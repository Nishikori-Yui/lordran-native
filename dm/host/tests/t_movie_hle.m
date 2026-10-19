// Exercise the actual HLE worker, input ownership and output backpressure.
#import <AVFoundation/AVFoundation.h>
#include "../hle_movie.c"
#include <assert.h>
#include <time.h>

uint64_t now_ns(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}
void *guest_sym(const char *name) { (void)name; return NULL; }
void *dm_guest_thread_spawn(void (*fn)(void *), void *arg, int priority, size_t stack) {
    (void)fn; (void)arg; (void)priority; (void)stack; abort();
}
int nvn_host_write_texture(const void *t, const void *p, int w, int h, size_t row, int *tw, int *th) {
    (void)t; (void)p; (void)w; (void)h; (void)row; (void)tw; (void)th; abort();
}
int nvn_host_signal_sync(void *sync) { (void)sync; abort(); }
static void signal_event(void *event) { (*(int *)event)++; }

static mdec_t *decoder(NSData *avcc, int *errors) {
    mdec_t *d = calloc(1, sizeof *d); assert(d);
    pthread_mutex_init(&d->mu, NULL); pthread_mutex_init(&d->dmu, NULL);
    pthread_mutex_init(&d->wmu, NULL); pthread_cond_init(&d->wcv, NULL);
    d->type = MD_TYPE_AVC; d->fmt = MD_FMT_NV12; d->w = 1920; d->h = 1080; d->started = 1;
    for (int i = 0; i < MD_NIN; i++) { d->in[i] = malloc(MD_INCAP); assert(d->in[i]); d->infree[i] = i; }
    d->ninfree = MD_NIN; d->ev[3] = errors; G.signal = signal_event;
    d->vhdr[0] = malloc(avcc.length); assert(d->vhdr[0]);
    memcpy(d->vhdr[0], avcc.bytes, avcc.length); d->vhdr_n[0] = (int)avcc.length;
    assert(!pthread_create(&d->wk, NULL, md_worker, d));
    return d;
}
static int frames, eos_count;
static int64_t previous_pts;
static NSMutableSet<NSNumber *> *expected;
static int receive(void **self) {
    int index, remaining; int64_t pts; uint32_t flags;
    int result = h_movie_AcqOut(self, &index, &pts, &flags, &remaining);
    if (result == MD_NO_OUTPUT) return 0;
    assert(!result);
    mdec_t *d = md_of(self);
    if (d->out[index].pic) {
        assert(!frames || pts > previous_pts); previous_pts = pts;
        assert([expected containsObject:@(pts)]); [expected removeObject:@(pts)];
        assert(d->out[index].frm); frames++;
    }
    eos_count += (flags & 4) != 0;
    assert(eos_count <= 1);
    assert(!h_movie_RelOut(self, index));
    assert(h_movie_RelOut(self, index) == 0x100b);
    return 1;
}
static void submit(void **self, NSData *packet, int64_t pts, unsigned flags) {
    int index, remaining;
    int result = h_movie_AcqIn(self, &index, &remaining);
    while (result == MD_NO_INPUT) {
        assert(receive(self));
        result = h_movie_AcqIn(self, &index, &remaining);
    }
    assert(!result && packet.length <= MD_INCAP);
    if (packet.length) memcpy(md_of(self)->in[index], packet.bytes, packet.length);
    assert(!h_movie_SendIn(self, index, 0, (int)packet.length, pts, flags));
}
static void run(NSArray<NSData *> *packets, NSArray<NSNumber *> *pts, NSData *avcc, int final_eos) {
    int errors = 0; void *self[] = {NULL, decoder(avcc, &errors)};
    frames = eos_count = 0; expected = [NSMutableSet setWithArray:pts];
    for (NSUInteger i = 0; i < packets.count; i++) {
        submit(self, packets[i], pts[i].longLongValue, final_eos && i + 1 == packets.count ? 4 : 0);
        // Outputs still in the ready queue belong to the decoder, not the client.
        mdec_t *d = md_of(self);
        if (d->noutq) assert(h_movie_RelOut(self, d->outq[0]) == 0x100b);
    }
    if (!final_eos) submit(self, nil, 0, 4);
    while (receive(self)) {}
    assert(frames == (int)packets.count && eos_count == 1 && expected.count == 0 && !errors);
    assert(!h_movie_LastErr(self));
    md_reset(md_of(self), 1);
    assert(!md_of(self)->avc && !h_movie_LastErr(self));
    // A zero-frame stream still emits exactly one EOS notification after reset.
    frames = eos_count = 0;
    submit(self, nil, 0, 4); assert(receive(self)); assert(!receive(self)); assert(eos_count == 1);
    md_reset(md_of(self), 1);
    NSData *invalid = [NSData dataWithBytes:(uint8_t[]){0, 0, 0, 9, 0x65} length:5];
    submit(self, invalid, 0, 0);
    assert(errors == 1 && h_movie_LastErr(self) != 0);
    md_reset(md_of(self), 1); assert(!h_movie_LastErr(self));
    md_free(self);
    printf("movie HLE: backpressure, timestamps, EOS=%s, empty EOS, ownership, errors and reset passed\n", final_eos ? "last packet" : "separate packet");
}
static void test_aac(NSString *path, int use_fallback_cookie) {
    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:path]];
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject; assert(track);
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:nil]; assert(reader);
    AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:nil];
    [reader addOutput:output]; assert([reader startReading]);
    // Read the format description from the compressed sample itself; this is the cookie passed by the game's Configure call.
    CMSampleBufferRef first = [output copyNextSampleBuffer]; assert(first);
    CMAudioFormatDescriptionRef description = (CMAudioFormatDescriptionRef)CMSampleBufferGetFormatDescription(first);
    const AudioStreamBasicDescription *format = CMAudioFormatDescriptionGetStreamBasicDescription(description);
    size_t cookieSize = 0; const void *cookie = CMAudioFormatDescriptionGetMagicCookie(description, &cookieSize);
    assert(format && cookie && cookieSize > 0);
    mdec_t decoder = {0}; decoder.type = MD_TYPE_AAC; decoder.ch = (int)format->mChannelsPerFrame; decoder.rate = (int)format->mSampleRate;
    if (!use_fallback_cookie) {
        decoder.vhdr[0] = malloc(cookieSize); assert(decoder.vhdr[0]); memcpy(decoder.vhdr[0], cookie, cookieSize); decoder.vhdr_n[0] = (int)cookieSize;
    } else cookieSize = 0;
    int decoded = 0, packets = 0; int64_t energy = 0;
    CMSampleBufferRef sample = first;
    for (int i = 0; sample && i < 16; i++) {
        CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
        if (!block || !CMSampleBufferGetNumSamples(sample)) {
            CFRelease(sample); sample = [output copyNextSampleBuffer]; continue;
        }
        const AudioStreamPacketDescription *descriptions = NULL; size_t descriptions_size = 0;
        assert(!CMSampleBufferGetAudioStreamPacketDescriptionsPtr(sample, &descriptions, &descriptions_size));
        size_t count = descriptions_size ? descriptions_size / sizeof(*descriptions) : (size_t)CMSampleBufferGetNumSamples(sample);
        assert(count > 0 && (!descriptions_size || descriptions_size % sizeof(*descriptions) == 0));
        size_t block_size = CMBlockBufferGetDataLength(block);
        for (size_t p = 0; p < count; p++) {
            size_t offset = descriptions ? (size_t)descriptions[p].mStartOffset : p * (size_t)format->mBytesPerPacket;
            size_t size = descriptions ? descriptions[p].mDataByteSize : (size_t)format->mBytesPerPacket;
            assert(size > 0 && offset <= block_size && size <= block_size - offset);
            NSMutableData *packet = [NSMutableData dataWithLength:size];
            assert(!CMBlockBufferCopyDataBytes(block, offset, size, packet.mutableBytes));
            decoder.jerr = 0;
            int got = md_aac(&decoder, packet.bytes, (int)packet.length, 0);
            assert(!decoder.jerr);
            packets++;
            if (got) {
                assert(decoder.out[0].bytes > 0 && decoder.out[0].bytes % ((size_t)decoder.ch * 2) == 0);
                int16_t *pcm = (int16_t *)decoder.out[0].frm;
                for (size_t j = 0; j < decoder.out[0].bytes / 2; j++) energy += llabs(pcm[j]);
                decoded++;
            }
        }
        CFRelease(sample);
        sample = [output copyNextSampleBuffer];
    }
    if (sample) CFRelease(sample);
    assert(packets >= 8 && decoded >= 8 && energy > 0);
    md_close(&decoder); free(decoder.vhdr[0]); free(decoder.out[0].frm);
    printf("AAC decoder: input_packets=%d decoded_packets=%d channels=%d sample_rate_hz=%d cookie_bytes=%zu source=%s PCM_energy=%lld passed\n",
           packets, decoded, decoder.ch, decoder.rate, cookieSize, use_fallback_cookie ? "no-cookie" : "asset", (long long)energy);
}
int main(int argc, char **argv) { @autoreleasepool {
    if (argc == 3 && !strcmp(argv[1], "--aac")) { test_aac(@(argv[2]), 0); return 0; }
    if (argc == 3 && !strcmp(argv[1], "--aac-no-cookie")) { test_aac(@(argv[2]), 1); return 0; }
    assert(argc == 2);
    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:@(argv[1])]];
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject; assert(track);
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:nil]; assert(reader);
    AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:nil];
    [reader addOutput:output]; assert([reader startReading]);
    NSMutableArray *packets = [NSMutableArray new], *pts = [NSMutableArray new]; NSData *avcc = nil;
    CMSampleBufferRef sample;
    while ((sample = [output copyNextSampleBuffer])) {
        CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
        if (block) {
            if (!avcc) {
                NSDictionary *atoms = (__bridge NSDictionary *)CMFormatDescriptionGetExtension(CMSampleBufferGetFormatDescription(sample), kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms);
                avcc = atoms[@"avcC"]; assert(avcc.length);
            }
            NSMutableData *data = [NSMutableData dataWithLength:CMBlockBufferGetDataLength(block)];
            assert(!CMBlockBufferCopyDataBytes(block, 0, data.length, data.mutableBytes));
            [packets addObject:data];
            [pts addObject:@(CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample), 1000000, kCMTimeRoundingMethod_RoundHalfAwayFromZero).value)];
        }
        CFRelease(sample);
    }
    assert(reader.status == AVAssetReaderStatusCompleted && packets.count > 32);
    run(packets, pts, avcc, 0); run(packets, pts, avcc, 1);
    return 0;
} }
