// Copyright 2026 Кислов Роман Сергеевич
// SPDX-License-Identifier: Apache-2.0

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <string.h>

char *mac_bundle_info(const char *path) {
    @autoreleasepool {
        NSString *base = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:path length:strlen(path)];
        NSData *data = [NSData dataWithContentsOfFile:[base stringByAppendingPathComponent:@"Contents/Info.plist"]];
        id info = data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:nil] : nil;
        if (![info isKindOfClass:[NSDictionary class]]) return NULL;
        id identifier = info[@"CFBundleIdentifier"];
        id name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"];
        NSDictionary *result = @{@"bundleID": [identifier isKindOfClass:[NSString class]] ? identifier : @"",
                                 @"name": [name isKindOfClass:[NSString class]] ? name : @""};
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        return json ? strndup([json bytes], [json length]) : NULL;
    }
}

int mac_app_running(const char *path) {
    @autoreleasepool {
        NSString *string = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:path length:strlen(path)];
        for (NSRunningApplication *app in [[NSWorkspace sharedWorkspace] runningApplications]) {
            if ([[[app bundleURL] path] isEqualToString:string]) return 1;
        }
        return 0;
    }
}

char *mac_trash(const char *path) {
    @autoreleasepool {
        NSString *string = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:path length:strlen(path)];
        if (!string) return strdup("Invalid file name");
        NSError *error = nil;
        BOOL ok = [[NSFileManager defaultManager] trashItemAtURL:[NSURL fileURLWithPath:string]
                                              resultingItemURL:nil error:&error];
        if (ok) return NULL;
        return strdup([[error localizedDescription] UTF8String] ?: "Unable to move item to Trash");
    }
}
