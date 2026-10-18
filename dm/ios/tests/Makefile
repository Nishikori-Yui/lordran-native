OUT ?= ../../../game/01004AB00A260000-work/build/ios-diagnostics-tests
.PHONY: run ui-build
run: $(OUT)/diagnostics $(OUT)/camera_swipe $(OUT)/control_profile $(OUT)/pad_axis $(OUT)/app_settings
	$(OUT)/diagnostics
	$(OUT)/camera_swipe
	$(OUT)/control_profile
	$(OUT)/pad_axis
	$(OUT)/app_settings
$(OUT)/diagnostics $(OUT)/app_settings $(OUT)/DmControlsUITest.app/DmControlsUITest: ../../host/dm_log.h
$(OUT)/pad_axis: pad_axis.c ../Sources/dm_pad_axis.h ../../host/dm_padmap.h Makefile
	mkdir -p $(OUT)
	clang -O1 -g -Wall -Wextra -Werror pad_axis.c -o $@
$(OUT)/control_profile: control_profile.m ../Sources/DmControlProfile.m ../Sources/DmControlProfile.h Makefile
	mkdir -p $(OUT)
	clang -O1 -g -Wall -Wextra -Werror -Wno-incompatible-pointer-types -fobjc-arc -framework Foundation -framework CoreGraphics control_profile.m ../Sources/DmControlProfile.m -o $@
$(OUT)/camera_swipe: camera_swipe.c ../Sources/dm_camera_swipe.h Makefile
	mkdir -p $(OUT)
	clang -O1 -g -Wall -Wextra -Werror camera_swipe.c -o $@
$(OUT)/diagnostics: diagnostics.m ../Sources/DmDiagnosticReport.m ../Sources/DmDiagnosticReport.h Makefile
	mkdir -p $(OUT)
	clang -O1 -g -Wall -Wextra -Werror -Wno-incompatible-pointer-types -fobjc-arc -framework Foundation diagnostics.m ../Sources/DmDiagnosticReport.m -o $@
$(OUT)/app_settings: app_settings.m ../Sources/DmAppSettings.m ../Sources/DmAppSettings.h ../Sources/DmDiagnosticReport.m ../Sources/DmDiagnosticReport.h Makefile
	mkdir -p $(OUT)
	clang -O1 -g -Wall -Wextra -Werror -Wno-incompatible-pointer-types -fobjc-arc -framework Foundation app_settings.m ../Sources/DmAppSettings.m ../Sources/DmDiagnosticReport.m -o $@
ui-build: $(OUT)/DmControlsUITest.app/DmControlsUITest
$(OUT)/DmControlsUITest.app/DmControlsUITest: controls_ui.m controls_ui.plist ../Sources/DmGamepad.m ../Sources/DmControlOverlay.m ../Sources/DmControlProfile.m ../Sources/DmAppSettings.m ../Sources/DmDiagnosticReport.m ../Sources/DmGamepad.h ../Sources/DmControlOverlay.h ../Sources/DmControlProfile.h ../Sources/DmAppSettings.h ../Sources/dm_camera_swipe.h ../Sources/dm_pad_axis.h Makefile
	mkdir -p $(OUT)/DmControlsUITest.app
	cp controls_ui.plist $(OUT)/DmControlsUITest.app/Info.plist
	xcrun --sdk iphonesimulator clang -target arm64-apple-ios26.0-simulator -O0 -g -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations -fobjc-arc -I../../host -I../../host/gen/01004AB00A260000 controls_ui.m ../Sources/DmGamepad.m ../Sources/DmControlOverlay.m ../Sources/DmControlProfile.m ../Sources/DmAppSettings.m ../Sources/DmDiagnosticReport.m -framework UIKit -framework Foundation -framework QuartzCore -framework CoreText -framework CoreGraphics -framework GameController -o $@
