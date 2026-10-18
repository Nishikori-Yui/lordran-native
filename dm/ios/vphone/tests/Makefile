# Native Mach VM tests; the production implementation is enabled explicitly.
OUT = ../../../host/tests/build/t_vphone_remap
.PHONY: run
run: $(OUT)
	$(OUT)
$(OUT): remap.c ../remap.c ../remap.h Makefile
	mkdir -p $(dir $@)
	clang -O1 -g -Wall -Werror -DDM_VPHONE_REMAP_TEST remap.c ../remap.c -o $@
