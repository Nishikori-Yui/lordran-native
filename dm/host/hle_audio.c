// nn::audio AudioOut: the game (FMOD nx output layer) appends PCM buffers block by block; once played the system puts them back on the "released" queue and signals the event.
// Host: real audio output = CoreAudio AudioUnit (Mac DefaultOutput / iOS RemoteIO); silent sink = consumes buffers in real time (no sound, pacing matches the real device).
//       iOS defaults to real audio output (the product must have sound), tests that want silence set DM_AUDIO=0 explicitly; Mac defaults to the silent sink (replay / gate checks are silent), DM_AUDIO=1 for real audio output.
// The contents of AudioOut / AudioOutBuffer / AudioOutParameter are read and written only through the interfaces below; the host defines its own internal layout and only writes the front part of the structs.
#include "hle.h"
#include <AudioToolbox/AudioToolbox.h>
#include <TargetConditionals.h>
#include <dispatch/dispatch.h>
#include <stdatomic.h>
#include <unistd.h>

enum { FMT_PCM16 = 2, STATE_STARTED = 0, STATE_STOPPED = 1, RATE = 48000 };
enum { HOST_AUDIO_CHANNELS = 2, MIX_CHUNK_FRAMES = 256 };

typedef struct { void *ptr; uint64_t cap, size; } gbuf;     // The first 24 bytes written into the guest AudioOutBuffer
#define QMAX 64
#define RELMAX QMAX                    // Released max = number of in-flight buffers (the game must take a buffer back before it can append again), same limit as pending
typedef struct {
    pthread_mutex_t m;
    void *event;                       // Guest SystemEvent: signaled whenever a buffer is released
    int ch;
    int out_ch;                        // Apple output is kept stereo; the guest may submit surround PCM
    int16_t *mix_scratch;              // Preallocated callback scratch; never allocate on the real-time thread
    size_t mix_scratch_samples;
    _Atomic int state;
    gbuf *q[QMAX]; _Atomic uint32_t q_head, q_tail;       // Pending: written by the game side, read by the output side
    gbuf *rel[RELMAX]; _Atomic uint32_t rel_head, rel_tail; // Released: written by the output side, read by the game side
    uint64_t pos;                      // Bytes already played of the current block
    AudioUnit au;
    pthread_t null_th; _Atomic int null_run;
    dispatch_semaphore_t notify_sem;
    pthread_t notify_th; _Atomic int notify_run, notify_pending, notify_armed;
    int id;                            // open sequence number (#N in the log; tells simultaneous outputs apart, e.g. Engage's Wwise and Unity's built-in FMOD)
    int nlog;                          // Start / Stop / Close lines logged so far (at most 32 per output)
    _Atomic uint64_t under_n, under_b; // underruns: times the pending queue was empty when the callback needed data / zero-filled bytes
    uint64_t st_calls, st_qsum, st_u0, st_ub0; uint32_t st_fmin, st_fmax;   // sound card callback statistics (read and written only on the callback thread)
} aout;

// Registry of open outputs: suspended / resumed all at once by the front-end lifecycle (going to background)
#define AOMAX 8
static aout *g_aos[AOMAX];
static pthread_mutex_t g_aos_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_suspended;
static aout *ao(const void *g) { aout *a = objmap_get(g); if (!a) die("AudioOut object was not created by the host: %p", g); return a; }
// the call site as "module+offset"; "宿主" (host) when the host itself calls (in-process audio renderer)
static const char *site(void *lr, char *buf, size_t n) {
    module_t *m = lr ? module_of(lr) : NULL;
    if (m) snprintf(buf, n, "%s+%#llx", m->name, (unsigned long long)((uint8_t *)lr - m->base)); else snprintf(buf, n, "host");
    return buf;
}
// Start / Stop / Close: at most 32 lines per output; middleware calls them only at init, suspend and resume, more means it keeps toggling
static void au_note(aout *a, const char *what, void *lr) {
    char b[64];
    if (a->nlog < 32) { a->nlog++; LOG("AudioOut #%d: %s caller=%s%s", a->id, what, site(lr, b, sizeof b), a->nlog == 32 ? "; further events suppressed" : ""); }
}

