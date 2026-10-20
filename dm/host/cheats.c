#include "cheats.h"
#include "dm_log.h"
#include "game_profile.h"
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

static _Atomic unsigned g_count;
static _Atomic uint32_t *g_flags;
enum { DM_CHEAT_NAME_MAX = 512 };
static char g_names_en[DM_CHEAT_MAX][DM_CHEAT_NAME_MAX];
static char g_names_zh[DM_CHEAT_MAX][DM_CHEAT_NAME_MAX];

static int known_build(const char *build) {
    static const struct { const char *id, *version; } builds[] = {DM_GAME_DISPLAY_VERSIONS};
    for (unsigned i = 0; i < sizeof builds / sizeof *builds; i++)
        if (!strcmp(build, builds[i].id)) return 1;
    return 0;
}

static int valid_name(const char *name) {
    const unsigned char *s = (const unsigned char *)name;
    size_t length = strlen(name);
    if (!length || length >= DM_CHEAT_NAME_MAX) return 0;
    for (size_t i = 0; i < length;) {
        uint32_t c = s[i++];
        if (c < 128) { if (c < 32 || c == 127) return 0; continue; }
        unsigned n = c >= 0xC2 && c <= 0xDF ? 1 : c >= 0xE0 && c <= 0xEF ? 2 : c >= 0xF0 && c <= 0xF4 ? 3 : 0;
        if (!n || i + n > length) return 0;
        uint32_t minimum = n == 1 ? 0x80 : n == 2 ? 0x800 : 0x10000;
        c &= (1u << (6 - n)) - 1;
        for (unsigned j = 0; j < n; j++) {
            unsigned b = s[i++];
            if ((b & 0xC0) != 0x80) return 0;
            c = (c << 6) | (b & 63);
        }
        if (c < minimum || c > 0x10FFFF || (c >= 0xD800 && c <= 0xDFFF)) return 0;
    }
    return 1;
}

static int read_line(FILE *file, char **line, size_t *capacity) {
    ssize_t n = getline(line, capacity, file);
    if (n < 0) return feof(file) ? 0 : -1;
    if (n > 1024 || memchr(*line, '\0', (size_t)n)) return -1;
    if (n && (*line)[n - 1] == '\n') (*line)[--n] = '\0';
    if (n && (*line)[n - 1] == '\r') (*line)[--n] = '\0';
    if (memchr(*line, '\r', (size_t)n) || memchr(*line, '\n', (size_t)n)) return -1;
    return 1;
}

int dm_cheats_load(uint32_t *flags, unsigned count, const char *build_id, const char *manifest) {
    atomic_store_explicit(&g_count, 0, memory_order_release);
    g_flags = NULL;
    if (!count) return 1;
    if (!flags || (uintptr_t)flags % _Alignof(_Atomic uint32_t) || count > DM_CHEAT_MAX ||
        !build_id || !known_build(build_id) || !manifest) return 0;
    FILE *file = fopen(manifest, "r");
    if (!file) return 0;
    char *line = NULL; size_t capacity = 0;
    char header[80]; snprintf(header, sizeof header, "# BUILD_ID\t%s", build_id);
    uint32_t initial[DM_CHEAT_MAX];
    int ok = read_line(file, &line, &capacity) == 1 && !strcmp(line, header);
    for (unsigned i = 0; ok && i < count; i++) {
        if (read_line(file, &line, &capacity) != 1) { ok = 0; break; }
        char *state = strchr(line, '\t');
        if (!state) { ok = 0; break; }
        *state++ = '\0';
        char *name = strchr(state, '\t');
        if (!name) { ok = 0; break; }
        *name++ = '\0';
        char index[16]; snprintf(index, sizeof index, "%u", i);
        if (strcmp(line, index) || (strcmp(state, "0") && strcmp(state, "1")) || !valid_name(name)) {
            ok = 0; break;
        }
        initial[i] = state[0] == '1';
        char localized[DM_CHEAT_NAME_MAX];
        strlcpy(localized, name, sizeof localized);
        char *language_split = strstr(localized, "//");
        if (language_split) {
            *language_split = '\0';
            const char *fallback = localized[0] ? localized : language_split + 2;
            const char *chinese = localized[0] ? localized : fallback;
            const char *english = language_split[2] ? language_split + 2 : fallback;
            strlcpy(g_names_zh[i], chinese, sizeof g_names_zh[i]);
            strlcpy(g_names_en[i], english, sizeof g_names_en[i]);
        } else {
            strlcpy(g_names_zh[i], name, sizeof g_names_zh[i]);
            strlcpy(g_names_en[i], name, sizeof g_names_en[i]);
        }
    }
    if (ok && read_line(file, &line, &capacity) != 0) ok = 0;
    free(line); fclose(file);
    if (!ok) return 0;
    g_flags = (_Atomic uint32_t *)flags;
    for (unsigned i = 0; i < count; i++) atomic_store_explicit(&g_flags[i], initial[i], memory_order_relaxed);
    atomic_store_explicit(&g_count, count, memory_order_release);
    DM_LOG_INFO("cheats", "Runtime cheat groups loaded: count=%u build_id=%s", count, build_id);
    return 1;
}

unsigned dm_cheat_count(void) { return atomic_load_explicit(&g_count, memory_order_acquire); }
const char *dm_cheat_name(unsigned index) {
    if (index >= dm_cheat_count()) return "";
    const char *language = getenv("DM_LANG");
    return language && !strncasecmp(language, "zh", 2) ? g_names_zh[index] : g_names_en[index];
}
int dm_cheat_enabled(unsigned index) {
    return index < dm_cheat_count() && atomic_load_explicit(&g_flags[index], memory_order_relaxed) != 0;
}
int dm_cheat_set(unsigned index, int enabled) {
    if (index >= dm_cheat_count()) return 0;
    atomic_store_explicit(&g_flags[index], enabled != 0, memory_order_relaxed);
    DM_LOG_INFO("cheats", "Runtime cheat changed: index=%u enabled=%d", index, enabled != 0);
    return 1;
}
