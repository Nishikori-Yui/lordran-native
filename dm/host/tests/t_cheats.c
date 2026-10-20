#include "../cheats.h"
#include "game_profile.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const struct { const char *id, *version; } builds[] = {DM_GAME_DISPLAY_VERSIONS};
static void write_manifest(const char *path, const char *build, const char *rows) {
    FILE *f = fopen(path, "w"); assert(f);
    fprintf(f, "# BUILD_ID\t%s\n%s", build, rows); fclose(f);
}
int main(void) {
    char path[] = "/tmp/dm-cheats-XXXXXX";
    int fd = mkstemp(path); assert(fd >= 0); close(fd);
    uint32_t flags[2] = {55, 66};
    assert(dm_cheats_load(NULL, 0, NULL, NULL) && dm_cheat_count() == 0);
    assert(!dm_cheat_set(0, 1) && !dm_cheat_enabled(0) && !*dm_cheat_name(0));
    write_manifest(path, builds[0].id, "0\t0\tExample\n1\t1\tSecond\n");
    assert(dm_cheats_load(flags, 2, builds[0].id, path));
    assert(dm_cheat_count() == 2 && flags[0] == 0 && flags[1] == 1);
    assert(!strcmp(dm_cheat_name(1), "Second") && dm_cheat_enabled(1));
    assert(dm_cheat_set(0, 1) && flags[0] == 1);
    assert(dm_cheat_set(1, 0) && flags[1] == 0);
    assert(!dm_cheat_set(2, 1) && !*dm_cheat_name(2));
    assert(!dm_cheats_load(flags, DM_CHEAT_MAX + 1, builds[0].id, path));
    assert(!dm_cheats_load(flags, 2, "unregistered", path));
    assert(!dm_cheats_load(flags, 2, builds[1].id, path));
    const char *bad[] = {
        "1\t0\tWrong index\n", "0\t2\tInvalid state\n", "0\t0\t\n",
        "0\t0\tValid\n1\t0\tUnexpected\n", "0\t0\tBad\tname\n",
        "0\t0\tBad\rhidden\n", "0\t0\t\xc0\xaf\n", "0\t0\t\xed\xa0\x80\n",
        "0\t0\t\xf4\x90\x80\x80\n", ""
    };
    for (unsigned i = 0; i < sizeof bad / sizeof *bad; i++) {
        flags[0] = 77;
        write_manifest(path, builds[0].id, bad[i]);
        assert(!dm_cheats_load(flags, 1, builds[0].id, path));
        assert(dm_cheat_count() == 0 && flags[0] == 77);
    }
    write_manifest(path, builds[0].id, "0\t1\t\xe9\xad\x82\r\n");
    assert(dm_cheats_load(flags, 1, builds[0].id, path) && dm_cheat_enabled(0));
    unlink(path);
    puts("PASS: runtime cheat manifest guards and live atomic state");
}
