# Dark Souls host tests; build artifacts stay under build/.
GAME ?= 01004AB00A260000
ifneq ($(GAME),01004AB00A260000)
$(error Only Dark Souls: Remastered (01004AB00A260000) is supported)
endif
B = build
GAME_H = ../gen/$(GAME)/game_profile.h
GINC = -I../gen/$(GAME) -I../../games/$(GAME)
TESTS = t_padmap t_touch t_oe t_fs t_thread_leak t_fs_case t_audio t_audio_spsc t_swkbd t_altstack t_condvar t_condvar_old t_time t_log_timestamp t_log t_crash_log t_cheats t_hid_motion t_net_wait
.DEFAULT_GOAL := run
.PHONY: mac-cheats-test
mac-cheats-test: $(B)/t_cheats_mac
	$(B)/t_cheats_mac
$(B)/t_cheats_mac: t_cheats_mac.m ../cheats_mac.m ../cheats_mac.h ../cheats.c ../cheats.h $(GAME_H) | $(B)
	clang -O1 -g -Wall -Wextra -Werror -fobjc-arc $(GINC) -o $@ t_cheats_mac.m ../cheats_mac.m ../cheats.c -framework Cocoa -framework QuartzCore
MOVIE_B = ../../../game/$(GAME)-work/build/movie-tests
movie-avc-build: $(MOVIE_B)/t_movie_avc $(MOVIE_B)/t_movie_sps
$(MOVIE_B):
	mkdir -p $@
$(MOVIE_B)/t_movie_sps: t_movie_sps.c ../dm_movie_sps.h | $(MOVIE_B)
	clang -O1 -g -Wall -Wextra -Werror -o $@ $<
$(MOVIE_B)/t_movie_avc: t_movie_avc.m ../hle_movie_avc.c ../dm_movie_avc.h ../dm_movie_sps.h ../dm_log.h | $(MOVIE_B)
	clang -O1 -g -Wall -Wextra -Werror -Wno-deprecated-declarations -fobjc-arc -o $@ t_movie_avc.m ../hle_movie_avc.c -framework AVFoundation -framework VideoToolbox -framework CoreMedia -framework CoreVideo
movie-avc-simulator-build: $(MOVIE_B)/t_movie_avc_sim
$(MOVIE_B)/t_movie_avc_sim: t_movie_avc.m ../hle_movie_avc.c ../dm_movie_avc.h ../dm_movie_sps.h ../dm_log.h | $(MOVIE_B)
	xcrun --sdk iphonesimulator clang -target arm64-apple-ios26.0-simulator -O1 -g -Wall -Wextra -Werror -Wno-deprecated-declarations -fobjc-arc -o $@ t_movie_avc.m ../hle_movie_avc.c -framework AVFoundation -framework VideoToolbox -framework CoreMedia -framework CoreVideo
movie-hle-build: $(MOVIE_B)/t_movie_hle
$(MOVIE_B)/t_movie_hle: t_movie_hle.m ../hle_movie.c ../hle_movie_avc.c ../dm_movie_avc.h ../dm_movie_sps.h ../dm_log.h ../gen/vpx/libvpx.a $(GAME_H) | $(MOVIE_B)
	clang -O1 -g -Wall -Wextra -Wno-unused-function -Wno-deprecated-declarations -Wno-incompatible-pointer-types -fobjc-arc $(GINC) -I../../third_party/libvpx -I../../third_party/stb_vorbis -o $@ t_movie_hle.m ../hle_movie_avc.c ../gen/vpx/libvpx.a -framework AVFoundation -framework AudioToolbox -framework VideoToolbox -framework CoreMedia -framework CoreVideo
$(addprefix $(B)/,$(TESTS)) $(B)/t_audio_spsc_tsan: Makefile $(GAME_H) ../dm_log.h
$(GAME_H): ../../games/$(GAME)/game.tsv ../../games/game.py
	$(MAKE) -C .. GAME=$(GAME) game_profile
run: $(addprefix $(B)/,$(TESTS))
	$(B)/t_cheats
	$(B)/t_hid_motion
	$(B)/t_net_wait
	$(B)/t_touch
	$(B)/t_oe 2>/dev/null
	$(B)/t_fs 2>/dev/null
	$(B)/t_thread_leak
	TMPDIR="$(abspath $(B))" $(B)/t_fs_case 2>/dev/null
	$(B)/t_audio
	$(B)/t_audio_spsc
	$(B)/t_swkbd
	$(B)/t_altstack
	$(B)/t_condvar
	$(B)/t_condvar_old
	$(B)/t_padmap
	$(B)/t_time
	$(B)/t_time fixed
	$(B)/t_log_timestamp
	$(B)/t_log
	$(B)/t_crash_log
	python3 check_log_language.py
	PYTHONPYCACHEPREFIX="$(abspath ../../../game/$(GAME)-work/build/pycache)" python3 -m unittest test_log_language.py
