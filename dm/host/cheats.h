#pragma once
#include <stdint.h>

#define DM_CHEAT_MAX 256
// Called once during loading, before any guest or UI can access the flags.
int dm_cheats_load(uint32_t *flags, unsigned count, const char *build_id, const char *manifest);
unsigned dm_cheat_count(void);
const char *dm_cheat_name(unsigned index);
int dm_cheat_enabled(unsigned index);
int dm_cheat_set(unsigned index, int enabled);
