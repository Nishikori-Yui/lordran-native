// Diagnostic-only frame graph used to investigate temporal-upscaling inputs.
#pragma once
#include <stdint.h>

#define NVN_SCENE_META_MAX_PASSES 256
#define NVN_SCENE_META_MAX_READS 8

typedef struct {
    uint64_t pass, color, depth;
    uint32_t color_format, depth_format, width, height, samples, draws;
    uint64_t reads[NVN_SCENE_META_MAX_READS];
    uint32_t read_count;
} nvn_scene_pass;

typedef struct {
    uint64_t frame, present;
    uint32_t present_width, present_height;
    nvn_scene_pass passes[NVN_SCENE_META_MAX_PASSES];
    uint32_t pass_count;
    uint32_t dropped_passes, dropped_reads;
} nvn_scene_frame;

typedef enum {
    NVN_SCENE_CANDIDATE_FOUND,
    NVN_SCENE_NO_PRESENT_PRODUCER,
    NVN_SCENE_NO_DEPTH_IN_READ_CHAIN,
} nvn_scene_candidate_status;

typedef struct {
    nvn_scene_candidate_status status;
    const nvn_scene_pass *present;
    const nvn_scene_pass *scene;
    uint32_t chain_passes;
} nvn_scene_candidate;

void nvn_scene_meta_begin(uint64_t frame);
void nvn_scene_meta_pass(uint64_t frame, uint64_t pass, uint64_t color, uint64_t depth,
                         uint32_t color_format, uint32_t depth_format,
                         uint32_t width, uint32_t height, uint32_t samples);
void nvn_scene_meta_read(uint64_t frame, uint64_t pass, uint64_t serial);
void nvn_scene_meta_draw(uint64_t frame, uint64_t pass);
void nvn_scene_meta_present(uint64_t frame, uint64_t serial, uint32_t width, uint32_t height);
const nvn_scene_frame *nvn_scene_meta_last(void);
void nvn_scene_meta_analyze(const nvn_scene_frame *frame, uint64_t present_serial,
                            nvn_scene_candidate *out);
