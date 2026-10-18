#import "DmDiagnosticReport.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>
#include "../../host/dm_log.h"

static NSURL *diagnosticFile(NSURL *documents, NSString *name) {
    return [[documents URLByAppendingPathComponent:@"diagnostics" isDirectory:YES] URLByAppendingPathComponent:name];
}

BOOL DmDiagnosticsPrepare(NSURL *documents, NSError **error) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *directory = [documents URLByAppendingPathComponent:@"diagnostics" isDirectory:YES];
    if (![fm createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    NSURL *marker = diagnosticFile(documents, @"run-active");
    NSURL *recovery = diagnosticFile(documents, @"recovery.log");
    BOOL interrupted = [fm fileExistsAtPath:marker.path];
    if (interrupted && ![fm fileExistsAtPath:recovery.path]) {
        NSURL *log = [documents URLByAppendingPathComponent:@"log.txt"];
        if ([fm fileExistsAtPath:log.path] && ![fm copyItemAtURL:log toURL:recovery error:error]) return YES;
    }
    return interrupted || [fm fileExistsAtPath:recovery.path];
}

BOOL DmDiagnosticsBeginRun(NSURL *documents, NSError **error) {
    NSURL *marker = diagnosticFile(documents, @"run-active");
    if (![[NSData data] writeToURL:marker options:NSDataWritingAtomic error:error]) return NO;
    // A new attempted run supersedes the retained recovery log.
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *recovery = diagnosticFile(documents, @"recovery.log");
    if ([fm fileExistsAtPath:recovery.path] && ![fm removeItemAtURL:recovery error:error]) return NO;
    return YES;
}

void DmDiagnosticsSetActive(NSURL *documents, BOOL active) {
    NSURL *marker = diagnosticFile(documents, @"run-active");
    if (active) [[NSData data] writeToURL:marker options:NSDataWritingAtomic error:nil];
    else [NSFileManager.defaultManager removeItemAtURL:marker error:nil];
}

static BOOL appendLog(FILE *output, NSURL *url, NSString *label) {
    fprintf(output, "\n===== %s =====\n", label.UTF8String);
    int fd = open(url.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) { fprintf(output, "[Log unavailable: errno %d]\n", errno); return YES; }
    struct stat st;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode)) {
        close(fd); fputs("[Not a regular log file]\n", output); return YES;
    }
    // Snapshot the size so an actively growing log cannot make export unbounded.
    off_t remaining = st.st_size, limit = 8 * 1024 * 1024;
    if (remaining > limit) {
        fprintf(output, "[Showing the last %lld of %lld bytes]\n", (long long)limit, (long long)remaining);
        if (lseek(fd, remaining - limit, SEEK_SET) < 0) { close(fd); return NO; }
        remaining = limit;
    }
    char buffer[65536];
    while (remaining > 0) {
        ssize_t n = read(fd, buffer, (size_t)MIN(remaining, (off_t)sizeof buffer));
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) { close(fd); return NO; }
        if (!n) break;
        if (fwrite(buffer, 1, (size_t)n, output) != (size_t)n) { close(fd); return NO; }
        remaining -= n;
    }
    close(fd);
    return !ferror(output);
}

NSURL *DmDiagnosticReportCreate(NSURL *documents, NSDictionary *metadata, NSError **error) {
    NSDate *exported = NSDate.date;
    NSISO8601DateFormatter *iso = NSISO8601DateFormatter.new;
    iso.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    NSMutableDictionary *reportMetadata = metadata.mutableCopy;
    reportMetadata[@"exported_at"] = [iso stringFromDate:exported];
    reportMetadata[@"log_timestamps"] = @"UTC ISO 8601 milliseconds; retained logs from older builds may lack timestamps.";
    reportMetadata[@"log_schema_version"] = @(DM_LOG_SCHEMA_VERSION);
    reportMetadata[@"log_format"] = @"[UTC timestamp] [LEVEL] [component] [thread=id] English message";
    reportMetadata[@"log_levels"] = @[@"DEBUG", @"INFO", @"WARN", @"ERROR", @"FATAL"];
    reportMetadata[@"log_compatibility"] = @"Historical logs are retained verbatim. Signal-context dumps may use continuation records; emergency records use Unix seconds when the stream is locked.";
    NSData *json = [NSJSONSerialization dataWithJSONObject:reportMetadata options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:error];
    if (!json) return nil;
    NSURL *directory = [documents URLByAppendingPathComponent:@"diagnostics" isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:error]) return nil;
    NSDateFormatter *filenameDate = NSDateFormatter.new;
    filenameDate.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    filenameDate.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    filenameDate.dateFormat = @"yyyyMMdd'T'HHmmss.SSS'Z'";
    NSString *filename = [NSString stringWithFormat:@"DarkSouls-diagnostics-%@-%@.txt",
        [filenameDate stringFromDate:exported], [NSUUID.UUID.UUIDString substringToIndex:8]];
    NSURL *destination = [directory URLByAppendingPathComponent:filename];
    NSURL *temporary = [directory URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".tmp"]];
    FILE *output = fopen(temporary.fileSystemRepresentation, "wx");
    if (!output) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return nil;
    }
    fputs("Dark Souls: Remastered diagnostics\n", output);
    BOOL ok = fwrite(json.bytes, 1, json.length, output) == json.length;
    NSArray<NSString *> *logs = @[@"log.txt", @"log.prev.txt", @"diagnostics/recovery.log"];
    for (NSString *name in logs)
        if (ok) ok = appendLog(output, [documents URLByAppendingPathComponent:name], name);
    int savedError = errno;
    if (fclose(output)) { ok = NO; savedError = errno; }
    if (ok && rename(temporary.fileSystemRepresentation, destination.fileSystemRepresentation)) { ok = NO; savedError = errno; }
    if (!ok) {
        unlink(temporary.fileSystemRepresentation);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:savedError ?: EIO userInfo:nil];
        return nil;
    }
    return destination;
}