static void notify_release(aout *a) {
    atomic_store_explicit(&a->notify_pending, 1, memory_order_release);
    if (atomic_exchange_explicit(&a->notify_armed, 1, memory_order_acq_rel) == 0)
        dispatch_semaphore_signal(a->notify_sem);
}

static void *event_notify(void *p) {
    aout *a = p;
    for (;;) {
        dispatch_semaphore_wait(a->notify_sem, DISPATCH_TIME_FOREVER);
        if (atomic_exchange_explicit(&a->notify_pending, 0, memory_order_acq_rel) && a->event)
            hle_signal_system_event(a->event);
        atomic_store_explicit(&a->notify_armed, 0, memory_order_release);
        if (!atomic_load_explicit(&a->notify_run, memory_order_acquire)) break;
        if (atomic_load_explicit(&a->notify_pending, memory_order_acquire) &&
            atomic_exchange_explicit(&a->notify_armed, 1, memory_order_acq_rel) == 0)
            dispatch_semaphore_signal(a->notify_sem);
    }
    return NULL;
}

// Take n bytes from the pending queue and hand them to the output side; once a whole block has played, move it to released and notify the ordinary thread.
static void pull(aout *a, uint8_t *dst, uint64_t n) {
    int released = 0;
    uint32_t qh = atomic_load_explicit(&a->q_head, memory_order_relaxed);
    while (n) {
        uint32_t qt = atomic_load_explicit(&a->q_tail, memory_order_acquire);
        if (qh == qt || atomic_load_explicit(&a->state, memory_order_acquire) != STATE_STARTED) {
            if (qh == qt && atomic_load_explicit(&a->state, memory_order_acquire) == STATE_STARTED) { atomic_fetch_add(&a->under_n, 1); atomic_fetch_add(&a->under_b, n); }
            memset(dst, 0, n); break; }
        gbuf *b = a->q[qh & (QMAX - 1)];
        uint64_t k = b->size - a->pos; if (k > n) k = n;
        memcpy(dst, (uint8_t *)b->ptr + a->pos, k);
        dst += k; n -= k; a->pos += k;
        if (a->pos >= b->size) {
            uint32_t rw = atomic_load_explicit(&a->rel_tail, memory_order_relaxed);
            uint32_t rr = atomic_load_explicit(&a->rel_head, memory_order_acquire);
            if (rw - rr == RELMAX) die("AudioOut released-buffer queue overflow");
            a->rel[rw & (RELMAX - 1)] = b;
            atomic_store_explicit(&a->rel_tail, rw + 1, memory_order_release);
            qh++;
            atomic_store_explicit(&a->q_head, qh, memory_order_release);
            a->pos = 0; released = 1;
        }
    }
    if (released) notify_release(a);
}

static int16_t mix_clip(int64_t v) {
    if (v > INT16_MAX) return INT16_MAX;
    if (v < INT16_MIN) return INT16_MIN;
    return (int16_t)v;
}

// Downmix the layouts used by AudioOut to the stereo hardware format. The
// six-channel layout is FL, FR, FC, LFE, SL, SR; integer coefficients keep the
// callback deterministic and avoid floating-point work on the audio thread.
static void downmix_stereo(const int16_t *src, int16_t *dst, size_t frames, int ch) {
    for (size_t i = 0; i < frames; i++, src += ch, dst += HOST_AUDIO_CHANNELS) {
        int64_t l, r;
        if (ch >= 6) {
            l = (int64_t)src[0] * 1024 + (int64_t)src[2] * 724 + (int64_t)src[3] * 257 + (int64_t)src[4] * 724;
            r = (int64_t)src[1] * 1024 + (int64_t)src[2] * 724 + (int64_t)src[3] * 257 + (int64_t)src[5] * 724;
            dst[0] = mix_clip(l / 1024); dst[1] = mix_clip(r / 1024);
        } else if (ch == 1) {
            dst[0] = dst[1] = src[0];
        } else {
            dst[0] = src[0]; dst[1] = src[1];
        }
    }
}

