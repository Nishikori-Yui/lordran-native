#import "DmAppSettings.h"
#import "DmDiagnosticReport.h"
#include <stdlib.h>

NSString *const DmAppLanguageKey = @"DmLanguage";
NSString *const DmAppOperationModeKey = @"DmOperationMode";
NSString *const DmAppFPSKey = @"DmShowFPS";

NSString *DmAppLanguage(void) {
    NSString *language = [NSUserDefaults.standardUserDefaults stringForKey:DmAppLanguageKey];
    return [language.lowercaseString hasPrefix:@"zh"] ? @"zh-Hans" : @"en-US";
}
BOOL DmAppUsesChinese(void) { return [DmAppLanguage() isEqualToString:@"zh-Hans"]; }
NSInteger DmAppOperationMode(void) {
    NSNumber *saved = [NSUserDefaults.standardUserDefaults objectForKey:DmAppOperationModeKey];
    if (saved) return saved.integerValue == 0 ? 0 : 1;
    return 1;
}
BOOL DmAppPerformanceVisible(void) {
    NSNumber *saved = [NSUserDefaults.standardUserDefaults objectForKey:DmAppFPSKey];
    if (saved) return saved.boolValue;
    return YES;
}
NSString *DmAppText(NSString *english, NSString *simplifiedChinese) {
    return DmAppUsesChinese() ? simplifiedChinese : english;
}
void DmAppApplyStartupSettings(void) {
    // These values are menu-owned and are never read from Documents/env.txt.
    setenv("DM_LANG", DmAppLanguage().UTF8String, 1);
    setenv("DM_OPMODE", DmAppOperationMode() == 0 ? "0" : "1", 1);
}
void DmAppExitForSettings(void) {
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    // The setting change is an intentional restart, not an interrupted game run.
    DmDiagnosticsSetActive(documents, NO);
    fflush(stderr);
    exit(0);
}
