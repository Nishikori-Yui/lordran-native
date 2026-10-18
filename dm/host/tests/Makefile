# Dark Souls host tests; build artifacts stay under build/.
GAME ?= 01004AB00A260000
ifneq ($(GAME),01004AB00A260000)
$(error Only Dark Souls: Remastered (01004AB00A260000) is supported)
endif
B = build
GAME_H = ../gen/$(GAME)/game_profile.h
GINC = -I../gen/$(GAME) -I../../games/$(GAME)
TESTS = t_padmap t_touch t_oe t_fs t_thread_leak t_fs_case t_audio t_audio_spsc t_swkbd t_altstack t_condvar t_condvar_old t_time t_log_timestamp t_log t_crash_log
.DEFAULT_GOAL := run
$(addprefix $(B)/,$(TESTS)) $(B)/t_audio_spsc_tsan: Makefile $(GAME_H) ../dm_log.h
$(GAME_H): ../../games/$(GAME)/game.tsv ../../games/game.py
	$(MAKE) -C .. GAME=$(GAME) game_profile
run: $(addprefix $(B)/,$(TESTS))
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
