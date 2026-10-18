OUT ?= ../../../game/01004AB00A260000-work/build/ios-diagnostics-tests
.PHONY: run
run: $(OUT)/diagnostics
	$(OUT)/diagnostics
$(OUT)/diagnostics: diagnostics.m ../Sources/DmDiagnosticReport.m ../Sources/DmDiagnosticReport.h Makefile
	mkdir -p $(OUT)
	clang -O1 -g -Wall -Wextra -Werror -Wno-incompatible-pointer-types -fobjc-arc -framework Foundation diagnostics.m ../Sources/DmDiagnosticReport.m -o $@
