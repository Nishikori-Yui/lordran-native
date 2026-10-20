#pragma once
#include <stdint.h>
#include <stdlib.h>

// Read only the SPS fields needed to reach VUI's reorder limit (H.264 E.1.1).
// Unspecified or malformed limits retain the maximum legal frame window.
typedef struct { const uint8_t *data; size_t bits, pos; int failed; } dm_sps_bits;
static uint32_t dm_sps_read(dm_sps_bits *b, unsigned count) {
    if (count > 32 || count > b->bits - b->pos) { b->failed = 1; return 0; }
    uint32_t value = 0;
    while (count--) { value = value << 1 | ((b->data[b->pos / 8] >> (7 - b->pos % 8)) & 1); b->pos++; }
    return value;
}
static uint32_t dm_sps_ue(dm_sps_bits *b) {
    unsigned zeros = 0;
    while (!b->failed && !dm_sps_read(b, 1)) {
        if (++zeros > 31) { b->failed = 1; return 0; }
    }
    return ((uint32_t)1 << zeros) - 1 + dm_sps_read(b, zeros);
}
static void dm_sps_scaling(dm_sps_bits *b, unsigned count) {
    int last = 8, next = 8;
    for (unsigned i = 0; i < count && !b->failed; i++) {
        if (next) {
            uint32_t code = dm_sps_ue(b);
            int64_t delta = code & 1 ? ((int64_t)code + 1) / 2 : -(int64_t)code / 2;
            next = (int)((last + delta) & 255);
        }
        if (next) last = next;
    }
}
static void dm_sps_hrd(dm_sps_bits *b) {
    uint32_t count = dm_sps_ue(b);
    if (count > 31) { b->failed = 1; return; }
    dm_sps_read(b, 8);
    for (uint32_t i = 0; i <= count; i++) { dm_sps_ue(b); dm_sps_ue(b); dm_sps_read(b, 1); }
    dm_sps_read(b, 20);
}
static int dm_movie_sps_reorder(const uint8_t *nal, size_t size) {
    if (!nal || size < 4 || size > 65535 || (nal[0] & 0x9f) != 7 || !(nal[0] & 0x60)) return 16;
    uint8_t *rbsp = malloc(size);
    if (!rbsp) return 16;
    size_t n = 0; unsigned zeros = 0;
    for (size_t i = 1; i < size; i++) {
        if (zeros == 2 && nal[i] == 3) {
            if (i + 1 == size || nal[i + 1] > 3) { free(rbsp); return 16; }
            zeros = 0; continue;
        }
        rbsp[n++] = nal[i]; zeros = nal[i] ? 0 : zeros + 1;
    }
    dm_sps_bits b = {.data = rbsp, .bits = n * 8};
    unsigned profile = dm_sps_read(&b, 8);
    dm_sps_read(&b, 16); dm_sps_ue(&b);
    switch (profile) {
        case 44: case 83: case 86: case 100: case 110: case 118: case 122:
        case 128: case 134: case 135: case 138: case 139: case 244: {
            unsigned chroma = dm_sps_ue(&b);
            if (chroma > 3) b.failed = 1;
            if (chroma == 3) dm_sps_read(&b, 1);
            dm_sps_ue(&b); dm_sps_ue(&b); dm_sps_read(&b, 1);
            if (dm_sps_read(&b, 1))
                for (unsigned i = 0; i < (chroma == 3 ? 12u : 8u); i++)
                    if (dm_sps_read(&b, 1)) dm_sps_scaling(&b, i < 6 ? 16 : 64);
            break;
        }
        default: if (profile != 66 && profile != 77 && profile != 88) b.failed = 1;
    }
    dm_sps_ue(&b);
    unsigned poc = dm_sps_ue(&b);
    if (!poc) dm_sps_ue(&b);
    else if (poc == 1) {
        dm_sps_read(&b, 1); dm_sps_ue(&b); dm_sps_ue(&b);
        unsigned cycle = dm_sps_ue(&b);
        if (cycle > 255) b.failed = 1;
        for (unsigned i = 0; i < cycle && !b.failed; i++) dm_sps_ue(&b);
    } else if (poc != 2) b.failed = 1;
    unsigned refs = dm_sps_ue(&b);
    dm_sps_read(&b, 1); dm_sps_ue(&b); dm_sps_ue(&b);
    if (!dm_sps_read(&b, 1)) dm_sps_read(&b, 1);
    dm_sps_read(&b, 1);
    if (dm_sps_read(&b, 1)) for (unsigned i = 0; i < 4; i++) dm_sps_ue(&b);
    int result = 16;
    if (dm_sps_read(&b, 1)) {
        if (dm_sps_read(&b, 1) && dm_sps_read(&b, 8) == 255) { dm_sps_read(&b, 16); dm_sps_read(&b, 16); }
        if (dm_sps_read(&b, 1)) dm_sps_read(&b, 1);
        if (dm_sps_read(&b, 1)) {
            dm_sps_read(&b, 4);
            if (dm_sps_read(&b, 1)) dm_sps_read(&b, 24);
        }
        if (dm_sps_read(&b, 1)) { dm_sps_ue(&b); dm_sps_ue(&b); }
        if (dm_sps_read(&b, 1)) { dm_sps_read(&b, 32); dm_sps_read(&b, 32); dm_sps_read(&b, 1); }
        int nal_hrd = dm_sps_read(&b, 1); if (nal_hrd) dm_sps_hrd(&b);
        int vcl_hrd = dm_sps_read(&b, 1); if (vcl_hrd) dm_sps_hrd(&b);
        if (nal_hrd || vcl_hrd) dm_sps_read(&b, 1);
        dm_sps_read(&b, 1);
        if (dm_sps_read(&b, 1)) {
            dm_sps_read(&b, 1);
            for (unsigned i = 0; i < 4; i++) dm_sps_ue(&b);
            unsigned reorder = dm_sps_ue(&b), buffering = dm_sps_ue(&b);
            if (!b.failed && reorder <= buffering && refs <= buffering && buffering <= 16) result = (int)reorder;
        }
    }
    free(rbsp);
    return result;
}
