#import <Foundation/Foundation.h>

// Session files and reports are independent of UIKit and the game runtime.
BOOL DmDiagnosticsPrepare(NSURL *documents, NSError **error);
BOOL DmDiagnosticsBeginRun(NSURL *documents, NSError **error);
void DmDiagnosticsSetActive(NSURL *documents, BOOL active);
NSURL *DmDiagnosticReportCreate(NSURL *documents, NSDictionary *metadata, NSError **error);
