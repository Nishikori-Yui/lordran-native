// Self-contained reflection parser tests. Fixtures describe the runtime ABI and
// require neither a game dump nor a shader cache from another workspace.
#import "../nvn/nvn_refl.h"
#import <Metal/Metal.h>
#include <stdio.h>
#include <string.h>

static int failures, checks;
static void check(const char *label, long expected, long actual) {
    checks++;
    if (expected != actual) {
        failures++;
        fprintf(stderr, "FAIL %s: expected=%ld actual=%ld\n", label, expected, actual);
    }
}
static NSDictionary *binding(NSString *kind, int reg, int aid, NSString *type) {
    return @{@"kind": kind, @"reg": @(reg), @"arg_id": @(aid),
        @"msl_name": @"test_binding", @"msl_type": type};
}
static void reject(const char *label, NSDictionary *fixture, const char *reason) {
    nvn_refl result; char error[256] = "";
    check(label, 1, nvn_refl_from_json(fixture, &result, error, sizeof error) != 0);
    check("error identifies the rejected input", 1, strstr(error, reason) != NULL);
    for (const unsigned char *p = (const unsigned char *)error; *p; p++)
        if (*p >= 128) { check("authored parser errors use English ASCII", 0, 1); break; }
}
static void route_b(void) {
    NSArray *bindings = @[
        @{@"kind": @"support", @"arg_id": @0},
        binding(@"cbuf", 10, 1, @"constant float4*"),
        @{@"kind": @"c1", @"arg_id": @2},
        @{@"kind": @"drvcb", @"bank": @0, @"arg_id": @3},
        @{@"kind": @"drvcb", @"bank": @2, @"arg_id": @4},
        @{@"kind": @"sbuf", @"reg": @4, @"arg_id": @5, @"rw": @YES},
        binding(@"tbuf", 8, 6, @"texture_buffer<uint>"),
        binding(@"tex", 41, 7, @"texture2d<float>"),
        binding(@"samp", 3, 8, @"sampler"),
        binding(@"tex", 39, 9, @"depthcube_array<float>"),
        binding(@"samp_tex", 5, 10, @"sampler"),
        binding(@"img", 6, 11, @"texture3d<int, access::write>"),
        binding(@"ubo_ptr", 2, 12, @"device float*"),
        @{@"kind": @"tex_ubo", @"reg": @7, @"arg_id": @13, @"off": @24, @"msl_type": @"texture2d<uint>"},
        @{@"kind": @"samp_ubo", @"reg": @8, @"arg_id": @14, @"off": @32}
    ];
    NSDictionary *fixture = @{@"route": @"B", @"bindings": bindings, @"c1": @"71c49cbf01020304",
        @"vertex_inputs": @[
            @{@"location": @0, @"msl_type": @"float4"}, @{@"location": @3, @"msl_type": @"uint2"},
            @{@"location": @7, @"msl_type": @"int4"}, @{@"location": @15, @"msl_type": @"float4"}],
        @"threadgroup_size": @[@8, @4, @1],
        @"raster": @{@"pos_attr": @2, @"pos_w": @"one", @"discard": @0, @"sample_mask": @0,
            @"colors": @[@0, @2], @"uv_from_attr": @{@"1": @3},
            @"uv_affine": @{@"2": @{@"attr": @5, @"sx": @[@1, @2, @3], @"ox": @[@2, @3, @0],
                @"sy": @[@3, @4, @1], @"oy": @[@4, @5, @2]}}},
        @"fetch": @{@"calls": @[@{@"fc": @0, @"tex_reg": @41, @"varying_locn": @1},
            @{@"fc": @1, @"tex_reg": @70, @"varying_locn": @3}], @"mixed_regs": @[@3, @70],
            @"outputs": @[@{@"color": @0}, @{@"color": @2}]}};
    nvn_refl result; char error[256] = "";
    check("route B parses", 0, nvn_refl_from_json(fixture, &result, error, sizeof error));
    check("route B flag", 1, result.route_b); check("argument buffer index", 0, result.abi);
    check("binding count", 15, result.nb);
    const int kinds[] = {NVN_RB_SUPPORT, NVN_RB_CBUF, NVN_RB_C1, NVN_RB_DRV0, NVN_RB_DRV2,
        NVN_RB_SBUFP, NVN_RB_TBUF, NVN_RB_TEX, NVN_RB_SAMP, NVN_RB_TEX, NVN_RB_SAMPT,
        NVN_RB_IMG, NVN_RB_UBOP, NVN_RB_TEXU, NVN_RB_SAMPU};
    for (int i = 0; i < 15; i++) {
        check("binding kind", kinds[i], result.b[i].kind);
        check("binding argument index", i, result.b[i].aid);
        check("binding register", [bindings[i][@"reg"] intValue], result.b[i].reg);
    }
    check("storage buffer writable", 1, result.b[5].rw);
    check("typed buffer pixel class", NVN_DPF_UINT, result.b[6].dpf);
    check("depth cube array type", MTLTextureTypeCubeArray, result.b[9].dtt);
    check("depth cube pixel class", NVN_DPF_DEPTH, result.b[9].dpf);
    check("storage image pixel class", NVN_DPF_SINT, result.b[11].dpf);
    check("runtime texture handle offset", 24, result.b[13].off);
    check("runtime sampler handle offset", 32, result.b[14].off);
    check("runtime handle bindings", 1, result.bindless);
    check("driver c0 inferred from binding", 1, result.drv_read[0]);
    check("driver c2 inferred from binding", 1, result.drv_read[2]);
    const uint8_t c1[] = {0x71, 0xc4, 0x9c, 0xbf, 1, 2, 3, 4};
    check("constant segment present", 1, result.has_c1);
    check("constant segment length", sizeof c1, result.c1_len);
    check("constant segment bytes", 0, memcmp(c1, result.c1, sizeof c1));
    check("vertex inputs", 4, result.nv);
    const int locations[] = {0, 3, 7, 15};
    const int types[] = {NVN_CT_FLOAT, NVN_CT_UINT, NVN_CT_INT, NVN_CT_FLOAT};
    for (int i = 0; i < 4; i++) {
        check("vertex location", locations[i], result.v[i].loc);
        check("NVN vertex attribute", locations[i], result.v[i].nvn);
        check("vertex component type", types[i], result.v[i].ct);
    }
    check("threadgroup x", 8, result.tg[0]); check("threadgroup y", 4, result.tg[1]); check("threadgroup z", 1, result.tg[2]);
    check("position attribute", 2, result.pos_attr); check("position w=1", 1, result.pos_w1);
    check("fragment discard", 0, result.may_discard); check("sample mask writes", 0, result.writes_smask);
    check("color mask known", 1, result.color_known); check("color mask", 5, result.color_mask);
    check("UV attribute mapping", 3, result.uv_attr[1]); check("UV affine attribute", 5, result.uv_aff_attr[2]);
    check("UV affine scale reference", (1 << 8) | (2 << 2) | 3, result.uv_aff[2][0]);
    check("UV affine offset reference", (4 << 8) | (5 << 2) | 2, result.uv_aff[2][3]);
    check("fetch calls", 2, result.nfc); check("fetch texture register", 70, result.fc_reg[1]);
    check("fetch varying location", 3, result.fc_locn[1]);
    check("mixed texture register 3", 1, (result.fc_mixed[0] >> 3) & 1);
    check("mixed texture register 70", 1, (result.fc_mixed[1] >> 6) & 1);
    check("fetch outputs", 2, result.nfo); check("fetch color", 2, result.fo_color[1]);
}
static void texture_types(void) {
    NSArray *names = @[@"texture1d<float>", @"texture1d_array<float>", @"texture2d<float>",
        @"texture2d_array<uint>", @"texture3d<int>", @"texturecube<float>", @"depthcube_array<float>"];
    const int types[] = {MTLTextureType1D, MTLTextureType1DArray, MTLTextureType2D, MTLTextureType2DArray,
        MTLTextureType3D, MTLTextureTypeCube, MTLTextureTypeCubeArray};
    const int pixels[] = {NVN_DPF_FLOAT, NVN_DPF_FLOAT, NVN_DPF_FLOAT, NVN_DPF_UINT, NVN_DPF_SINT, NVN_DPF_FLOAT, NVN_DPF_DEPTH};
    for (NSUInteger i = 0; i < names.count; i++) {
        nvn_refl result; char error[256] = "";
        check("texture fixture parses", 0, nvn_refl_from_json(@{@"route": @"B",
            @"bindings": @[binding(@"tex", 1, 0, names[i])]}, &result, error, sizeof error));
        check("dummy texture type", types[i], result.b[0].dtt);
        check("dummy texture pixel class", pixels[i], result.b[0].dpf);
    }
}
static void invalid_inputs(void) {
    reject("retired route rejected", @{@"bindings": @[]}, "Not route-B");
    reject("missing bindings rejected", @{@"route": @"B"}, "Missing bindings");
    NSMutableArray *oversized = [NSMutableArray array];
    for (int i = 0; i <= NVN_REFL_MAXB; i++) [oversized addObject:binding(@"cbuf", 0, i, @"constant float*")];
    reject("binding limit enforced", @{@"route": @"B", @"bindings": oversized}, "exceeds limit");
    reject("unknown binding rejected", @{@"route": @"B", @"bindings": @[binding(@"unknown", 0, 0, @"float")]}, "unsupported");
    reject("unresolved slot rejected", @{@"route": @"B", @"bindings": @[@{@"kind": @"tex", @"msl_name": @"test_texture", @"reg": NSNull.null, @"arg_id": @0, @"msl_type": @"texture2d<float>"}]}, "no resolved slot");
    reject("unfillable driver input rejected", @{@"route": @"B", @"bindings": @[], @"drv_unfillable": @[@"c0[99]"]}, "cannot supply");
    reject("odd constant hex rejected", @{@"route": @"B", @"bindings": @[], @"c1": @"abc"}, "not paired");
    reject("oversized constants rejected", @{@"route": @"B", @"bindings": @[], @"c1": [@"" stringByPaddingToLength:8194 withString:@"0" startingAtIndex:0]}, "exceeds the limit");
    reject("vertex location limit enforced", @{@"route": @"B", @"bindings": @[], @"vertex_inputs": @[@{@"location": @(NVN_REFL_MAXV), @"msl_type": @"float4"}]}, "out of range");
    reject("discontinuous fetch rejected", @{@"route": @"B", @"bindings": @[], @"fetch": @{@"calls": @[@{@"fc": @2, @"tex_reg": @1, @"varying_locn": @0}]}}, "discontinuous");
    reject("fetch register limit enforced", @{@"route": @"B", @"bindings": @[], @"fetch": @{@"calls": @[@{@"fc": @0, @"tex_reg": @128, @"varying_locn": @0}]}}, "out of range");
    reject("fetch output limit enforced", @{@"route": @"B", @"bindings": @[], @"fetch": @{@"outputs": @[@{@"color": @0}, @{@"color": @1}, @{@"color": @2}, @{@"color": @3}, @{@"color": @4}]}}, "exceeds 4");
}
int main(void) { @autoreleasepool {
    route_b(); texture_types(); invalid_inputs();
    printf("Reflection parser: checks=%d failures=%d (self-contained fixtures; no external cache required)\n", checks, failures);
    return failures != 0;
} }