static void pull_output(aout *a, uint8_t *dst, UInt32 frames) {
    if (!frames) return;
    if (a->ch == a->out_ch) {
        pull(a, dst, (uint64_t)frames * a->out_ch * sizeof(int16_t));
        return;
    }
    uint8_t *out = dst;
    UInt32 left = frames;
    while (left) {
        UInt32 n = left > MIX_CHUNK_FRAMES ? MIX_CHUNK_FRAMES : left;
        size_t samples = (size_t)n * (size_t)a->ch;
        if (samples > a->mix_scratch_samples) {
            // au_open allocates enough for the normal callback size. A larger
            // request is silenced rather than overrunning the real-time buffer.
            memset(out, 0, (size_t)n * a->out_ch * sizeof(int16_t));
        } else {
            pull(a, (uint8_t *)a->mix_scratch, samples * sizeof(int16_t));
            downmix_stereo(a->mix_scratch, (int16_t *)out, n, a->ch);
        }
        out += (size_t)n * a->out_ch * sizeof(int16_t); left -= n;
    }
}

static _Atomic uint64_t g_render_calls;   // Cumulative sound card callbacks (lifecycle verification: must keep growing after resume)
uint64_t dm_audio_render_calls(void) { return atomic_load_explicit(&g_render_calls, memory_order_relaxed); }
static OSStatus au_render(void *ctx, AudioUnitRenderActionFlags *f, const AudioTimeStamp *ts, UInt32 bus, UInt32 frames, AudioBufferList *bl) {
    (void)f; (void)ts; (void)bus;
    aout *a = ctx;
    atomic_fetch_add_explicit(&g_render_calls, 1, memory_order_relaxed);
    {
        // Every 2000 callbacks of each output, log one line: frames requested per call, pending blocks at callback start, underruns (check this line on a new device; docs/agents/03-bringup.md "Crackling on iOS only").
        // Kept per output: with two outputs open, combined numbers mislead (one fully fed and one fed by nobody look like "every other callback underruns")
        uint32_t qd = atomic_load(&a->q_tail) - atomic_load(&a->q_head);
        if (!a->st_calls || frames < a->st_fmin) a->st_fmin = frames; if (frames > a->st_fmax) a->st_fmax = frames; a->st_qsum += qd;
        if (++a->st_calls % 2000 == 0) { uint64_t un = atomic_load(&a->under_n), ubb = atomic_load(&a->under_b);
            LOG("AudioOut #%d: callbacks=%llu frames_per_callback=%u-%u queued_blocks_avg=%.1f; last 2000 callbacks: underruns=%llu silence_ms=%.1f", a->id, (unsigned long long)a->st_calls, a->st_fmin, a->st_fmax, a->st_qsum / 2000.0,
                (unsigned long long)(un - a->st_u0), (ubb - a->st_ub0) / (2.0 * a->ch) / (RATE / 1000.0)); a->st_fmin = ~0u; a->st_fmax = 0; a->st_qsum = 0; a->st_u0 = un; a->st_ub0 = ubb; } }
    if (bl->mNumberBuffers && bl->mBuffers[0].mData) {
        UInt32 capacity = (UInt32)(bl->mBuffers[0].mDataByteSize / (a->out_ch * sizeof(int16_t)));
        if (frames > capacity) frames = capacity;
        pull_output(a, bl->mBuffers[0].mData, frames);
        bl->mBuffers[0].mDataByteSize = frames * a->out_ch * sizeof(int16_t);
    }
    { static int mute = -1; if (mute < 0) { const char *e = getenv("DM_AUDIO_MUTE"); mute = e && atoi(e); }   // diagnostic: the whole real-output path (AudioUnit callback pacing, background take-over) but with the output silenced (lifecycle tests on the Mac without noise)
      if (mute && bl->mNumberBuffers && bl->mBuffers[0].mData) memset(bl->mBuffers[0].mData, 0, bl->mBuffers[0].mDataByteSize); }
    return noErr;
}
static void au_open(aout *a) {
    AudioComponentDescription d = {.componentType = kAudioUnitType_Output,
#if TARGET_OS_IPHONE
                                   .componentSubType = kAudioUnitSubType_RemoteIO,
#else
                                   .componentSubType = kAudioUnitSubType_DefaultOutput,
#endif
                                   .componentManufacturer = kAudioUnitManufacturer_Apple};
    AudioComponent c = AudioComponentFindNext(NULL, &d);
    if (!c || AudioComponentInstanceNew(c, &a->au)) die("Failed to create AudioUnit instance");
    a->out_ch = HOST_AUDIO_CHANNELS;
    a->mix_scratch_samples = (size_t)MIX_CHUNK_FRAMES * (size_t)a->ch;
    a->mix_scratch = calloc(a->mix_scratch_samples, sizeof *a->mix_scratch);
    if (!a->mix_scratch) die("Failed to allocate AudioUnit downmix buffer");
    AudioStreamBasicDescription f = {.mSampleRate = RATE, .mFormatID = kAudioFormatLinearPCM,
                                     .mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                     .mBytesPerPacket = 2u * a->out_ch, .mFramesPerPacket = 1, .mBytesPerFrame = 2u * a->out_ch,
                                     .mChannelsPerFrame = (UInt32)a->out_ch, .mBitsPerChannel = 16};
    AURenderCallbackStruct cb = {au_render, a};
#if !TARGET_OS_IPHONE
    { const char *e = getenv("DM_DBG_AU_FRAMES"); if (e) {   // diagnostic: on the Mac, make the sound card callback ask N frames each time (1024 = the iOS default, reproduces the crackling)
        UInt32 fr = (UInt32)atoi(e); OSStatus st = AudioUnitSetProperty(a->au, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &fr, sizeof fr);
        LOG("Audio device buffer size: frames=%u status=%d", fr, (int)st); } }
#endif
    if (AudioUnitSetProperty(a->au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof f) ||
        AudioUnitSetProperty(a->au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb) ||
        AudioUnitInitialize(a->au)) die("Failed to configure AudioUnit");
    LOG("AudioOut #%d: output_channels=%d guest_channels=%d; host downmix enabled", a->id, a->out_ch, a->ch);
}
// Silent sink: consumes in real time at 48 kHz every 5 ms. When more than 100 ms behind (iOS suspended the whole process in the background, SIGSTOP on the Mac), restart the count from now and do not make up the missed time --
// making it up would pull hundreds of times in one go (seconds' worth), releasing all of the game's buffers and logging hundreds of underruns; a suspended console does not play that stretch either
static void *null_sink(void *p) {
    aout *a = p; uint8_t scratch[RATE / 200 * 2 * 8];
    uint64_t bytes = (uint64_t)RATE / 200 * 2 * a->ch, t = now_ns();
    while (atomic_load_explicit(&a->null_run, memory_order_acquire)) {
        t += 5000000; uint64_t now = now_ns();
        if (t > now) usleep((useconds_t)((t - now) / 1000)); else if (now - t > 100000000) t = now;
        pull(a, scratch, bytes);
    }
    return NULL;
}
static int real_audio(void) { const char *e = getenv("DM_AUDIO"); return e ? atoi(e) != 0 : TARGET_OS_IPHONE; }

