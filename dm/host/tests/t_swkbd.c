// swkbd unit test (takes seconds): lay out a ShowKeyboardArg by hand following the SDK layout, have swkbd_show write back the String, and all expected bytes are computed by hand.
// Build: make -C dm/host/tests GAME=<title ID> build/t_swkbd
#include "../hle.h"
#include <stdio.h>
#include "../hle_swkbd.c"

Result swkbd_show(void *out, const void *arg, int (*input)(const char *, const char *, const char *, const char *, int, char *, int));
int front_text_input(const char *t, const char *s, const char *g, const char *i, int m, char *o, int c) { (void)t; (void)s; (void)g; (void)i; (void)m; (void)o; (void)c; return -1; }

static int fails, checks;
#define CHECK(c, ...) do { checks++; if (!(c)) { fails++; printf("  ✗ "); printf(__VA_ARGS__); printf("\n"); } } while (0)

// Input stub: record the arguments received and return as configured
static const char *g_reply; static int g_ret, g_called; static char g_title[256], g_init[256]; static int g_max;
static void *finalize_during_input;
static int stub(const char *t, const char *s, const char *g, const char *i, int m, char *o, int c) {
    (void)s; (void)g; g_called++; snprintf(g_title, sizeof g_title, "%s", t); snprintf(g_init, sizeof g_init, "%s", i); g_max = m;
    if (g_ret > 0) snprintf(o, c, "%s", g_reply);
    if (finalize_during_input) h_ikb_Fin(finalize_during_input);
    return g_ret;
}

static uint8_t arg[0x500], work[0x1000], sbuf[0x7d4];
static struct { uint8_t *p; uint64_t n; } str = {sbuf, sizeof sbuf};
static void mkarg(int utf8, int maxlen, const uint16_t *init, int ilen) {
    memset(arg, 0, sizeof arg); memset(work, 0, sizeof work); memset(sbuf, 0xAA, sizeof sbuf);
    static const uint16_t title[] = {0x8D77, 0x540D, 0};                 // 「起名」(Name your character)
    memcpy(arg + 0x24, title, sizeof title);
    memcpy(arg + 0x3ac, &maxlen, 4); arg[0x3bd] = (uint8_t)utf8;
    int off = 0x14; memcpy(arg + 0x3c0, &off, 4); memcpy(arg + 0x3c4, &ilen, 4);   // the way SetInitialTextUtf8 writes it
    memcpy(work + off, init, (size_t)ilen * 2);
    uint8_t *w = work; memcpy(arg + 0x4d0, &w, 8);
    g_called = 0;
}
static int bytes_eq(const uint8_t *want, size_t n) {   // the first n bytes equal the expectation, and everything after to the end of the buffer is 0
    if (memcmp(sbuf, want, n)) return 0;
    for (size_t i = n; i < sizeof sbuf; i++) if (sbuf[i]) return 0;
    return 1;
}

