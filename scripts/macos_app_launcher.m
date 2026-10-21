#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include "../dm/host/dm_log.h"
#include "../dm/host/dm_log_timestamp.h"

static void set_path(const char *name, NSString *path) {
    if (setenv(name, path.fileSystemRepresentation, 1) != 0) {
        perror("setenv");
        exit(1);
    }
}

static void make_directory(NSString *path) {
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:path
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&error]) {
        fprintf(stderr, "Cannot create directory %s: %s\n",
                path.fileSystemRepresentation, error.localizedDescription.UTF8String);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        NSBundle *bundle = NSBundle.mainBundle;
        NSString *resources = bundle.resourcePath;
        NSArray<NSString *> *supportPaths = NSSearchPathForDirectoriesInDomains(
            NSApplicationSupportDirectory, NSUserDomainMask, YES);
        if (!resources || !supportPaths.count) {
            fputs("Cannot resolve the app's resource or Application Support folder.\n", stderr);
            return 1;
        }

        NSString *support = [supportPaths[0] stringByAppendingPathComponent:@"Lordran Native"];
        NSString *save = [support stringByAppendingPathComponent:@"save"];
        NSString *temp = [support stringByAppendingPathComponent:@"temp"];
        NSString *logs = [support stringByAppendingPathComponent:@"logs"];
        make_directory(save);
        make_directory(temp);
        make_directory(logs);

        NSString *log = [logs stringByAppendingPathComponent:@"lordran-native.log"];
        int log_fd = open(log.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0600);
        if (log_fd < 0 || dup2(log_fd, STDERR_FILENO) < 0 || dup2(log_fd, STDOUT_FILENO) < 0) {
            perror("open/dup2 log");
            if (log_fd >= 0) close(log_fd);
            return 1;
        }
        close(log_fd);
        dm_log_timestamp_stderr();
        NSData *versionData = [NSData dataWithContentsOfFile:[resources stringByAppendingPathComponent:@"dm/app-version.json"]];
        id versionObject = versionData ? [NSJSONSerialization JSONObjectWithData:versionData options:0 error:nil] : nil;
        NSDictionary *sourceVersion = [versionObject isKindOfClass:NSDictionary.class] ? versionObject : @{};
        NSString *versionJSON = sourceVersion.count ? [[NSString alloc] initWithData:
            [NSJSONSerialization dataWithJSONObject:sourceVersion options:NSJSONWritingSortedKeys error:nil]
            encoding:NSUTF8StringEncoding] : @"unknown";
        DM_LOG_INFO("launcher", "App build identity: %s", versionJSON.UTF8String);

        NSString *host = [bundle.bundlePath stringByAppendingPathComponent:@"Contents/MacOS/dmhost"];
        NSString *romfs = [resources stringByAppendingPathComponent:@"game/RomFS"];
        NSString *modules = [resources stringByAppendingPathComponent:@"game/patched"];
        NSString *shaders = [resources stringByAppendingPathComponent:@"shaders"];
        NSString *fonts = [resources stringByAppendingPathComponent:@"fonts"];
        NSString *shaderMap = [resources stringByAppendingPathComponent:@"dm/shader_map.tsv"];

        set_path("DM_ROOT", support);
        set_path("DM_ROMFS", romfs);
        set_path("DM_SAVE", save);
        set_path("DM_TEMP", temp);
        set_path("DM_MSL_DIR", shaders);
        set_path("DM_FONT_DIR", fonts);
        set_path("DM_NVN_SHMAP", shaderMap);
        setenv("DM_WINDOW", "1", 1);
        setenv("DM_AUDIO", "1", 1);

        if (chdir(support.fileSystemRepresentation) != 0) {
            perror("chdir Application Support");
            return 1;
        }

        char *arguments[] = {
            (char *)host.fileSystemRepresentation,
            (char *)modules.fileSystemRepresentation,
            NULL
        };
        execv(host.fileSystemRepresentation, arguments);
        perror("execv dmhost");
        return 1;
    }
}
