#include "../nvn/nvn_scene_meta.h"
#include <stdio.h>
#include <string.h>

static int failures;
#define CHECK(name, condition) do { if (!(condition)) { printf("FAIL %s\n", name); failures++; } } while (0)

int main(void) {
    nvn_scene_meta_begin(1);
    nvn_scene_meta_pass(1, 10, 100, 200, 1, 2, 1920, 1080, 1);
    nvn_scene_meta_read(1, 10, 100);
    nvn_scene_meta_read(1, 10, 100);
    nvn_scene_meta_draw(1, 10);
    nvn_scene_meta_pass(1, 11, 101, 0, 3, 0, 1920, 1080, 1);
    nvn_scene_meta_read(1, 11, 100);
    nvn_scene_meta_present(1, 101, 2560, 1440);
    const nvn_scene_frame *f = nvn_scene_meta_last();
    CHECK("frame", f->frame == 1);
    CHECK("pass count", f->pass_count == 2);
    CHECK("color", f->passes[0].color == 100);
    CHECK("depth", f->passes[0].depth == 200);
    CHECK("deduplicated read", f->passes[0].read_count == 1);
    CHECK("draw count", f->passes[0].draws == 1);
    CHECK("present", f->present == 101 && f->present_width == 2560);
    nvn_scene_meta_begin(2);
    CHECK("new frame clears old records", nvn_scene_meta_last()->pass_count == 0);
    nvn_scene_meta_pass(2, 20, 300, 0, 4, 0, 640, 360, 1);
    nvn_scene_meta_read(2, 20, 999);
    nvn_scene_meta_read(2, 21, 888);
    CHECK("read requires matching pass", nvn_scene_meta_last()->passes[0].read_count == 1);
    for (int i = 0; i < NVN_SCENE_META_MAX_READS + 2; i++) nvn_scene_meta_read(2, 20, 1000 + i);
    CHECK("reads bounded", nvn_scene_meta_last()->passes[0].read_count == NVN_SCENE_META_MAX_READS);

    nvn_scene_frame graph = {.frame = 3, .present = 500};
    graph.passes[0] = (nvn_scene_pass){.pass = 10, .color = 100, .depth = 900};
    graph.passes[1] = (nvn_scene_pass){.pass = 11, .color = 200, .depth = 901};
    graph.passes[2] = (nvn_scene_pass){.pass = 12, .color = 300};
    graph.passes[3] = (nvn_scene_pass){.pass = 13, .color = 500};
    graph.passes[4] = (nvn_scene_pass){.pass = 14, .color = 100, .depth = 902};
    graph.pass_count = 5;
    graph.passes[2].reads[0] = 200; graph.passes[2].read_count = 1;
    graph.passes[3].reads[0] = 300; graph.passes[3].read_count = 1;
    nvn_scene_candidate candidate;
    nvn_scene_meta_analyze(&graph, 500, &candidate);
    CHECK("nearest depth in read chain", candidate.status == NVN_SCENE_CANDIDATE_FOUND && candidate.scene->pass == 11);
    CHECK("composite chain length", candidate.chain_passes == 3);
    CHECK("present producer", candidate.present->pass == 13);
    graph.passes[3].reads[0] = 100;
    nvn_scene_meta_analyze(&graph, 500, &candidate);
    CHECK("future write is not a producer", candidate.status == NVN_SCENE_CANDIDATE_FOUND && candidate.scene->pass == 10);
    nvn_scene_meta_analyze(&graph, 999, &candidate);
    CHECK("missing present producer", candidate.status == NVN_SCENE_NO_PRESENT_PRODUCER);
    graph.passes[0].depth = graph.passes[1].depth = 0;
    graph.passes[3].reads[0] = 300;
    nvn_scene_meta_analyze(&graph, 500, &candidate);
    CHECK("depth-free chain", candidate.status == NVN_SCENE_NO_DEPTH_IN_READ_CHAIN);
    printf("scene metadata: %d failures\n", failures);
    return failures != 0;
}