// AudioOutParameter = { int32 sampleRate; uint16 channelCount; uint16 _r; ... }, 0 = system default (48 kHz / 2 channels)
HLE_FORCE("_ZN2nn5audio27InitializeAudioOutParameterEPNS0_17AudioOutParameterE", "音频输出参数默认值", void, h_au_InitParam, uint8_t *p) { memset(p, 0, 8); }
// AudioOutInfo = { char name[256] }
HLE_FORCE("_ZN2nn5audio13ListAudioOutsEPNS0_12AudioOutInfoEi", "音频输出设备列表；宿主 1 个", int, h_au_List, char *info, int n) {
    if (n < 1) return 0;
    memset(info, 0, 256); strcpy(info, "DeviceOut"); return 1;
}
static Result au_open_at(void *g, void *ev, const char *name, const uint8_t *param, void *lr) {
    static _Atomic int nopen;
    int ch = *(const uint16_t *)(param + 4); int rate = *(const int32_t *)param;
    if (!ch) ch = 2;
    if (rate && rate != RATE) die("Unsupported AudioOut sample rate: %d Hz; expected 48000 Hz", rate);
    aout *a = calloc(1, sizeof *a);
    pthread_mutex_init(&a->m, NULL); a->event = ev; a->ch = ch;
    atomic_init(&a->state, STATE_STOPPED);
    atomic_init(&a->q_head, 0); atomic_init(&a->q_tail, 0);
    atomic_init(&a->rel_head, 0); atomic_init(&a->rel_tail, 0);
    atomic_init(&a->null_run, 0); atomic_init(&a->notify_run, 1);
    atomic_init(&a->notify_pending, 0); atomic_init(&a->notify_armed, 0);
    a->notify_sem = dispatch_semaphore_create(0); a->id = atomic_fetch_add(&nopen, 1);
    pthread_create(&a->notify_th, NULL, event_notify, a);
    if (ev) hle_bind_system_event(ev, 1);   // Buffer release event: bind a kernel event on the guest thread (auto-clear), afterwards signaled by the audio thread
    objmap_put(g, a);
    pthread_mutex_lock(&g_aos_lock);
    int slot = -1; for (int i = 0; i < AOMAX; i++) if (!g_aos[i]) { slot = i; break; }
    if (slot < 0) die("Too many open AudioOut instances: limit=%d", AOMAX);
    g_aos[slot] = a;
    pthread_mutex_unlock(&g_aos_lock);
    char sb[64];
    LOG("AudioOut #%d opened: name=%s channels=%d output=%s%s caller=%s", a->id, name ? name : "(default)", ch, real_audio() ? "CoreAudio" : "silent sink", ev ? "" : "; no release event (guest polling)", site(lr, sb, sizeof sb));
    if (real_audio()) au_open(a);
    return RES_OK;
}
HLE_FORCE("_ZN2nn5audio12OpenAudioOutEPNS0_8AudioOutEPNS_2os11SystemEventEPKcRKNS0_17AudioOutParameterE", "连 audout 服务；宿主 AudioUnit / 静音接收端",
          Result, h_au_Open, void *g, void *ev, const char *name, const uint8_t *param) { return au_open_at(g, ev, name, param, __builtin_return_address(0)); }
