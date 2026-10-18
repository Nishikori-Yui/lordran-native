// swkbd software keyboard (system applet) → host native input box. MakePreset / SetInitialTextUtf8 / GetRequired*Size are left to run as is in the SDK,
// here we only read the ShowKeyboardArg they write and write back String per the output convention of the real swkbd applet.
// Layout sources (offsets in the original sdk 3.3.94012 image):
//   ShowKeyboard 0x3a6770 moves KeyboardConfig field by field into the applet arguments: +0x24 title u16[65], +0xa6 subtitle u16[129], +0x1a8 hint u16[257],
//     +0x3ac maximum length, +0x3b0 minimum length, +0x3bd isUseUtf8, +0x3c0 offset of the initial text within the work buffer, +0x3c4 UTF-16 length of the initial text;
//     work buffer pointer / size at +0x4d0 / +0x4d8 (handed to the applet together with CreateLargeStorage)
//   SetInitialTextUtf8 0x3a74c0: UTF-8 → UTF-16 written to work buffer+offset (offset 0x14, at most 500 characters + terminating 0)
//   ReadCloseResultAndString 0x3a63f0: output storage = u32 CloseResult + text area; the text area is copied as is into String{+0 pointer, +8 byte count}
//   ShowKeyboard wrap-up 0x3a6acc: CloseResult == 0 (OK) → Result 0, otherwise (cancel) → 0x29F; GetRequiredStringBufferSize = 0x7D4
// Game side (main 0xc6deac) sets isUseUtf8 = 1 after MakePreset and reads back as a C string (0x1b66640 strlen); UTF-16 output is supported as well per the original convention.
// No window and DM_KBD unset: return as cancel (no popup, no hang). DM_KBD="text": no popup, return that text directly as OK (windowless testing / lockstep comparison).
#include "hle.h"
#include <unistd.h>
#include "front.h"

enum { ARG_HEADER = 0x24, ARG_SUB = 0xa6, ARG_GUIDE = 0x1a8, ARG_MAXLEN = 0x3ac, ARG_MINLEN = 0x3b0, ARG_UTF8 = 0x3bd,
       ARG_INIT_OFF = 0x3c0, ARG_INIT_LEN = 0x3c4, ARG_WORKBUF = 0x4d0,
       HEADER_N = 65, SUB_N = 129, GUIDE_N = 257 };
#define SWKBD_RESULT_CANCELED 0x29Fu   // swkbd module 159 / description 1: the constant the SDK returns when CloseResult != 0

// UTF-16 (at most n units, stops at 0) → UTF-8, written to out (cap includes the terminating 0), returns the number of bytes written
size_t swkbd_u16_to_u8(const uint16_t *s, size_t n, char *out, size_t cap) {
    size_t o = 0;
    for (size_t i = 0; i < n && s[i]; i++) {
        uint32_t c = s[i];
        if (c >= 0xD800 && c < 0xDC00 && i + 1 < n && s[i + 1] >= 0xDC00 && s[i + 1] < 0xE000) c = 0x10000 + ((c - 0xD800) << 10) + (s[++i] - 0xDC00);
        char b[4]; int k = c < 0x80 ? (b[0] = (char)c, 1) : c < 0x800 ? (b[0] = (char)(0xC0 | c >> 6), b[1] = (char)(0x80 | (c & 63)), 2)
                 : c < 0x10000 ? (b[0] = (char)(0xE0 | c >> 12), b[1] = (char)(0x80 | (c >> 6 & 63)), b[2] = (char)(0x80 | (c & 63)), 3)
                 : (b[0] = (char)(0xF0 | c >> 18), b[1] = (char)(0x80 | (c >> 12 & 63)), b[2] = (char)(0x80 | (c >> 6 & 63)), b[3] = (char)(0x80 | (c & 63)), 4);
        if (o + k + 1 > cap) break;
        memcpy(out + o, b, k); o += k;
    }
    if (cap) out[o] = 0;
    return o;
}
// UTF-8 → UTF-16, at most max_units units (surrogate pairs are not split), written to out (cap units including the terminating 0), returns the unit count
size_t swkbd_u8_to_u16(const char *s, size_t max_units, uint16_t *out, size_t cap) {
    size_t o = 0; const uint8_t *p = (const uint8_t *)s;
    while (*p) {
        uint32_t c; int k = *p < 0x80 ? 1 : *p < 0xE0 ? 2 : *p < 0xF0 ? 3 : 4;
        c = k == 1 ? *p : k == 2 ? *p & 31 : k == 3 ? *p & 15 : *p & 7;
        for (int j = 1; j < k; j++) { if ((p[j] & 0xC0) != 0x80) { k = j; break; } c = c << 6 | (p[j] & 63); }
        size_t need = c >= 0x10000 ? 2 : 1;
        if (o + need > max_units || o + need + 1 > cap) break;
        if (need == 2) { c -= 0x10000; out[o++] = (uint16_t)(0xD800 | c >> 10); out[o++] = (uint16_t)(0xDC00 | (c & 0x3FF)); }
        else out[o++] = (uint16_t)c;
        p += k;
    }
    if (cap) out[o] = 0;
    return o;
}

