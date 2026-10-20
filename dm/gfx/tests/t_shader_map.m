#include "../nvn/nvn_mtl.m"

int prog_key(const prog_t *p, unsigned stage, uint8_t key[8]) {
    memcpy(key, p->sd[stage].control, 8);
    return 0;
}
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
uint64_t nvn_new_serial(void) { static uint64_t serial; return ++serial; }

static int failures, rows, rejected, misbound;

static void check(int ok, const char *name) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", name); failures++; }
}

int main(int argc, char **argv) { @autoreleasepool {
    NSString *path = argc > 1 ? @(argv[1]) : @"../../games/" DM_GAME_ID "/shader_map.tsv";
    NSError *error = nil;
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
    if (!text) { fprintf(stderr, "Cannot read shader map: %s\n", error.localizedDescription.UTF8String); return 1; }
    g_shmap = [NSMutableDictionary dictionary];
    g_shcache = [NSMutableDictionary dictionary];
    uint8_t samples[2][8] = {{0}};
    int have_sample[2] = {0};
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (!line.length || [line hasPrefix:@"#"] || [line hasPrefix:@"package\t"]) continue;
        NSArray<NSString *> *columns = [line componentsSeparatedByString:@"\t"];
        check(columns.count >= 4, "shader map row has required columns");
        if (columns.count < 4) continue;
        int expected = [columns[0] hasPrefix:@"vs_"] ? 0 : [columns[0] hasPrefix:@"ps_"] ? 1 : -1;
        check(expected >= 0, "Dark Souls shader package has a known stage");
        if (expected < 0) continue;
        rows++;
        if (stage_of(columns[2]) != expected) rejected++;
        g_shmap[columns[3]] = columns[2];
        // Use cached shader objects to exercise production program binding without a GPU.
        NvShader *shader = [NvShader new];
        shader->stage = expected;
        g_shcache[[columns[3] stringByAppendingString:@"_b"]] = shader;
        uint8_t key[8] = {0};
        unsigned long long value = strtoull(columns[3].UTF8String, NULL, 16);
        for (int i = 0; i < 8; i++) key[i] = (uint8_t)(value >> (56 - 8 * i));
        if (!have_sample[expected]) { memcpy(samples[expected], key, 8); have_sample[expected] = 1; }
        prog_t program = {.nstage = 1, .serial = nvn_new_serial()};
        program.sd[0].control = key;
        NvProg *bound = prog_get(&program);
        if (!bound || bound->sh[expected] != shader) misbound++;
        mtl_prog_release(&program);
    }
    check(rows > 0, "actual profile shader map was exercised");
    check(rejected == 0, "every profile stage is recognized");
    check(misbound == 0, "every profile shader binds to its expected program stage");
    NSArray<NSString *> *names = @[@"vertex", @"fragment", @"compute", @"tessellation-control", @"tessellation-evaluation",
        @"\u9876\u70b9", @"\u50cf\u7d20", @"\u8ba1\u7b97", @"\u5916\u58f3", @"\u57df"];
    int stages[] = {0, 1, 5, 3, 4, 0, 1, 5, 3, 4};
    for (NSUInteger i = 0; i < names.count; i++) check(stage_of(names[i]) == stages[i], "serialized stage token or English alias");
    check(stage_of(nil) == -1 && stage_of(@"") == -1 && stage_of(@"unknown") == -1, "unknown stages are rejected");
    check(have_sample[0] && have_sample[1], "profile contains vertex and fragment shaders");
    pso_key no_attachments = {0};
    check(!pso_key_has_attachments(&no_attachments), "pipeline key without attachments is rejected");
    pso_pend_kick(&no_attachments, NULL, NULL);
    int invalid_pipeline_queued = 0;
    for (int i = 0; i < PSO_PEND_MAX; i++) invalid_pipeline_queued |= g_pp[i].used;
    check(!invalid_pipeline_queued, "attachment-free pipeline is not compiled in background");
    no_attachments.cfmt[0] = MTLPixelFormatBGRA8Unorm;
    check(pso_key_has_attachments(&no_attachments), "color-only pipeline is allowed");
    no_attachments.cfmt[0] = 0; no_attachments.dfmt = MTLPixelFormatDepth32Float;
    check(pso_key_has_attachments(&no_attachments), "depth-only pipeline is allowed");
    if (argc > 2 && have_sample[0] && have_sample[1]) {
        g_dev = MTLCreateSystemDefaultDevice();
        check(g_dev != nil, "Metal device is available for shader loading");
        if (g_dev) {
            g_msl_dir = @(argv[2]);
            g_shcache = [NSMutableDictionary dictionary];
            prog_t program = {.nstage = 2, .serial = nvn_new_serial()};
            program.sd[0].control = samples[0]; program.sd[1].control = samples[1];
            NvProg *bound = prog_get(&program);
            check(bound && bound->sh[0] && bound->sh[0]->fn.functionType == MTLFunctionTypeVertex,
                "profile vertex shader loads from the compiled library");
            check(bound && bound->sh[1] && bound->sh[1]->fn.functionType == MTLFunctionTypeFragment,
                "profile fragment shader loads from the compiled library");
            mtl_prog_release(&program);
        }
    }
    printf("Shader map: rows=%d rejected=%d misbound=%d failures=%d\n", rows, rejected, misbound, failures);
    return failures != 0;
} }
