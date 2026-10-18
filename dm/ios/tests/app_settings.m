#import "../Sources/DmAppSettings.h"
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
int main(void) {
    @autoreleasepool {
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        [d removeObjectForKey:DmAppLanguageKey]; [d removeObjectForKey:DmAppOperationModeKey]; [d removeObjectForKey:DmAppFPSKey];
        setenv("DM_LANG", "zh-Hans", 1); setenv("DM_OPMODE", "0", 1); setenv("DM_HUD", "0", 1);
        assert([DmAppLanguage() isEqualToString:@"en-US"] && DmAppOperationMode() == 1 && DmAppPerformanceVisible());
        [d setObject:@"zh-Hans" forKey:DmAppLanguageKey]; [d setObject:@0 forKey:DmAppOperationModeKey]; [d setObject:@NO forKey:DmAppFPSKey];
        assert(DmAppUsesChinese() && DmAppOperationMode() == 0 && !DmAppPerformanceVisible());
        DmAppApplyStartupSettings();
        assert(strcmp(getenv("DM_LANG"), "zh-Hans") == 0 && strcmp(getenv("DM_OPMODE"), "0") == 0);
        puts("app settings: menu-owned language, operation mode and FPS preference passed");
    }
    return 0;
}