// Core (called directly by unit tests): decode the display parameters from arg, get the user text through input (returns 1 OK / 0 cancel / -1 no window), write back out per the arg convention
// The game's offline character name rule (original image, judged byte by byte): 2–15 bytes, first and last must be a "letter", '-' and '_' at most one in total, the rest must be letters. The original game only accepts ASCII letters;
// hle_charname.c also lets bytes ≥0x80 through (Chinese names), so the rule becomes: English letters or Chinese characters, at most 15 UTF-8 bytes in total (3 bytes per Chinese character, at most 5).
// While the naming panel is open the front end blocks on the spot by this rule and writes the rule in the dialog. diag.c maintains this flag from UI messages.
int g_swkbd_name_panel;
int g_swkbd_numeric_max = -1;   // ≥0 = this input is a quantity box, value = upper limit (set by dm_textinput.c, read by the front end input box, set back to -1 after use)
int (*g_swkbd_unfilter)(void);   // registered by the host (dm_charname_unfilter in hle_charname.c; NULL in unit tests): keyboard requests from the naming panel bypass the game's ASCII typing filter
typedef int (*swkbd_input_fn)(const char *title, const char *sub, const char *guide, const char *initial, int max_chars, char *out, int out_cap);
Result swkbd_show(void *out, const void *arg_, swkbd_input_fn input) {
    const uint8_t *arg = arg_;
    char title[HEADER_N * 3 + 1], sub[SUB_N * 3 + 1], guide[GUIDE_N * 3 + 1], init[501 * 3 + 1] = "", text[1002 * 3 + 1];
    swkbd_u16_to_u8((const uint16_t *)(arg + ARG_HEADER), HEADER_N, title, sizeof title);
    swkbd_u16_to_u8((const uint16_t *)(arg + ARG_SUB), SUB_N, sub, sizeof sub);
    swkbd_u16_to_u8((const uint16_t *)(arg + ARG_GUIDE), GUIDE_N, guide, sizeof guide);
    int32_t maxlen, ilen, ioff; memcpy(&maxlen, arg + ARG_MAXLEN, 4); memcpy(&ilen, arg + ARG_INIT_LEN, 4); memcpy(&ioff, arg + ARG_INIT_OFF, 4);
    const uint8_t *work; memcpy(&work, arg + ARG_WORKBUF, 8);
    if (ilen > 0 && work) swkbd_u16_to_u8((const uint16_t *)(work + ioff), (size_t)ilen, init, sizeof init);

    const char *script = getenv("DM_KBD");
    // Freeze the guest clock while the keyboard is up (in offline single-player, monsters should not keep attacking while the player types, nor should ticks be caught up on return; this follows the native iOS experience, not the original game's Switch semantics of "the clock keeps running while an applet holds the foreground")
    if (!script) guest_clock_freeze_for(2, 1);
    int r = script ? (snprintf(text, sizeof text, "%s", script), 1) : input(title, sub, guide, init, maxlen > 0 ? maxlen : 0, text, sizeof text);
    if (!script) guest_clock_freeze_for(2, 0);
    g_swkbd_numeric_max = -1;   // the numeric box mark applies to this one time only (set by dm_textinput.c before bringing up the keyboard)
    LOG("Software keyboard: title=%s initial=%s max_length=%d result=%s text=%s", title, init, maxlen,
        r > 0 ? "accepted" : r == 0 ? "cancelled" : "cancelled (no window)", r > 0 ? text : "");
    if (r <= 0) return SWKBD_RESULT_CANCELED;
    if (g_swkbd_name_panel && g_swkbd_unfilter && g_swkbd_unfilter()) LOG("Software keyboard naming panel: guest ASCII input restriction disabled; Unicode names accepted");

    uint8_t *buf; uint64_t cap; memcpy(&buf, (uint8_t *)out, 8); memcpy(&cap, (uint8_t *)out + 8, 8);
    if (!buf || !cap) return RES_OK;                         // same as the SDK: if String has no buffer, the text is not read
    memset(buf, 0, cap);
    uint16_t u16[1003]; size_t n = swkbd_u8_to_u16(text, maxlen > 0 ? (size_t)maxlen : 1002, u16, 1003);   // truncate to the character limit (counted in UTF-16 units)
    if (arg[ARG_UTF8]) swkbd_u16_to_u8(u16, n, (char *)buf, cap);
    else memcpy(buf, u16, (n + 1) * 2 <= cap ? n * 2 : (cap / 2 - 1) * 2);
    { const char *lag = getenv("DM_TEST_SWKBD_LAG_MS"); if (lag) usleep((useconds_t)atoi(lag) * 1000); }   // test: slow down "keyboard handed back → the game's thread gets the result" to verify that auto-accept does not jump the gun   // front end path cleanup (dm_cursor.c): auto-accept after the name is typed on the naming page
    return RES_OK;
}

