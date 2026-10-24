# Unit tests: make compiles and runs them (seconds)
# Source files are included by wildcard, same convention as GFX in the host Makefile (hle_nvn.c is #included directly by t_nvn.c, so it is excluded); adding new source files needs no change here
# Use the same Dark Souls profile as the host.
GAME ?= 01004AB00A260000
ifneq ($(GAME),01004AB00A260000)
$(error Only Dark Souls: Remastered (01004AB00A260000) is supported)
endif
GAME_DIR = ../../games/$(GAME)
GAME_H = ../../host/gen/$(GAME)/game_profile.h
CFLAGS=-O1 -g -Wall -Wno-unused-function -I../nvn/include -I$(dir $(GAME_H)) -I$(GAME_DIR)
GFX=$(filter-out ../nvn/hle_nvn.c,$(sort $(wildcard ../nvn/*.c ../nvn/*.m ../nvn/*.S ../tex/*.c ../tex/*.m)))
GFX_H=$(wildcard ../nvn/*.h ../nvn/*.inc ../nvn/include/*.h ../tex/*.h) $(GAME_H) $(GAME_DIR)/dmsh_chain.h
.DEFAULT_GOAL := t_nvn   # the profile header rule comes first, so keep the default goal as before
$(GAME_H):
	$(MAKE) -C ../../host game_profile GAME=$(GAME)
FW=-framework Metal -framework MetalFX -framework Foundation -framework QuartzCore -framework ImageIO -framework CoreGraphics -framework UniformTypeIdentifiers
# Host crash.c is linked in as well: the write-protect unit tests go through the same page-fault hook as production
t_nvn: t_nvn.c ../nvn/hle_nvn.c ../../host/crash.c ../../host/hle_bigstack.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_nvn.c ../../host/crash.c ../../host/hle_bigstack.c $(GFX) $(FW)
t_dirty_slots: t_dirty_slots.c ../nvn/nvn_dirty.c ../../host/crash.c ../nvn/nvn_dirty.h
	clang $(CFLAGS) -o $@ t_dirty_slots.c ../../host/crash.c ../nvn/nvn_dirty.c
t_dirty_race: t_dirty_race.c ../nvn/nvn_dirty.c ../../host/crash.c ../nvn/nvn_dirty.h
	clang $(CFLAGS) -o $@ t_dirty_race.c ../../host/crash.c
t_builtin: t_builtin.m ../nvn/nvn_builtin.h
	clang -O1 -g -Wall -fobjc-arc -o $@ t_builtin.m -framework Metal -framework Foundation
t_deswz_gpu: t_deswz_gpu.m ../tex/nvn_deswizzle.c ../tex/nvn_deswizzle_gpu.m ../tex/nvn_deswizzle.h ../tex/nvn_deswizzle_gpu.h ../nvn/nvn_tex.c ../nvn/nvn_tex.h
	clang $(CFLAGS) -fobjc-arc -o $@ t_deswz_gpu.m ../tex/nvn_deswizzle.c ../tex/nvn_deswizzle_gpu.m ../nvn/nvn_tex.c -framework Metal -framework Foundation
t_refl: t_refl.m ../nvn/nvn_refl.m ../nvn/nvn_refl.h
	clang -O1 -g -Wall -Wextra -Werror -fobjc-arc -o $@ t_refl.m ../nvn/nvn_refl.m -framework Metal -framework Foundation
t_hmap: t_hmap.c ../nvn/nvn_hmap.h
	clang -O1 -Wall -o $@ t_hmap.c
t_cover: t_cover.c ../nvn/nvn_cover.h
	clang -O1 -Wall -o $@ t_cover.c
t_pace: t_pace.c ../nvn/nvn_pace.h
	clang -O1 -Wall -o $@ t_pace.c
t_perf: t_perf.c ../nvn/nvn_perf.c ../nvn/nvn_perf.h
	clang -O1 -g -Wall -o $@ t_perf.c ../nvn/nvn_perf.c -lpthread
t_scene_meta: t_scene_meta.c ../nvn/nvn_scene_meta.c ../nvn/nvn_scene_meta.h
	clang $(CFLAGS) -O1 -g -Wall -Wextra -Werror -o $@ t_scene_meta.c ../nvn/nvn_scene_meta.c
t_fuse_check: t_fuse_check.m ../../host/crash.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_fuse_check.m ../../host/crash.c $(filter-out ../nvn/nvn_mtl.m ../nvn/nvn_entry.S ../nvn/nvn_thunks.S,$(GFX)) $(FW)
t_present_crop: t_present_crop.m ../nvn/hle_nvn.c ../../host/crash.c ../../host/hle_bigstack.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_present_crop.m ../../host/crash.c ../../host/hle_bigstack.c $(filter-out ../nvn/nvn_mtl.m,$(GFX)) $(FW)
t_present_focus: t_present_focus.m present_focus_stub.c ../nvn/hle_nvn.c ../../host/crash.c ../../host/hle_bigstack.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_present_focus.m present_focus_stub.c ../../host/crash.c ../../host/hle_bigstack.c $(filter-out ../nvn/nvn_mtl.m,$(GFX)) $(FW)
t_reorder_chain: t_reorder_chain.m ../../host/crash.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_reorder_chain.m ../../host/crash.c $(filter-out ../nvn/nvn_mtl.m ../nvn/nvn_entry.S ../nvn/nvn_thunks.S,$(GFX)) $(FW)
t_defer_chain: t_defer_chain.m ../../host/crash.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_defer_chain.m ../../host/crash.c $(filter-out ../nvn/nvn_mtl.m ../nvn/nvn_entry.S ../nvn/nvn_thunks.S,$(GFX)) $(FW)
t_zskip: t_zskip.m ../../host/crash.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_zskip.m ../../host/crash.c $(filter-out ../nvn/nvn_mtl.m ../nvn/nvn_entry.S ../nvn/nvn_thunks.S,$(GFX)) $(FW)
t_xv: t_xv.m ../../host/crash.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_xv.m ../../host/crash.c $(filter-out ../nvn/nvn_mtl.m ../nvn/nvn_entry.S ../nvn/nvn_thunks.S,$(GFX)) $(FW)
t_ub: t_ub.m ../../host/crash.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_ub.m ../../host/crash.c $(filter-out ../nvn/nvn_mtl.m ../nvn/nvn_entry.S ../nvn/nvn_thunks.S,$(GFX)) $(FW)
t_mip_extent: t_mip_extent.m ../nvn/hle_nvn.c ../../host/crash.c ../../host/hle_bigstack.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_mip_extent.m ../../host/crash.c ../../host/hle_bigstack.c $(filter-out ../nvn/nvn_mtl.m,$(GFX)) $(FW)
t_rt_range_shape: t_rt_range_shape.m ../../host/crash.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_rt_range_shape.m ../../host/crash.c $(filter-out ../nvn/nvn_mtl.m ../nvn/nvn_entry.S ../nvn/nvn_thunks.S,$(GFX)) $(FW)
t_rt_range_ro: t_rt_range_ro.m ../../host/crash.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_rt_range_ro.m ../../host/crash.c $(filter-out ../nvn/nvn_mtl.m ../nvn/nvn_entry.S ../nvn/nvn_thunks.S,$(GFX)) $(FW)
t_shader_map: t_shader_map.m ../../host/crash.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_shader_map.m ../../host/crash.c $(filter-out ../nvn/nvn_mtl.m ../nvn/nvn_entry.S ../nvn/nvn_thunks.S,$(GFX)) $(FW)
t_rt_range: t_rt_range.m ../../host/crash.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_rt_range.m ../../host/crash.c $(filter-out ../nvn/nvn_mtl.m ../nvn/nvn_entry.S ../nvn/nvn_thunks.S,$(GFX)) $(FW)
t_rt_depth_ro: t_rt_depth_ro.m ../../host/crash.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_rt_depth_ro.m ../../host/crash.c $(filter-out ../nvn/nvn_mtl.m ../nvn/nvn_entry.S ../nvn/nvn_thunks.S,$(GFX)) $(FW)
t_pso_skey: t_pso_skey.m ../nvn/nvn_pso_skey.h ../nvn/nvn_obj.h
	clang $(CFLAGS) -fobjc-arc -o $@ t_pso_skey.m -framework Foundation
t_sim_packed16: t_sim_packed16.m ../nvn/nvn_sim_packed16.h
	clang $(CFLAGS) -fobjc-arc -o $@ t_sim_packed16.m -framework Foundation -framework Metal
t_pfv: t_pfv.m ../../host/crash.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_pfv.m ../../host/crash.c $(filter-out ../nvn/nvn_mtl.m ../nvn/nvn_entry.S ../nvn/nvn_thunks.S,$(GFX)) $(FW)
t_tex_registry: t_tex_registry.m ../../host/crash.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_tex_registry.m ../../host/crash.c $(filter-out ../nvn/nvn_mtl.m ../nvn/nvn_entry.S ../nvn/nvn_thunks.S,$(GFX)) $(FW)
t_vertex_fetch: t_vertex_fetch.m ../../host/crash.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_vertex_fetch.m ../../host/crash.c $(filter-out ../nvn/nvn_mtl.m ../nvn/nvn_entry.S ../nvn/nvn_thunks.S,$(GFX)) $(FW)
t_alpha: t_alpha.m ../../host/crash.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_alpha.m ../../host/crash.c $(filter-out ../nvn/nvn_mtl.m ../nvn/nvn_entry.S ../nvn/nvn_thunks.S,$(GFX)) $(FW)
t_sampler_reduction: t_sampler_reduction.m ../nvn/hle_nvn.c ../../host/crash.c ../../host/hle_bigstack.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_sampler_reduction.m ../../host/crash.c ../../host/hle_bigstack.c $(filter-out ../nvn/nvn_mtl.m,$(GFX)) $(FW)
t_sampler_pool: t_sampler_pool.m ../nvn/hle_nvn.c ../../host/crash.c ../../host/hle_bigstack.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_sampler_pool.m ../../host/crash.c ../../host/hle_bigstack.c $(filter-out ../nvn/nvn_mtl.m,$(GFX)) $(FW)
t_visibility: t_visibility.m ../nvn/hle_nvn.c ../../host/crash.c ../../host/hle_bigstack.c $(GFX) $(GFX_H)
	clang $(CFLAGS) -fobjc-arc -o $@ t_visibility.m ../../host/crash.c ../../host/hle_bigstack.c $(filter-out ../nvn/nvn_mtl.m,$(GFX)) $(FW)
run: t_nvn t_dirty_slots t_dirty_race t_builtin t_deswz_gpu t_pace t_perf t_scene_meta t_refl t_hmap t_cover t_fuse_check t_present_crop t_present_focus t_reorder_chain t_defer_chain t_zskip t_xv t_ub t_mip_extent t_rt_range_shape t_rt_range_ro t_shader_map t_rt_range t_rt_depth_ro t_pso_skey t_sim_packed16 t_pfv t_tex_registry t_vertex_fetch t_alpha t_sampler_reduction t_sampler_pool t_visibility
	./t_nvn
	./t_dirty_slots
	./t_dirty_race
	./t_builtin
	./t_deswz_gpu
	./t_pace
	./t_perf
	./t_scene_meta
	./t_refl
	./t_hmap
	./t_cover
	./t_fuse_check
	./t_present_crop
	./t_present_focus
	MTL_DEBUG_LAYER=1 ./t_reorder_chain
	MTL_DEBUG_LAYER=1 ./t_defer_chain
	./t_zskip
	./t_xv
	./t_ub
	MTL_DEBUG_LAYER=1 ./t_mip_extent
	MTL_DEBUG_LAYER=1 ./t_mip_extent --stencil-only
	./t_rt_depth_ro
	./t_rt_range_shape
	./t_rt_range_ro
	./t_shader_map
	DM_NVN_UNWRITTEN_DC=0 MTL_DEBUG_LAYER=1 ./t_rt_range
	MTL_DEBUG_LAYER=1 ./t_rt_range   # DontCare on by default: attachment bytes use the closed-form expectation of "one depth-stencil store saved per pass"
	DM_NVN_UNWRITTEN_DC=0 MTL_DEBUG_LAYER=1 ./t_rt_range --disabled
	DM_NVN_UNWRITTEN_DC=0 MTL_DEBUG_LAYER=1 ./t_rt_range --small-depth
	DM_NVN_UNWRITTEN_DC=0 MTL_DEBUG_LAYER=1 ./t_rt_range --sample-attachment --both-flags
	./t_pso_skey
	./t_sim_packed16
	MTL_DEBUG_LAYER=1 ./t_pfv
	MTL_DEBUG_LAYER=1 ./t_tex_registry
	MTL_DEBUG_LAYER=1 python3 test_vertex_fetch.py
	MTL_DEBUG_LAYER=1 python3 test_alpha.py
	MTL_DEBUG_LAYER=1 ./t_sampler_reduction
	MTL_DEBUG_LAYER=1 ./t_sampler_pool
	MTL_DEBUG_LAYER=1 ./t_visibility
	python3 test_tbdr_budget.py
.PHONY: run