void guest_clock_freeze_for(int reason, int on) { (void)reason; (void)on; }   // the real implementation is in hle_os.c; the unit test does not care about the clock
static int enters, changes, cancels, initialized, callback_utf8, invalidate_on_change;
static char callback_text[2004];
static int32_t callback_len, callback_cursor, composition_begin, composition_end;
static void *callback_kb;
static pthread_t calc_thread;
static void entered(const void *p) {
    enters++;
    CHECK(pthread_equal(pthread_self(), calc_thread), "Callback left the Calc thread");
    size_t off = callback_utf8 ? 0x7d4 : 0x3ec;
    memcpy(&callback_len, (const uint8_t *)p + off, 4);
    if (callback_utf8) snprintf(callback_text, sizeof callback_text, "%s", (const char *)p);
    else swkbd_u16_to_u8(p, 501, callback_text, sizeof callback_text);
}
static void changed(const void *p) {
    changes++;
    size_t off = callback_utf8 ? 0x7d4 : 0x3ec;
    memcpy(&composition_begin, (const uint8_t *)p + off + 4, 4);
    memcpy(&composition_end, (const uint8_t *)p + off + 8, 4);
    memcpy(&callback_cursor, (const uint8_t *)p + off + 12, 4);
    if (invalidate_on_change) h_ikb_Fin(callback_kb);
}
static void canceled(void) { cancels++; }
static void ready(void) { initialized++; }
static void appear(void *kb, int maxlen, int minlen) {
    uint8_t a[0x48] = {0};
    memcpy(a + 0x20, &maxlen, 4);
    memcpy(a + 0x24, &minlen, 4);
    h_ikb_Appear(kb, a);
}
static void inline_tests(void) {
    int kb;
    callback_kb = &kb; calc_thread = pthread_self();
    h_ikb_Init(&kb, NULL);
    h_ikb_SetInitialized(&kb, ready);
    h_ikb_SetEnter(&kb, entered); h_ikb_SetEnter8(&kb, entered);
    h_ikb_SetChanged(&kb, changed); h_ikb_SetChanged8(&kb, changed);
    h_ikb_SetCancel(&kb, canceled);
    h_ikb_Launch(&kb);
    ikb_calc(&kb, stub); ikb_calc(&kb, stub);
    CHECK(initialized == 1, "Launch initialization callback count %d", initialized);

    uint16_t initial[501] = {'H', 'e', 'r', 'o'};
    h_ikb_SetText(&kb, initial);
    appear(&kb, 10, 1);
    g_ret = 1; g_reply = "A\xE5\x90\x8D\xF0\x9F\x98\x80";
    ikb_calc(&kb, stub); ikb_calc(&kb, stub);
    CHECK(enters == 1 && changes == 1 && cancels == 0, "Inline UTF-16 callback counts");
    CHECK(!strcmp(g_init, "Hero") && g_max == 10, "Inline initial text / maximum");
    CHECK(!strcmp(callback_text, g_reply) && callback_len == 4, "Inline UTF-16 payload / length");
    CHECK(callback_cursor == 4 && composition_begin == -1 && composition_end == -1, "Inline changed cursor / composition");

    appear(&kb, 10, 1); g_ret = 0;
    ikb_calc(&kb, stub);
    CHECK(cancels == 1 && enters == 1 && changes == 1, "Cancel must not change text");
    CHECK(!strcmp(g_init, "A\xE5\x90\x8D\xF0\x9F\x98\x80"), "Cancel / reopen lost the last name");

    h_ikb_SetUtf8(&kb, 1); callback_utf8 = 1;
    appear(&kb, 2, 0); g_ret = 1;
    ikb_calc(&kb, stub);
    CHECK(enters == 2 && callback_len == 2 && !strcmp(callback_text, "A\xE5\x90\x8D"), "Inline UTF-8 truncation / payload");
    CHECK(callback_cursor == 2, "Inline UTF-8 cursor");

    appear(&kb, 2, 0); h_ikb_Disappear(&kb);
    int calls = g_called; ikb_calc(&kb, stub);
    CHECK(g_called == calls && enters == 2 && cancels == 1, "Disappear must retract input without a cancel event");

    setenv("DM_KBD", "Script", 1); appear(&kb, 10, 0); ikb_calc(&kb, stub);
    CHECK(g_called == calls && enters == 3 && !strcmp(callback_text, "Script"), "Inline scripted input");
    setenv("DM_KBD", "", 1); appear(&kb, 10, 2); ikb_calc(&kb, stub);
    CHECK(cancels == 2 && enters == 3, "Scripted input must respect minimum length");
    unsetenv("DM_KBD");

    appear(&kb, 10, 0); finalize_during_input = &kb;
    ikb_calc(&kb, stub); finalize_during_input = NULL;
    CHECK(enters == 3 && cancels == 2, "Finalized keyboard delivered a stale result");
    ikb_calc(&kb, stub);
    CHECK(ikb_find(&kb) < 0, "Calc resurrected a finalized keyboard");

    h_ikb_Init(&kb, NULL); h_ikb_SetEnter(&kb, entered); h_ikb_SetChanged(&kb, changed);
    appear(&kb, 10, 0); invalidate_on_change = 1;
    ikb_calc(&kb, stub); invalidate_on_change = 0;
    CHECK(enters == 3, "Changed callback finalized keyboard but enter still fired");
    h_ikb_Fin(&kb);
    for (int i = 0; i < 12; i++) { CHECK(h_ikb_Init(&kb, NULL), "Inline lifecycle leaked a slot"); h_ikb_Dtor(&kb); }
}
int main(void) {
    unsetenv("DM_KBD");
    static const uint16_t hero[] = {'H', 'e', 'r', 'o'};

    printf("1 确定、UTF-8 输出（游戏实际用法）\n");
    mkarg(1, 16, hero, 4); g_ret = 1; g_reply = "Ünï名";
    Result r = swkbd_show(&str, arg, stub);
    static const uint8_t w1[] = {0xC3, 0x9C, 0x6E, 0xC3, 0xAF, 0xE5, 0x90, 0x8D, 0x00};   // U+00DC n U+00EF U+540D + terminating 0
    CHECK(r == 0, "Result %#x 期望 0", r);
    CHECK(bytes_eq(w1, sizeof w1), "UTF-8 回写字节不符");
    CHECK(!strcmp(g_title, "\xE8\xB5\xB7\xE5\x90\x8D"), "标题解出「%s」期望「起名」", g_title);
    CHECK(!strcmp(g_init, "Hero"), "初始文本解出「%s」期望 Hero", g_init);
    CHECK(g_max == 16, "上限 %d 期望 16", g_max);

    printf("2 取消 → 0x29F，缓冲不动\n");
    mkarg(1, 16, hero, 4); g_ret = 0;
    r = swkbd_show(&str, arg, stub);
    CHECK(r == 0x29F, "Result %#x 期望 0x29F", r);
    CHECK(sbuf[0] == 0xAA && sbuf[sizeof sbuf - 1] == 0xAA, "取消时改了缓冲");

    printf("3 无窗口（输入返回 -1）→ 按取消 0x29F\n");
    mkarg(1, 16, hero, 4); g_ret = -1;
    CHECK(swkbd_show(&str, arg, stub) == 0x29F, "无窗口未按取消返回");

    printf("4 UTF-16 输出（isUseUtf8 = 0）\n");
    mkarg(0, 16, hero, 0); g_ret = 1; g_reply = "A名";
    r = swkbd_show(&str, arg, stub);
    static const uint8_t w4[] = {0x41, 0x00, 0x0D, 0x54, 0x00, 0x00};   // 'A' U+540D terminating 0 (little endian)
    CHECK(r == 0 && bytes_eq(w4, sizeof w4), "UTF-16 回写字节不符");
    CHECK(g_init[0] == 0, "初始长度 0 时应无初始文本");

    printf("5 最大长度截断（3 字）\n");
    mkarg(1, 3, hero, 4); g_ret = 1; g_reply = "ABCDE";
    swkbd_show(&str, arg, stub);
    static const uint8_t w5[] = {'A', 'B', 'C', 0};
    CHECK(bytes_eq(w5, sizeof w5), "截断结果不符");

    printf("6 截断不拆代理对（上限 2 单元，a + U+1F600 需 3 单元）\n");
    mkarg(1, 2, hero, 4); g_ret = 1; g_reply = "a\xF0\x9F\x98\x80";
    swkbd_show(&str, arg, stub);
    static const uint8_t w6[] = {'a', 0};
    CHECK(bytes_eq(w6, sizeof w6), "代理对被拆或未截断");

    printf("7 DM_KBD 直给文本：不调输入框\n");
    setenv("DM_KBD", "Kbd", 1);
    mkarg(1, 16, hero, 4); g_ret = 0;
    r = swkbd_show(&str, arg, stub);
    static const uint8_t w7[] = {'K', 'b', 'd', 0};
    CHECK(r == 0 && bytes_eq(w7, sizeof w7) && g_called == 0, "DM_KBD 路径不符（调用输入框 %d 次）", g_called);
    unsetenv("DM_KBD");

    printf("8 Inline keyboard callbacks, text, cancellation and lifecycle\n");
    inline_tests();
    printf("%s：%d/%d\n", fails ? "红" : "全过", checks - fails, checks);
    return fails != 0;
}
