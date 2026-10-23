// Physical controller face button mapping (dm_padmap.h): each type x four face buttons -> game keys. Expected values are hand-written from
// the rule: whatever letter is printed is that game key; Nintendo glyphs are right A, bottom B, top X, left Y, Xbox glyphs are bottom A,
// right B, left X, top Y; everything else is laid out as Xbox.
#include <stdio.h>
#include "../dm_padmap.h"
static int checks, fails;
#define CHECK(c, ...) do { checks++; if (c) printf("  ✓ "); else { fails++; printf("  ✗ "); } printf(__VA_ARGS__); printf("\n"); } while (0)
int main(void) {
    struct { const char *cat, *ven; int kind; } id[] = {
        { "Switch Pro Controller", "Pro Controller", DM_PADKIND_NINTENDO }, { "Nintendo Switch Joy-Con (L/R)", "Joy-Con (L/R)", DM_PADKIND_NINTENDO },
        { "Nintendo Switch Joy-Con (L)", "Joy-Con (L)", DM_PADKIND_NINTENDO }, { "MFi", "NINTENDO compatible pad", DM_PADKIND_NINTENDO },
        { "Gamepad", "Pro Controller", DM_PADKIND_NINTENDO }, { "Gamepad", "Joy-Con (R)", DM_PADKIND_NINTENDO },
        { "Xbox One", "Xbox Wireless Controller", DM_PADKIND_XBOX }, { "DualSense", "DualSense Wireless Controller", DM_PADKIND_XBOX },
        { "DualShock 4", "DUALSHOCK 4 Wireless Controller", DM_PADKIND_XBOX }, { "MFi", "SteelSeries Nimbus", DM_PADKIND_XBOX }, { NULL, NULL, DM_PADKIND_XBOX }, { "", "", DM_PADKIND_XBOX } };
    for (unsigned i = 0; i < sizeof id / sizeof *id; i++) CHECK(dm_padmap_kind(id[i].cat, id[i].ven) == id[i].kind, "类别「%s」厂商名「%s」→ %s 排法", id[i].cat ? id[i].cat : "(空)", id[i].ven ? id[i].ven : "(空)", id[i].kind ? "任天堂" : "Xbox");
    CHECK(dm_padmap_should_auto_select(DM_PADKIND_XBOX, DM_PADKIND_NINTENDO, 0, 0), "没有当前手柄时允许选择首个 Nintendo 手柄");
    CHECK(dm_padmap_should_auto_select(DM_PADKIND_XBOX, DM_PADKIND_XBOX, 0, 0), "没有 Nintendo 手柄时允许选择首个通用手柄");
    CHECK(dm_padmap_should_auto_select(DM_PADKIND_XBOX, DM_PADKIND_NINTENDO, 1, 0), "NS Pro 接入时自动优先选中");
    CHECK(!dm_padmap_should_auto_select(DM_PADKIND_NINTENDO, DM_PADKIND_XBOX, 1, 0), "NS Pro 已选中时不被 DualSense 抢占");
    CHECK(!dm_padmap_should_auto_select(DM_PADKIND_XBOX, DM_PADKIND_NINTENDO, 1, 1), "手动选择锁定优先于自动切换");
    CHECK(dm_padmap_should_auto_select(DM_PADKIND_XBOX, DM_PADKIND_XBOX, 1, 0), "同类手柄仍可按最近输入切换");
    // bottom right left top
    CHECK(dm_padmap_face(DM_PADKIND_NINTENDO, 1, 0, 0, 0) == DM_BTN_B, "任天堂：下 = B"); CHECK(dm_padmap_face(DM_PADKIND_NINTENDO, 0, 1, 0, 0) == DM_BTN_A, "任天堂：右 = A");
    CHECK(dm_padmap_face(DM_PADKIND_NINTENDO, 0, 0, 1, 0) == DM_BTN_Y, "任天堂：左 = Y"); CHECK(dm_padmap_face(DM_PADKIND_NINTENDO, 0, 0, 0, 1) == DM_BTN_X, "任天堂：上 = X");
    CHECK(dm_padmap_face(DM_PADKIND_XBOX, 1, 0, 0, 0) == DM_BTN_A, "Xbox：下 = A"); CHECK(dm_padmap_face(DM_PADKIND_XBOX, 0, 1, 0, 0) == DM_BTN_B, "Xbox：右 = B");
    CHECK(dm_padmap_face(DM_PADKIND_XBOX, 0, 0, 1, 0) == DM_BTN_X, "Xbox：左 = X"); CHECK(dm_padmap_face(DM_PADKIND_XBOX, 0, 0, 0, 1) == DM_BTN_Y, "Xbox：上 = Y");
    CHECK(dm_padmap_face(DM_PADKIND_XBOX, 1, 1, 0, 0) == (DM_BTN_A | DM_BTN_B), "两颗同时按：各算各的"); CHECK(dm_padmap_face(DM_PADKIND_NINTENDO, 0, 0, 0, 0) == 0, "都没按 = 0");
    printf("== %d 项，失败 %d ==\n", checks, fails);
    return fails != 0;
}
