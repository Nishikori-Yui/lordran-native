// Service clocks and calendar conversion must keep working after removing
// unrelated titles' fixed-address clock hooks.
#include "../hle_time.c"

#define CHECK(c) do { checks++; if (!(c)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); return 1; } } while (0)

int main(int argc, char **argv) {
    int checks = 0;
    int fixed = argc == 2 && !strcmp(argv[1], "fixed");
    if (fixed) setenv("DM_FIXED_TIME", "1704067200", 1);
    else unsetenv("DM_FIXED_TIME");

    CHECK(sizeof(CalendarTime) == 8);
    CHECK(sizeof(CalendarAdditionalInfo) == 24);
    CHECK(h_time_Initialize() == RES_OK && h_time_IsInitialized());
    int64_t before = time(NULL), current = 0;
    CHECK(h_time_GetCurrentTime(&current) == RES_OK);
    int64_t now = h_time_now(), after = time(NULL);
    if (fixed) CHECK(current == 1704067200 && now == 1704067200);
    else CHECK(current >= before && current <= after && now >= before && now <= after);
    CHECK(h_time_to_time_t(&current) == current);

    uint8_t steady[24];
    int64_t mono_before = clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1000000000ull;
    CHECK(h_time_SteadyNow(steady) == RES_OK);
    int64_t seconds; memcpy(&seconds, steady, sizeof seconds);
    int64_t mono_after = clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1000000000ull;
    CHECK(seconds >= mono_before && seconds <= mono_after);
    CHECK(!memcmp(steady + 8, "dmhost-steady-01", 16));

    setenv("TZ", "America/New_York", 1); tzset();
    int64_t epoch = 1704067200;
    CalendarTime ct; CalendarAdditionalInfo ai;
    CHECK(h_time_ToCalendarTime(&ct, &ai, &epoch) == RES_OK);
    CHECK(ct.year == 2023 && ct.month == 12 && ct.day == 31);
    CHECK(ct.hour == 19 && ct.minute == 0 && ct.second == 0);
    CHECK(ai.wday == 0 && ai.yday == 364 && !ai.dst && ai.offset == -18000);
    CHECK(!strcmp(ai.tzname, "EST"));
    int count = -1; int64_t roundtrip = -1;
    CHECK(h_time_ToPosixTime(&count, &roundtrip, 1, &ct) == RES_OK);
    CHECK(count == 1 && roundtrip == epoch);
    CHECK(h_time_ToPosixTime(&count, NULL, 0, &ct) == RES_OK && count == 0);
    CHECK(h_time_ToCalendarTime(NULL, NULL, &epoch) == RES_OK);
    struct tm local;
    CHECK(h_localtime_r(&epoch, &local) == &local);
    CHECK(local.tm_year == 123 && local.tm_mon == 11 && local.tm_mday == 31 && local.tm_hour == 19);
    CHECK(h_mktime(&local) == epoch);
    CHECK(h_localtime(&epoch)->tm_hour == 19);

    printf("time %s: %d checks passed\n", fixed ? "fixed" : "live", checks);
    return 0;
}
