#include "nvn_scene_meta.h"
#include <string.h>

static nvn_scene_frame g_frame;

void nvn_scene_meta_begin(uint64_t frame) {
    if (g_frame.frame == frame) return;
    memset(&g_frame, 0, sizeof g_frame);
    g_frame.frame = frame;
}

static nvn_scene_pass *find(uint64_t frame, uint64_t pass) {
    if (g_frame.frame != frame) return 0;
    for (uint32_t i = 0; i < g_frame.pass_count; i++)
        if (g_frame.passes[i].pass == pass) return &g_frame.passes[i];
    return 0;
}

void nvn_scene_meta_pass(uint64_t frame, uint64_t pass, uint64_t color, uint64_t depth,
                         uint32_t color_format, uint32_t depth_format,
                         uint32_t width, uint32_t height, uint32_t samples) {
    nvn_scene_meta_begin(frame);
    if (g_frame.pass_count >= NVN_SCENE_META_MAX_PASSES) { g_frame.dropped_passes++; return; }
    nvn_scene_pass *p = &g_frame.passes[g_frame.pass_count++];
    memset(p, 0, sizeof *p);
    p->pass = pass; p->color = color; p->depth = depth;
    p->color_format = color_format; p->depth_format = depth_format;
    p->width = width; p->height = height; p->samples = samples;
}

void nvn_scene_meta_read(uint64_t frame, uint64_t pass, uint64_t serial) {
    nvn_scene_pass *p = find(frame, pass);
    if (!p || !serial) return;
    for (uint32_t i = 0; i < p->read_count; i++) if (p->reads[i] == serial) return;
    if (p->read_count < NVN_SCENE_META_MAX_READS) p->reads[p->read_count++] = serial;
    else g_frame.dropped_reads++;
}

void nvn_scene_meta_draw(uint64_t frame, uint64_t pass) {
    nvn_scene_pass *p = find(frame, pass);
    if (p) p->draws++;
}

void nvn_scene_meta_present(uint64_t frame, uint64_t serial, uint32_t width, uint32_t height) {
    if (g_frame.frame != frame) nvn_scene_meta_begin(frame);
    g_frame.present = serial;
    g_frame.present_width = width;
    g_frame.present_height = height;
}

const nvn_scene_frame *nvn_scene_meta_last(void) { return &g_frame; }

void nvn_scene_meta_analyze(const nvn_scene_frame *f, uint64_t serial, nvn_scene_candidate *out) {
    memset(out, 0, sizeof *out);
    int present_i = -1;
    for (uint32_t i = 0; i < f->pass_count; i++) if (f->passes[i].color == serial) present_i = (int)i;
    if (present_i < 0) { out->status = NVN_SCENE_NO_PRESENT_PRODUCER; return; }
    out->present = &f->passes[present_i];
    int chain[NVN_SCENE_META_MAX_PASSES], cursor = present_i;
    while (cursor >= 0 && out->chain_passes < NVN_SCENE_META_MAX_PASSES) {
        chain[out->chain_passes++] = cursor;
        const nvn_scene_pass *p = &f->passes[cursor];
        int next = -1;
        for (uint32_t r = 0; r < p->read_count; r++) {
            uint64_t source = p->reads[r];
            for (uint32_t j = 0; j < f->pass_count; j++) {
                const nvn_scene_pass *q = &f->passes[j];
                if (q->color == source && q->pass < p->pass &&
                    (next < 0 || q->pass > f->passes[next].pass)) next = (int)j;
            }
        }
        cursor = next;
    }
    for (uint32_t i = 0; i < out->chain_passes; i++) {
        const nvn_scene_pass *p = &f->passes[chain[i]];
        if (p->depth) { out->status = NVN_SCENE_CANDIDATE_FOUND; out->scene = p; return; }
    }
    out->status = NVN_SCENE_NO_DEPTH_IN_READ_CHAIN;
}