// The two default-device overloads (Engage, SDK 12): as OpenAudioOut with the default device name; the overload without an event binds no release event (the game polls GetReleasedAudioOutBuffer)
HLE_FORCE("_ZN2nn5audio19OpenDefaultAudioOutEPNS0_8AudioOutEPNS_2os11SystemEventERKNS0_17AudioOutParameterE", "连 audout 服务（缺省设备）；同 OpenAudioOut",
          Result, h_au_OpenDef, void *g, void *ev, const uint8_t *param) { return au_open_at(g, ev, NULL, param, __builtin_return_address(0)); }
HLE_FORCE("_ZN2nn5audio19OpenDefaultAudioOutEPNS0_8AudioOutERKNS0_17AudioOutParameterE", "连 audout 服务（缺省设备、无事件）；同 OpenAudioOut",
          Result, h_au_OpenDef0, void *g, const uint8_t *param) { return au_open_at(g, NULL, NULL, param, __builtin_return_address(0)); }
static Result au_start_at(void *g, void *lr) {
    aout *a = ao(g);
    pthread_mutex_lock(&a->m); int was = atomic_load_explicit(&a->state, memory_order_relaxed); atomic_store_explicit(&a->state, STATE_STARTED, memory_order_release); pthread_mutex_unlock(&a->m);
    au_note(a, was == STATE_STARTED ? "Start (already playing)" : g_suspended ? "Start (app in background; using silence sink)" : "Start", lr);
    if (was == STATE_STARTED) return RES_OK;
    if (a->au && !g_suspended) { if (AudioOutputUnitStart(a->au)) die("Failed to start AudioUnit"); }
    else { atomic_store_explicit(&a->null_run, 1, memory_order_release); pthread_create(&a->null_th, NULL, null_sink, a); }
    return RES_OK;
}
HLE_FORCE("_ZN2nn5audio13StartAudioOutEPNS0_8AudioOutE", "开始播放", Result, h_au_Start, void *g) { return au_start_at(g, __builtin_return_address(0)); }
static void au_stop_at(void *g, void *lr) {   // lr NULL: the stop inside Close, not logged separately
    aout *a = ao(g);
    pthread_mutex_lock(&a->m); int was = atomic_load_explicit(&a->state, memory_order_relaxed); atomic_store_explicit(&a->state, STATE_STOPPED, memory_order_release); pthread_mutex_unlock(&a->m);
    if (lr) au_note(a, was == STATE_STARTED ? "Stop" : "Stop (already stopped)", lr);
    if (was != STATE_STARTED) return;
    pthread_mutex_lock(&g_aos_lock); int susp = g_suspended; pthread_mutex_unlock(&g_aos_lock);
    if (a->au && !susp) AudioOutputUnitStop(a->au);
    else { atomic_store_explicit(&a->null_run, 0, memory_order_release); pthread_join(a->null_th, NULL); }   // Silent sink (including one that took over during suspension)
}
HLE_FORCE("_ZN2nn5audio12StopAudioOutEPNS0_8AudioOutE", "停止播放", void, h_au_Stop, void *g) { au_stop_at(g, __builtin_return_address(0)); }
HLE_FORCE("_ZN2nn5audio13CloseAudioOutEPNS0_8AudioOutE", "关闭音频输出", void, h_au_Close, void *g) {
    au_note(ao(g), "Close", __builtin_return_address(0));
    au_stop_at(g, NULL);
    aout *a = objmap_del(g);
    atomic_store_explicit(&a->notify_run, 0, memory_order_release);
    dispatch_semaphore_signal(a->notify_sem);
    pthread_join(a->notify_th, NULL);
    pthread_mutex_lock(&g_aos_lock);
    for (int i = 0; i < AOMAX; i++) if (g_aos[i] == a) g_aos[i] = NULL;
    pthread_mutex_unlock(&g_aos_lock);
    if (a->au) { AudioUnitUninitialize(a->au); AudioComponentInstanceDispose(a->au); }
    free(a->mix_scratch);
    dispatch_release(a->notify_sem);
    pthread_mutex_destroy(&a->m); free(a);
}
HLE_FORCE("_ZN2nn5audio16GetAudioOutStateEPKNS0_8AudioOutE", "播放状态", int, h_au_State, const void *g) { return atomic_load_explicit(&ao(g)->state, memory_order_acquire); }
HLE_FORCE("_ZN2nn5audio21GetAudioOutSampleRateEPKNS0_8AudioOutE", "采样率", int, h_au_Rate, const void *g) { (void)ao(g); return RATE; }
HLE_FORCE("_ZN2nn5audio23GetAudioOutChannelCountEPKNS0_8AudioOutE", "声道数", int, h_au_Ch, const void *g) { return ao(g)->ch; }
HLE_FORCE("_ZN2nn5audio15GetAudioOutNameEPKNS0_8AudioOutE", "设备名；宿主只有缺省设备", const char *, h_au_Name, const void *g) { (void)g; return "DeviceOut"; }
HLE_FORCE("_ZN2nn5audio23GetAudioOutSampleFormatEPKNS0_8AudioOutE", "采样格式；只做 PCM16", int, h_au_Fmt, const void *g) { (void)ao(g); return FMT_PCM16; }

