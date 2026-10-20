#include "../dm_movie_sps.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

typedef struct { uint8_t data[512]; unsigned bits; } writer;
static void bits(writer *w, uint32_t value, unsigned count) {
    assert(w->bits + count <= sizeof w->data * 8);
    for (unsigned i = count; i; i--, w->bits++)
        w->data[w->bits / 8] |= ((value >> (i - 1)) & 1) << (7 - w->bits % 8);
}
static void ue(writer *w, uint32_t value) {
    unsigned n = 0; for (uint32_t v = value + 1; v; v >>= 1) n++;
    bits(w, 0, n - 1); bits(w, value + 1, n);
}
static void hrd(writer *w) {
    ue(w, 1); bits(w, 0, 8);
    for (unsigned i = 0; i < 2; i++) { ue(w, i); ue(w, i); bits(w, 1, 1); }
    bits(w, 0, 20);
}
static size_t sps(uint8_t *out, unsigned reorder, unsigned buffering, int high, int extras, int vui) {
    writer w = {0};
    bits(&w, high ? 100 : 66, 8); bits(&w, 0, 8); bits(&w, 40, 8); ue(&w, 0);
    if (high) {
        ue(&w, 1); ue(&w, 0); ue(&w, 0); bits(&w, 0, 1); bits(&w, extras, 1);
        if (extras) for (int i = 0; i < 8; i++) {
            bits(&w, i == 0, 1);
            if (i == 0) for (int j = 0; j < 16; j++) ue(&w, 0);
        }
    }
    ue(&w, 0); ue(&w, extras ? 1 : 0);
    if (extras) { bits(&w, 0, 1); ue(&w, 0); ue(&w, 0); ue(&w, 2); ue(&w, 0); ue(&w, 0); }
    else ue(&w, 0);
    ue(&w, 4); bits(&w, 0, 1); ue(&w, 119); ue(&w, 67);
    bits(&w, !extras, 1); if (extras) bits(&w, 0, 1);
    bits(&w, 1, 1); bits(&w, extras, 1);
    if (extras) for (int i = 0; i < 4; i++) ue(&w, 0);
    bits(&w, vui, 1);
    if (vui) {
        bits(&w, extras, 1);
        if (extras) { bits(&w, 255, 8); bits(&w, 1, 16); bits(&w, 1, 16); }
        bits(&w, extras, 1); if (extras) bits(&w, 0, 1);
        bits(&w, extras, 1); if (extras) { bits(&w, 11, 5); bits(&w, 0x010101, 24); }
        bits(&w, extras, 1); if (extras) { ue(&w, 0); ue(&w, 0); }
        bits(&w, 1, 1); bits(&w, 1001, 32); bits(&w, 60000, 32); bits(&w, 1, 1);
        bits(&w, extras, 1); if (extras) hrd(&w);
        bits(&w, extras, 1); if (extras) hrd(&w);
        if (extras) bits(&w, 0, 1);
        bits(&w, 0, 1); bits(&w, 1, 1); bits(&w, 1, 1);
        for (int i = 0; i < 4; i++) ue(&w, 0);
        ue(&w, reorder); ue(&w, buffering);
    }
    bits(&w, 1, 1);
    while (w.bits % 8) bits(&w, 0, 1);
    size_t size = 1; out[0] = 0x67; unsigned zeros = 0;
    for (unsigned i = 0; i < w.bits / 8; i++) {
        if (zeros == 2 && w.data[i] <= 3) { out[size++] = 3; zeros = 0; }
        out[size++] = w.data[i]; zeros = w.data[i] ? 0 : zeros + 1;
    }
    return size;
}
int main(void) {
    uint8_t data[1024];
    assert(dm_movie_sps_reorder(NULL, 0) == 16);
    for (int high = 0; high <= 1; high++) for (int extras = 0; extras <= 1; extras++) {
        for (unsigned reorder = 0; reorder <= 16; reorder++) {
            size_t n = sps(data, reorder, 16, high, extras, 1);
            assert(dm_movie_sps_reorder(data, n) == (int)reorder);
        }
        size_t n = sps(data, 2, 4, high, extras, 1);
        assert(dm_movie_sps_reorder(data, n) == 2);
        // Truncating any byte before the VUI limit must not expose a low limit.
        for (size_t k = 0; k + 1 < n; k++) assert(dm_movie_sps_reorder(data, k) == 16);
        n = sps(data, 2, 4, high, extras, 0);
        assert(dm_movie_sps_reorder(data, n) == 16);
        n = sps(data, 5, 4, high, extras, 1);
        assert(dm_movie_sps_reorder(data, n) == 16);
        n = sps(data, 1, 2, high, extras, 1);
        assert(dm_movie_sps_reorder(data, n) == 16);
    }
    memset(data, 0, sizeof data); data[0] = 0x67;
    assert(dm_movie_sps_reorder(data, sizeof data) == 16);
    puts("movie SPS: reorder limits, optional syntax, escaping and truncation passed");
    return 0;
}
