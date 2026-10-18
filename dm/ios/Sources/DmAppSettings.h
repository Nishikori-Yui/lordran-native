#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSString *const DmAppLanguageKey;
FOUNDATION_EXPORT NSString *const DmAppOperationModeKey;
FOUNDATION_EXPORT NSString *const DmAppFPSKey;

NSString *DmAppLanguage(void);
BOOL DmAppUsesChinese(void);
NSInteger DmAppOperationMode(void);
BOOL DmAppPerformanceVisible(void);
NSString *DmAppText(NSString *english, NSString *simplifiedChinese);
void DmAppApplyStartupSettings(void);
void DmAppExitForSettings(void);