$(B)/t_crash_log: t_crash_log.c t_altstack_stub.c ../crash.c ../dm.h ../dm_log_timestamp.h | $(B)
	clang -O1 -g -Wall -Wextra -Wno-unused-function -I.. $(GINC) -o $@ t_crash_log.c t_altstack_stub.c ../crash.c
$(B)/t_log: t_log.c ../dm_log.h ../dm_log_timestamp.h | $(B)
	clang -O1 -g -Wall -Wextra -Werror -o $@ t_log.c
$(B)/t_log_timestamp: t_log_timestamp.c ../dm_log_timestamp.h | $(B)
	clang -O1 -g -Wall -Wextra -Werror -o $@ t_log_timestamp.c
$(B)/t_cheats: t_cheats.c ../cheats.c ../cheats.h $(GAME_H) | $(B)
	clang -O1 -g -Wall -Wextra -Werror $(GINC) -o $@ t_cheats.c ../cheats.c
$(B)/t_hid_motion: t_hid_motion.c ../hle_hid.c ../dm_input.h ../dm_input_motion.h ../hle.h | $(B)
	clang -O1 -g -Wall -Wno-unused-function $(GINC) -I.. -o $@ t_hid_motion.c
$(B)/t_net_wait: t_net_wait.c ../hle_net.c ../hle_net_wait.h ../hle.h ../dm.h $(GAME_H) | $(B)
	clang -O1 -g -Wall -Wextra -Werror -I.. $(GINC) -o $@ t_net_wait.c
$(B)/t_padmap: t_padmap.c ../dm_padmap.h ../dm_input.h | $(B)
	clang -O1 -Wall -Werror -o $@ t_padmap.c
$(B)/t_touch: t_touch.c ../hle_touch.c ../front.h ../dm.h | $(B)
	clang -O1 -Wno-unused-function -I.. $(GINC) -o $@ t_touch.c ../hle_touch.c
$(B)/t_thread_leak: t_thread_leak.c ../thread.c ../dm.h | $(B)
	clang -O1 -Wno-unused-function -I.. $(GINC) -o $@ t_thread_leak.c
$(B)/t_fs: t_fs.c t_fs_stub.c t_bigstack_stub.c ../hle_fs.c ../hle.h ../dm.h | $(B)
	clang -O1 -Wno-unused-function -I.. $(GINC) -o $@ t_fs.c t_fs_stub.c t_bigstack_stub.c
$(B)/t_audio: t_audio.c ../hle_audio.c ../hle.h ../dm.h | $(B)
	clang -O1 -Wno-unused-function -I.. $(GINC) -o $@ t_audio.c -framework AudioToolbox
$(B)/t_audio_spsc: t_audio_spsc.c ../hle_audio.c ../hle.h ../dm.h | $(B)
	clang -O1 -Wno-unused-function -I.. $(GINC) -o $@ t_audio_spsc.c -framework AudioToolbox
$(B)/t_audio_spsc_tsan: t_audio_spsc.c ../hle_audio.c ../hle.h ../dm.h | $(B)
	clang -O1 -g -O1 -fsanitize=thread -Wno-unused-function -I.. $(GINC) -o $@ t_audio_spsc.c -framework AudioToolbox
$(B)/t_swkbd: t_swkbd.c ../hle_swkbd.c ../hle.h ../dm.h | $(B)
	clang -O1 -Wno-unused-function -I.. $(GINC) -o $@ t_swkbd.c
$(B)/t_altstack: t_altstack.c t_altstack_stub.c ../crash.c ../dm.h | $(B)
	clang -O1 -Wno-unused-function -I.. $(GINC) -o $@ t_altstack.c t_altstack_stub.c ../crash.c
$(B):
	mkdir -p $@
.PHONY: run tsan
tsan: $(B)/t_audio_spsc_tsan
	$(B)/t_audio_spsc_tsan
$(B)/t_condvar: t_condvar.c t_condvar_stub.c ../hle_thread.c ../dm.h | $(B)
	clang -O1 -Wno-unused-function -DDM_TEST_HOOKS -I.. $(GINC) -o $@ t_condvar.c t_condvar_stub.c ../hle_thread.c
$(B)/t_condvar_old: t_condvar.c t_condvar_stub.c ../hle_thread.c ../dm.h | $(B)
	clang -O1 -Wno-unused-function -DDM_TEST_HOOKS -DDM_TEST_CV_OLD_ORDER -I.. $(GINC) -o $@ t_condvar.c t_condvar_stub.c ../hle_thread.c

$(B)/t_fs_case: t_fs_case.c t_bigstack_stub.c ../hle_fs.c ../hle.h ../dm.h | $(B)
	clang -O1 -Wno-unused-function -I.. $(GINC) -o $@ t_fs_case.c t_bigstack_stub.c

$(B)/t_oe: t_oe.c ../hle_oe.c ../hle.h ../dm.h | $(B)
	clang -O1 -Wno-unused-function -I.. $(GINC) -o $@ t_oe.c
$(B)/t_time: t_time.c ../hle_time.c ../hle.h ../dm.h | $(B)
	clang -O1 -Wall -Wno-unused-function -I.. $(GINC) -o $@ t_time.c
