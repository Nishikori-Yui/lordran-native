#import "../Sources/DmDiagnosticReport.h"
#include <assert.h>
#include <unistd.h>

static void writeText(NSURL *directory, NSString *name, NSString *text) {
    assert([text writeToURL:[directory URLByAppendingPathComponent:name]
        atomically:YES encoding:NSUTF8StringEncoding error:nil]);
}
static NSString *readText(NSURL *url) {
    NSString *text = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
    assert(text); return text;
}

int main(void) {
    @autoreleasepool {
        char path[] = "/private/tmp/nxnative-diagnostics-XXXXXX";
        assert(mkdtemp(path));
        NSURL *documents = [NSURL fileURLWithPath:@(path) isDirectory:YES];
        NSError *error = nil;
        assert(!DmDiagnosticsPrepare(documents, &error) && !error);
        writeText(documents, @"log.txt", @"first failure\n");
        assert(DmDiagnosticsBeginRun(documents, &error) && !error);
        assert(DmDiagnosticsPrepare(documents, &error) && !error);
        NSURL *recovery = [documents URLByAppendingPathComponent:@"diagnostics/recovery.log"];
        assert([readText(recovery) isEqualToString:@"first failure\n"]);
        writeText(documents, @"log.txt", @"recovery UI\n");
        assert(DmDiagnosticsPrepare(documents, &error));
        assert([readText(recovery) isEqualToString:@"first failure\n"]);

        writeText(documents, @"log.prev.txt", @"previous session\n");
        writeText(documents, @"env.txt", @"DO_NOT_EXPORT=private\n");
        writeText(documents, @"save.dat", @"DO_NOT_EXPORT_SAVE\n");
        NSURL *report = DmDiagnosticReportCreate(documents, @{@"model": @"test-device"}, &error);
        assert(report && !error);
        NSString *text = readText(report);
        assert([text containsString:@"test-device"] && [text containsString:@"first failure"]);
        assert([text containsString:@"recovery UI"] && [text containsString:@"previous session"]);
        assert(![text containsString:@"DO_NOT_EXPORT"]);
        assert([readText([documents URLByAppendingPathComponent:@"log.txt"]) isEqualToString:@"recovery UI\n"]);

        NSMutableData *large = [NSMutableData dataWithLength:9 * 1024 * 1024];
        memset(large.mutableBytes, 'a', large.length);
        memcpy(large.mutableBytes, "OLD_HEAD", 8);
        memcpy((char *)large.mutableBytes + large.length - 8, "NEW_TAIL", 8);
        assert([large writeToURL:[documents URLByAppendingPathComponent:@"log.txt"] atomically:YES]);
        report = DmDiagnosticReportCreate(documents, @{}, &error);
        text = readText(report);
        assert([text containsString:@"Showing the last"] && [text containsString:@"NEW_TAIL"]);
        assert(![text containsString:@"OLD_HEAD"] && text.length < 9 * 1024 * 1024);

        assert(DmDiagnosticsBeginRun(documents, &error));
        assert(![NSFileManager.defaultManager fileExistsAtPath:recovery.path]);
        DmDiagnosticsSetActive(documents, NO);
        assert(!DmDiagnosticsPrepare(documents, &error));
        DmDiagnosticsSetActive(documents, YES);
        assert(DmDiagnosticsPrepare(documents, &error));
        assert(DmDiagnosticsBeginRun(documents, &error));
        DmDiagnosticsSetActive(documents, NO);

        NSURL *current = [documents URLByAppendingPathComponent:@"log.txt"];
        assert([NSFileManager.defaultManager removeItemAtURL:current error:nil]);
        assert(!symlink([documents URLByAppendingPathComponent:@"env.txt"].fileSystemRepresentation, current.fileSystemRepresentation));
        report = DmDiagnosticReportCreate(documents, @{}, &error);
        assert(report && ![readText(report) containsString:@"DO_NOT_EXPORT"]);
        assert([NSFileManager.defaultManager removeItemAtURL:current error:nil]);
        report = DmDiagnosticReportCreate(documents, @{}, &error);
        assert(report && [readText(report) containsString:@"Log unavailable"]);

        NSURL *blocked = [documents URLByAppendingPathComponent:@"not-a-directory"];
        writeText(documents, @"not-a-directory", @"blocked");
        assert(!DmDiagnosticReportCreate(blocked, @{}, &error) && error);
        assert([NSFileManager.defaultManager removeItemAtURL:documents error:nil]);
        puts("diagnostic report and recovery tests passed");
    }
    return 0;
}