HLE_FORCE("_ZN2nn5audio21SetAudioOutBufferInfoEPNS0_14AudioOutBufferEPvmm", "缓冲描述；写进客体结构体前 24 字节", void, h_au_SetBuf, gbuf *b, void *p, uint64_t cap, uint64_t size) {
    b->ptr = p; b->cap = cap; b->size = size;
}
HLE_FORCE("_ZN2nn5audio28GetAudioOutBufferDataPointerEPKNS0_14AudioOutBufferE", "缓冲数据指针", void *, h_au_BufPtr, const gbuf *b) { return b->ptr; }
HLE_FORCE("_ZN2nn5audio25GetAudioOutBufferDataSizeEPKNS0_14AudioOutBufferE", "缓冲数据大小", uint64_t, h_au_BufSize, const gbuf *b) { return b->size; }
HLE_FORCE("_ZN2nn5audio20AppendAudioOutBufferEPNS0_8AudioOutEPNS0_14AudioOutBufferE", "追加待播缓冲", unsigned, h_au_Append, void *g, gbuf *b) {
    aout *a = ao(g);
    // Diagnostic switch DM_AUDIO_DUMP=<file>: every PCM block the game appends is written out as is (16-bit, 48 kHz, channel count per the OpenAudioOut log, usually 6). Used to judge "did a given sound play or not":
    // cross-correlate the original game's audio against it (this is how the tier-one drop sound was verified). The file is opened only when the variable is set; when unset this costs only one extra cached check
    { static FILE *df; static int on = -1; if (on < 0) { const char *e = getenv("DM_AUDIO_DUMP"); on = e != NULL; if (on && !(df = fopen(e, "wb"))) LOG_ERROR("Cannot open audio dump: path=%s", e); }
      if (df && b && b->ptr && b->size) fwrite(b->ptr, 1, (size_t)b->size, df); }
    pthread_mutex_lock(&a->m);
    uint32_t qt = atomic_load_explicit(&a->q_tail, memory_order_relaxed);
    uint32_t qh = atomic_load_explicit(&a->q_head, memory_order_acquire);
    int ok = qt - qh < QMAX;
    if (ok) { a->q[qt & (QMAX - 1)] = b; atomic_store_explicit(&a->q_tail, qt + 1, memory_order_release); }
    pthread_mutex_unlock(&a->m);
    return ok;      // bool: false when the queue is full (the real device has a limit too)
}
HLE_FORCE("_ZN2nn5audio25GetReleasedAudioOutBufferEPNS0_8AudioOutE", "取已播完的缓冲；没有则 NULL", gbuf *, h_au_Released, void *g) {
    aout *a = ao(g); gbuf *b = NULL;
    pthread_mutex_lock(&a->m);
    uint32_t rr = atomic_load_explicit(&a->rel_head, memory_order_relaxed);
    uint32_t rw = atomic_load_explicit(&a->rel_tail, memory_order_acquire);
    if (rr != rw) { b = a->rel[rr & (RELMAX - 1)]; atomic_store_explicit(&a->rel_head, rr + 1, memory_order_release); }
    pthread_mutex_unlock(&a->m);
    return b;
}

