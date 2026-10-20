# This host is dedicated to Dark Souls: Remastered.
GAME ?= 01004AB00A260000
ifneq ($(GAME),01004AB00A260000)
$(error Only Dark Souls: Remastered (01004AB00A260000) is supported)
endif
GAME_DIR = ../games/$(GAME)
GAME_H = gen/$(GAME)/game_profile.h
CFLAGS=-O1 -g -Wall -Wno-unused-function
# Service-layer takeover hle_*.c files are included by wildcard: adding a file does not touch this line (avoids merge conflicts)
SRC=main.c loader.c cheats.c hle.c crash.c probe.c thread.c memstat.m ../ios/Sources/dm_touch_controls.c ../ios/vphone/remap.c $(sort $(wildcard hle_*.c)) front_mac.m perf_hud_mac.m cheats_mac.m entry.S
# NVN null device + nn::vi (dm/gfx/)
# Sources under dm/gfx and dm/gfx/nvn are included by wildcard (tests/ and metal/ do not go into the host): adding a file does not touch this line
GFX=$(sort $(wildcard ../gfx/*.c ../gfx/nvn/*.c ../gfx/nvn/*.m ../gfx/nvn/*.S ../gfx/tex/*.c ../gfx/tex/*.m))
GFX_H=$(sort $(wildcard ../gfx/nvn/*.h ../gfx/nvn/*.inc ../gfx/nvn/include/*.h ../gfx/tex/*.h))
# Third party: libvpx ships only the VP9 decoder's sources (movie decoding), with its configuration headers in config/ (arm64, shared by Mac and iOS). Built separately into a static library, file by file, so host changes do not recompile it
VPX=../third_party/libvpx
VPX_SRC=$(sort $(shell find $(VPX) -name '*.c'))
VPX_OBJ=$(patsubst $(VPX)/%.c,gen/vpx/%.o,$(VPX_SRC))
VPX_LIB=gen/vpx/libvpx.a
gen/vpx/%.o: $(VPX)/%.c $(wildcard $(VPX)/config/*.h)
	@mkdir -p $(dir $@)
	clang -O2 -g -I$(VPX) -I$(VPX)/config -c $< -o $@
$(VPX_LIB): $(VPX_OBJ)
	rm -f $@; ar rcs $@ $^
.DEFAULT_GOAL := dmhost   # The header generation rules are written first below, so the default goal must be stated explicitly (otherwise make only generates the headers and does not build the host)
.PHONY: game_profile
game_profile: $(GAME_H)
$(GAME_H): $(GAME_DIR)/game.tsv ../games/game.py
	python3 ../games/game.py header $(GAME) $@
dmhost: Makefile $(SRC) $(GFX) $(wildcard *.h) ../ios/Sources/dm_touch_controls.[ch] ../ios/vphone/*.h $(GFX_H) $(GAME_H) $(GAME_DIR)/dmsh_chain.h $(VPX_LIB)
	clang $(CFLAGS) -I../gfx/nvn/include -I$(dir $(GAME_H)) -I$(GAME_DIR) -I$(VPX) -I../third_party/stb_vorbis -fobjc-arc -o $@ $(SRC) $(GFX) $(VPX_LIB) -framework Cocoa -framework GameController -framework QuartzCore -framework Metal -framework AudioToolbox -framework ImageIO -framework UniformTypeIdentifiers -framework VideoToolbox -framework CoreMedia
