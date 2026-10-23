// Map GameController's positional face buttons to the game's button labels.
// buttonA/B/X/Y are bottom/right/left/top. Nintendo glyphs use right A,
// bottom B, top X, left Y; other and unrecognized controllers use Xbox layout.
// Recognize Nintendo pads from product category or vendor name, including
// generic "Pro Controller" and "Joy-Con" names reported by macOS.
#pragma once
#include <stdint.h>
#include <string.h>
#include <strings.h>
#include "dm_input.h"
enum { DM_PADKIND_XBOX = 0, DM_PADKIND_NINTENDO = 1 };
static inline int dm_padmap_has(const char *s, const char *w) { size_t n = strlen(w); for (; s && *s; s++) if (!strncasecmp(s, w, n)) return 1; return 0; }
static inline int dm_padmap_kind(const char *category, const char *vendor) {
    static const char *const k[] = { "switch", "nintendo", "joy-con", "pro controller" };
    for (unsigned i = 0; i < sizeof k / sizeof *k; i++) if (dm_padmap_has(category, k[i]) || dm_padmap_has(vendor, k[i])) return DM_PADKIND_NINTENDO;
    return DM_PADKIND_XBOX;
}
static inline int dm_padmap_should_auto_select(int current_kind, int candidate_kind,
                                               int has_current, int selection_locked) {
    if (selection_locked) return 0;
    if (!has_current || current_kind == candidate_kind) return 1;
    return current_kind != DM_PADKIND_NINTENDO || candidate_kind == DM_PADKIND_NINTENDO;
}
static inline uint64_t dm_padmap_face(int kind, int south, int east, int west, int north) {   // The four parameters = whether the bottom / right / left / top button is held
    if (kind == DM_PADKIND_NINTENDO) return (east ? DM_BTN_A : 0) | (south ? DM_BTN_B : 0) | (north ? DM_BTN_X : 0) | (west ? DM_BTN_Y : 0);
    return (south ? DM_BTN_A : 0) | (east ? DM_BTN_B : 0) | (west ? DM_BTN_X : 0) | (north ? DM_BTN_Y : 0);
}
