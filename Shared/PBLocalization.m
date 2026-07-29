#import "PBLocalization.h"
#import <rootless.h>

static NSBundle *PBLocalizationBundle(void) {
    static NSBundle *bundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray<NSBundle *> *candidates = [NSMutableArray array];

        Class prefsClass = NSClassFromString(@"PBRootListController");
        if (prefsClass) {
            NSBundle *prefsClassBundle = [NSBundle bundleForClass:prefsClass];
            if (prefsClassBundle) {
                [candidates addObject:prefsClassBundle];
            }
        }

        NSArray<NSString *> *candidatePaths = @[
            ROOT_PATH_NS(@"/Library/PreferenceBundles/iOSCopyPrefs.bundle"),
            ROOT_PATH_NS(@"/Library/Application Support/iOSCopy/Ressources.bundle")
        ];
        for (NSString *path in candidatePaths) {
            NSBundle *candidate = [NSBundle bundleWithPath:path];
            if (candidate) {
                [candidates addObject:candidate];
            }
        }

        for (NSBundle *candidate in candidates) {
            if ([candidate pathForResource:@"Localizable" ofType:@"strings"] ||
                [candidate pathForResource:@"Root" ofType:@"strings"]) {
                bundle = candidate;
                break;
            }
        }

        if (!bundle) {
            bundle = [NSBundle mainBundle];
        }
    });
    return bundle;
}

NSString *PBLocalizedString(NSString *key) {
    return PBLocalizedStringFromTable(key, @"Localizable", key);
}

NSString *PBLocalizedStringWithDefault(NSString *key, NSString *defaultValue) {
    return PBLocalizedStringFromTable(key, @"Localizable", defaultValue);
}

NSString *PBLocalizedStringFromTable(NSString *key, NSString *table, NSString *defaultValue) {
    NSBundle *bundle = PBLocalizationBundle();
    NSString *localized = NSLocalizedStringFromTableInBundle(key, table, bundle, nil);
    if (localized.length == 0 || ([localized isEqualToString:key] && defaultValue.length > 0)) {
        return defaultValue ?: key;
    }
    return localized;
}
