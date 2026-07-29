#import <Foundation/Foundation.h>

#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
#import <libroot/libroot.h>
#endif

#ifndef THEOS_PACKAGE_INSTALL_PREFIX
#define THEOS_PACKAGE_INSTALL_PREFIX ""
#endif

#ifndef IOSCOPY_FORCE_REAL_PREFERENCES_PATH
#define IOSCOPY_FORCE_REAL_PREFERENCES_PATH 0
#endif

static inline NSString *PBIOSCopyJailbreakRootPrefix(void) {
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
    const char *prefix = libroot_dyn_get_jbroot_prefix();
    if (prefix && prefix[0] != '\0') {
        return [NSString stringWithUTF8String:prefix];
    }
#endif

    return @THEOS_PACKAGE_INSTALL_PREFIX;
}

static inline BOOL PBIOSCopyIsRoothideRuntime(void) {
    NSString *prefix = PBIOSCopyJailbreakRootPrefix();
    return [prefix containsString:@"/var/containers/Bundle/Application/.jbroot"] ||
           [prefix containsString:@".jbroot-"];
}

static inline BOOL PBIOSCopyPathIsInsideJailbreakRoot(NSString *path) {
    NSString *standardPath = path.stringByStandardizingPath.lowercaseString ?: @"";
    NSString *rawPrefix = PBIOSCopyJailbreakRootPrefix();
    NSString *standardPrefix = rawPrefix.stringByStandardizingPath.lowercaseString ?: @"";
    if (standardPath.length == 0 || standardPrefix.length <= 1) {
        return NO;
    }

    NSMutableArray<NSString *> *prefixes = [NSMutableArray arrayWithObject:standardPrefix];
    if ([standardPrefix hasPrefix:@"/var/"]) {
        [prefixes addObject:[@"/private" stringByAppendingString:standardPrefix]];
    }

    for (NSString *prefix in prefixes) {
        NSString *directoryPrefix = [prefix hasSuffix:@"/"]
            ? prefix
            : [prefix stringByAppendingString:@"/"];
        if ([standardPath isEqualToString:prefix] ||
            [standardPath hasPrefix:directoryPrefix]) {
            return YES;
        }
    }
    return NO;
}

static inline NSString *PBIOSCopyJailbreakPath(NSString *logicalPath) {
    if (logicalPath.length == 0) {
        return @"";
    }
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
    NSString *runtimePath = JBROOT_PATH_NSSTRING(logicalPath);
    if (runtimePath.length > 0) {
        return runtimePath;
    }
#endif

    NSString *prefix = @THEOS_PACKAGE_INSTALL_PREFIX;
    return [prefix stringByAppendingString:logicalPath];
}

static inline NSString *PBIOSCopyRootlessPreferencesDirectoryPath(void) {
    return PBIOSCopyJailbreakPath(@"/var/mobile/Library/Preferences");
}

static inline NSString *PBIOSCopyPreferencesDirectoryPath(void) {
#if IOSCOPY_FORCE_REAL_PREFERENCES_PATH
    // 手动强制真实路径，便于特殊环境排查。
    return @"/var/mobile/Library/Preferences";
#else
    if (PBIOSCopyIsRoothideRuntime()) {
        // roothide 转换 rootless 包后，第三方 App 侧需要写真实 Preferences 路径。
        return @"/var/mobile/Library/Preferences";
    }

    // rootless 下写入越狱前缀路径，避免移除越狱后在真实系统目录残留。
    return PBIOSCopyRootlessPreferencesDirectoryPath();
#endif
}

static inline NSString *PBIOSCopyPreferenceFilePath(NSString *fileName) {
    return [PBIOSCopyPreferencesDirectoryPath()
        stringByAppendingPathComponent:fileName ?: @""];
}

static inline NSString *PBIOSCopyDataDirectoryPath(void) {
    static NSString *path = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        path = [PBIOSCopyJailbreakPath(@"/var/mobile/Library/iOSCopy") copy];
    });
    return path ?: @"";
}

static inline NSString *PBIOSCopyDataPath(NSString *relativePath) {
    NSString *base = PBIOSCopyDataDirectoryPath();
    if (base.length == 0) {
        return @"";
    }
    return [base stringByAppendingPathComponent:relativePath ?: @""];
}

static inline NSString *PBIOSCopyMainPreferencesPath(void) {
    return PBIOSCopyPreferenceFilePath(@"com.ssdsl.ioscopy.plist");
}

static inline void PBIOSCopyEnsureParentDirectoryForPath(NSString *path) {
    NSString *directory = [path stringByDeletingLastPathComponent];
    if (directory.length == 0) {
        return;
    }

    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
}

static inline BOOL PBIOSCopyWritePropertyListToFile(id propertyList,
                                                    NSString *path,
                                                    BOOL atomically) {
    PBIOSCopyEnsureParentDirectoryForPath(path);
    return [propertyList writeToFile:path atomically:atomically];
}