HLE_FORCE("_ZN2nn5swkbd12ShowKeyboardEPNS0_6StringERKNS0_15ShowKeyboardArgE", "软键盘小程序 → 宿主原生输入框（DM_KBD 直给文本）",
          Result, h_swkbd_Show, void *out, const void *arg) {
    return swkbd_show(out, arg, front_text_input);
}

// InlineKeyboard uses the same native dialog; results are delivered from Calc on
// the calling guest thread. Keep state outside the SDK object (no applet proxy).
// SDK 4.5 d9554752: CalcDecidedEnter_ +0x1cb744 reads 0x3f0 bytes;
// Dark Souls 1.0.3 main+0x686064 reads its UTF-16 length at +0x3ec.
// ChangedString adds composition begin/end and cursor at +0x3f0/4/8.
// UTF-8 replies use the same trailing fields after a 0x7d4-byte text area.
// AppearArg is 0x48 bytes; main+0x685de0 writes max length at +0x20.
typedef void (*ikb_cb0)(void);
typedef void (*ikb_cb)(const void *);
typedef struct {
    const void *kb;
    uint64_t epoch;
    ikb_cb0 initialized, finished, cancel;
    ikb_cb changed[2], moved[2], enter[2];
    uint16_t text[501];
    int utf8, maxlen, minlen, cursor, pending, init_pending;
} ikb_state;
static ikb_state g_ikb[4];
static uint64_t g_ikb_epoch;
static pthread_mutex_t g_ikb_mu = PTHREAD_MUTEX_INITIALIZER;
static int ikb_find(const void *kb) {
    for (int i = 0; i < 4; i++) if (g_ikb[i].kb == kb) return i;
    return -1;
}
static int ikb_slot(const void *kb) { // Caller holds the lock.
    int i = ikb_find(kb);
    if (i >= 0) return i;
    for (i = 0; i < 4; i++) if (!g_ikb[i].kb) {
        g_ikb[i] = (ikb_state){.kb = kb, .epoch = ++g_ikb_epoch, .maxlen = 500};
        return i;
    }
    return -1;
}
static int ikb_current(const ikb_state *s) {
    pthread_mutex_lock(&g_ikb_mu);
    int i = ikb_find(s->kb), current = i >= 0 && g_ikb[i].epoch == s->epoch;
    pthread_mutex_unlock(&g_ikb_mu);
    return current;
}
HLE_FORCE("_ZN2nn5swkbd14InlineKeyboard10InitializeEPv", "内嵌键盘：登记原生输入状态", unsigned, h_ikb_Init, void *kb, void *work) {
    (void)work;
    pthread_mutex_lock(&g_ikb_mu);
    int i = ikb_slot(kb);
    if (i >= 0) { g_ikb[i].epoch = ++g_ikb_epoch; g_ikb[i].pending = g_ikb[i].init_pending = 0; }
    pthread_mutex_unlock(&g_ikb_mu);
    LOG("Inline keyboard initialized: object=%p%s", kb, i < 0 ? "ERROR Registration table is full" : "");
    return i >= 0;
}
HLE_FORCE("_ZN2nn5swkbd14InlineKeyboard6LaunchEv", "内嵌键盘：下一次 Calc 通知初始化完成", void, h_ikb_Launch, void *kb) {
    pthread_mutex_lock(&g_ikb_mu);
    int i = ikb_find(kb); if (i >= 0) g_ikb[i].init_pending = 1;
    pthread_mutex_unlock(&g_ikb_mu);
}
HLE_FORCE("_ZN2nn5swkbd14InlineKeyboard8FinalizeEv", "内嵌键盘：清理原生输入状态", void, h_ikb_Fin, void *kb) {
    pthread_mutex_lock(&g_ikb_mu);
    int i = ikb_find(kb); if (i >= 0) memset(&g_ikb[i], 0, sizeof g_ikb[i]);
    pthread_mutex_unlock(&g_ikb_mu);
}
HLE_FORCE("_ZN2nn5swkbd14InlineKeyboardD1Ev", "内嵌键盘析构：清理输入状态", void, h_ikb_Dtor, void *kb) { h_ikb_Fin(kb); }
#define IKB_CB(mangled, cname, type, member) \
    HLE_FORCE(mangled, "Inline keyboard: registered guest callback", void, cname, void *kb, type fn) { \
        pthread_mutex_lock(&g_ikb_mu); int i = ikb_slot(kb); \
        if (i >= 0) g_ikb[i].member = fn; pthread_mutex_unlock(&g_ikb_mu); \
    }