// Host-internal PCM output (used by the in-process audio renderer, see hle_audren.c): the same AudioOut machinery (real output / silent sink / background take-over), keyed by a host-allocated dummy object
void *dm_pcmout_open(int ch) {
    void *key = calloc(1, 64); uint8_t param[8] = {0}; *(uint16_t *)(param + 4) = (uint16_t)ch;
    if (au_open_at(key, NULL, "AudioRenderer", param, NULL)) die("Failed to open host PCM output");
    return key;
}
void dm_pcmout_start(void *k) { au_start_at(k, NULL); }
int dm_pcmout_append(void *k, void *b) { return (int)h_au_Append(k, b); }
void *dm_pcmout_released(void *k) { return h_au_Released(k); }

// Front-end lifecycle / audio session interruption: suspend real audio output, with the silent sink taking over real-time consumption meanwhile (pacing unbroken); switch back to the AudioUnit on resume.
// The front end calls with 1 on going to background / interruption began, and with 0 on returning to foreground / interruption ended (shouldResume).
void dm_audio_suspend(int on) {
    pthread_mutex_lock(&g_aos_lock);
    if (g_suspended != on) {
        g_suspended = on; int failed = 0;
        for (int i = 0; i < AOMAX; i++) {
            aout *a = g_aos[i];
            if (!a || !a->au || atomic_load_explicit(&a->state, memory_order_acquire) != STATE_STARTED) continue;
            // While suspended the silent sink consumes in real time instead: otherwise buffers are no longer released, the FMOD output thread waits forever and the game's audio pacing stalls (same for an incoming call interruption)
            if (on) { AudioOutputUnitStop(a->au); atomic_store_explicit(&a->null_run, 1, memory_order_release); pthread_create(&a->null_th, NULL, null_sink, a); }
            else { atomic_store_explicit(&a->null_run, 0, memory_order_release); pthread_join(a->null_th, NULL);
                   OSStatus st = AudioOutputUnitStart(a->au);
                   if (st) {   // The session is still held by someone else (switched back to the game with a call not yet hung up, or the user is still in another app when the interruption ends): not fatal, the silent sink keeps covering, and we retry at the next resume
                       LOG_ERROR("Failed to resume AudioUnit: status=%d; using silent sink until the next resume attempt", (int)st);
                       atomic_store_explicit(&a->null_run, 1, memory_order_release); pthread_create(&a->null_th, NULL, null_sink, a); failed = 1; } }
        }
        if (failed) g_suspended = 1;   // Resume did not succeed: the state stays "suspended", and the next call with 0 will retry
        LOG("audio %s", on ? "suspended (background or interruption)" : failed ? "resume failed" : "resumed (foreground or interruption ended)");
    }
    pthread_mutex_unlock(&g_aos_lock);
}