IKB_CB("_ZN2nn5swkbd14InlineKeyboard29SetFinishedInitializeCallbackEPFvvE", h_ikb_SetInitialized, ikb_cb0, initialized)
IKB_CB("_ZN2nn5swkbd14InlineKeyboard27SetFinishedKeyboardCallbackEPFvvE", h_ikb_SetFinished, ikb_cb0, finished)
IKB_CB("_ZN2nn5swkbd14InlineKeyboard24SetDecidedCancelCallbackEPFvvE", h_ikb_SetCancel, ikb_cb0, cancel)
IKB_CB("_ZN2nn5swkbd14InlineKeyboard23SetDecidedEnterCallbackEPFvPKNS0_15DecidedEnterArgEE", h_ikb_SetEnter, ikb_cb, enter[0])
IKB_CB("_ZN2nn5swkbd14InlineKeyboard27SetDecidedEnterCallbackUtf8EPFvPKNS0_19DecidedEnterArgUtf8EE", h_ikb_SetEnter8, ikb_cb, enter[1])
IKB_CB("_ZN2nn5swkbd14InlineKeyboard24SetChangedStringCallbackEPFvPKNS0_16ChangedStringArgEE", h_ikb_SetChanged, ikb_cb, changed[0])
IKB_CB("_ZN2nn5swkbd14InlineKeyboard28SetChangedStringCallbackUtf8EPFvPKNS0_20ChangedStringArgUtf8EE", h_ikb_SetChanged8, ikb_cb, changed[1])
IKB_CB("_ZN2nn5swkbd14InlineKeyboard22SetMovedCursorCallbackEPFvPKNS0_14MovedCursorArgEE", h_ikb_SetMoved, ikb_cb, moved[0])
IKB_CB("_ZN2nn5swkbd14InlineKeyboard26SetMovedCursorCallbackUtf8EPFvPKNS0_18MovedCursorArgUtf8EE", h_ikb_SetMoved8, ikb_cb, moved[1])
#undef IKB_CB
HLE_FORCE("_ZN2nn5swkbd14InlineKeyboard11SetUtf8ModeEb", "内嵌键盘：选择回调文本编码", void, h_ikb_SetUtf8, void *kb, unsigned enabled) {
    pthread_mutex_lock(&g_ikb_mu);
    int i = ikb_slot(kb); if (i >= 0) g_ikb[i].utf8 = (enabled & 0xff) != 0;
    pthread_mutex_unlock(&g_ikb_mu);
}
HLE_FORCE("_ZN2nn5swkbd14InlineKeyboard6AppearERKNS0_9AppearArgE", "内嵌键盘：下一次 Calc 显示原生输入框", void, h_ikb_Appear, void *kb, const void *arg) {
    int32_t maxlen, minlen;
    memcpy(&maxlen, (const uint8_t *)arg + 0x20, 4);
    memcpy(&minlen, (const uint8_t *)arg + 0x24, 4);
    pthread_mutex_lock(&g_ikb_mu);
    int i = ikb_find(kb);
    if (i >= 0) {
        g_ikb[i].maxlen = maxlen > 0 && maxlen <= 500 ? maxlen : 500;
        g_ikb[i].minlen = minlen > 0 && minlen <= g_ikb[i].maxlen ? minlen : 0;
        g_ikb[i].pending = 1;
        g_ikb[i].epoch = ++g_ikb_epoch;
    }
    pthread_mutex_unlock(&g_ikb_mu);
    LOG("Inline keyboard requested native text input: object=%p max_length=%d min_length=%d", kb, maxlen, minlen);
}
HLE_FORCE("_ZN2nn5swkbd14InlineKeyboard9DisappearEv", "内嵌键盘：撤销待处理输入", void, h_ikb_Disappear, void *kb) {
    pthread_mutex_lock(&g_ikb_mu);
    int i = ikb_find(kb);
    if (i >= 0) { g_ikb[i].pending = 0; g_ikb[i].epoch = ++g_ikb_epoch; }
    pthread_mutex_unlock(&g_ikb_mu);
}
HLE_FORCE("_ZN2nn5swkbd14InlineKeyboard12SetInputTextERKNS0_9InputTextE", "内嵌键盘：保留初始文本", void, h_ikb_SetText, void *kb, const void *text) {
    pthread_mutex_lock(&g_ikb_mu);
    int i = ikb_slot(kb);
    if (i >= 0) { memcpy(g_ikb[i].text, text, 500 * 2); g_ikb[i].text[500] = 0; }
    pthread_mutex_unlock(&g_ikb_mu);
}
HLE_FORCE("_ZN2nn5swkbd14InlineKeyboard12SetCursorPosEi", "内嵌键盘：保留光标位置", void, h_ikb_SetCursor, void *kb, int pos) {
    pthread_mutex_lock(&g_ikb_mu);
    int i = ikb_slot(kb); if (i >= 0) g_ikb[i].cursor = pos;
    pthread_mutex_unlock(&g_ikb_mu);
}
static void ikb_calc(void *kb, swkbd_input_fn input) {
    // Heap storage also keeps this hook safe on small guest thread stacks.
    struct ikb_job { ikb_state s; char text[2004], initial[2004]; uint32_t reply[0x7e4 / 4]; };
    pthread_mutex_lock(&g_ikb_mu);
    int i = ikb_find(kb);
    if (i < 0 || (!g_ikb[i].pending && !g_ikb[i].init_pending)) { pthread_mutex_unlock(&g_ikb_mu); return; }
    struct ikb_job *job = calloc(1, sizeof *job);
    if (!job) { pthread_mutex_unlock(&g_ikb_mu); return; }
    job->s = g_ikb[i];
    g_ikb[i].init_pending = 0;
    if (!job->s.init_pending) g_ikb[i].pending = 0;
    pthread_mutex_unlock(&g_ikb_mu);
    ikb_state *s = &job->s;
    if (s->init_pending) {
        if (s->initialized) s->initialized();
        free(job); return;
    }
    if (!s->pending) { free(job); return; }
    swkbd_u16_to_u8(s->text, 500, job->initial, sizeof job->initial);
    const char *script = getenv("DM_KBD");
    char guide[128];
    snprintf(guide, sizeof guide, "Length: %d-%d characters", s->minlen, s->maxlen);
    if (!script) guest_clock_freeze_for(2, 1);
    int r;
    size_t units = 0;
    do {
        r = script ? (snprintf(job->text, sizeof job->text, "%s", script), 1)
                   : input("Text input", "", guide, job->initial, s->maxlen, job->text, sizeof job->text);
        if (r <= 0 || !ikb_current(s)) break;
        units = swkbd_u8_to_u16(job->text, s->maxlen, s->text, 501);
        swkbd_u16_to_u8(s->text, units, job->initial, sizeof job->initial);
        if (units >= (size_t)s->minlen) break;
        if (script) { r = 0; break; }
        snprintf(guide, sizeof guide, "Enter at least %d characters (maximum %d).", s->minlen, s->maxlen);
    } while (ikb_current(s));
    if (!script) guest_clock_freeze_for(2, 0);
    if (!ikb_current(s)) { free(job); return; }
    LOG("Inline keyboard completed: object=%p result=%s length=%zu", kb, r > 0 ? "accepted" : "cancelled", r > 0 ? units : 0);
    if (r <= 0) {
        if (s->cancel) s->cancel();
        free(job); return;
    }
    pthread_mutex_lock(&g_ikb_mu);
    i = ikb_find(kb);
    if (i >= 0 && g_ikb[i].epoch == s->epoch) memcpy(g_ikb[i].text, s->text, sizeof s->text);
    pthread_mutex_unlock(&g_ikb_mu);
    uint8_t *reply = (uint8_t *)job->reply;
    size_t text_size = s->utf8 ? 0x7d4 : 0x3ec;
    int32_t len = (int32_t)units, unmarked = -1;
    if (s->utf8) swkbd_u16_to_u8(s->text, units, (char *)reply, text_size);
    else memcpy(reply, s->text, (units + 1) * 2);
    memcpy(reply + text_size, &len, 4);
    memcpy(reply + text_size + 4, &unmarked, 4);
    memcpy(reply + text_size + 8, &unmarked, 4);
    memcpy(reply + text_size + 12, &len, 4);
    if (s->changed[s->utf8]) s->changed[s->utf8](reply);
    if (ikb_current(s) && s->enter[s->utf8]) s->enter[s->utf8](reply);
    free(job);
}
HLE_FORCE("_ZN2nn5swkbd14InlineKeyboard4CalcEv", "内嵌键盘：原生输入与游戏线程回调", void, h_ikb_Calc, void *kb) {
    ikb_calc(kb, front_text_input);
}
HLE_FORCE("_ZN2nn5swkbd14InlineKeyboard8GetImageEPvm", "内嵌键盘画面：由原生输入框代替", unsigned, h_ikb_GetImage, void *kb, void *buf, size_t n) { (void)kb; (void)buf; (void)n; return 0; }
HLE_FORCE("_ZNK2nn5swkbd14InlineKeyboard13GetWindowSizeEPiS2_", "内嵌键盘窗口尺寸：原生对话框不占游戏画面", void, h_ikb_WinSize, const void *kb, int *w, int *h) { (void)kb; if (w) *w = 0; if (h) *h = 0; }
