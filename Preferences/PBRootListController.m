#import "PBRootListController.h"
#import "../Shared/PBLocalization.h"
#import "../Shared/PBPathUtilities.h"
#import <rootless.h>

static NSString * const kPBClearAllDataNotification = @"com.ssdsl.ioscopy/clearAllData";
static NSString * const kPBBuildImageTextIndexNotification = @"com.ssdsl.ioscopy/buildImageTextIndex";

static NSString *PBPreferencesPath(void) {
    return PBIOSCopyMainPreferencesPath();
}

@interface PBRootListController ()
@end

@implementation PBRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        [self localizeSpecifiers:_specifiers];
    }
    return _specifiers;
}

- (void)localizeSpecifiers:(NSArray<PSSpecifier *> *)specifiers {
    self.title = PBLocalizedStringFromTable(@"iOSCopy", @"Root", @"iOSCopy");

    for (PSSpecifier *specifier in specifiers) {
        if (specifier.name.length > 0) {
            specifier.name = PBLocalizedStringFromTable(specifier.name, @"Root", specifier.name);
        }

        for (NSString *key in @[PSTitleKey, PSFooterTextGroupKey, PSPlaceholderKey]) {
            NSString *value = [specifier propertyForKey:key];
            if ([value isKindOfClass:[NSString class]] && value.length > 0) {
                [specifier setProperty:PBLocalizedStringFromTable(value, @"Root", value) forKey:key];
            }
        }
    }
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *prefsPath = PBPreferencesPath();
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:prefsPath];

    NSString *key = [specifier propertyForKey:@"key"];
    id defaultValue = [specifier propertyForKey:@"default"];

    if (!prefs || !prefs[key]) return defaultValue;
    return prefs[key];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *prefsPath = PBPreferencesPath();
    NSMutableDictionary *prefs = [[NSDictionary dictionaryWithContentsOfFile:prefsPath] mutableCopy];
    if (!prefs) prefs = [NSMutableDictionary dictionary];

    NSString *key = [specifier propertyForKey:@"key"];
    [prefs setObject:value forKey:key];
    PBIOSCopyWritePropertyListToFile(prefs, prefsPath, YES);

    // Notify tweak about preference change
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.ssdsl.ioscopy/prefschanged"),
        NULL, NULL, YES
    );
}

- (void)clearAllData {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:PBLocalizedString(@"Clear All Data")
        message:PBLocalizedString(@"This will delete all clipboard history. This action cannot be undone.")
        preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:PBLocalizedString(@"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    [alert addAction:[UIAlertAction actionWithTitle:PBLocalizedString(@"Delete All")
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge CFStringRef)kPBClearAllDataNotification,
            NULL, NULL, YES
        );

        UIAlertController *done = [UIAlertController
            alertControllerWithTitle:PBLocalizedString(@"Done")
            message:PBLocalizedString(@"All clipboard history has been cleared.")
            preferredStyle:UIAlertControllerStyleAlert];
        [done addAction:[UIAlertAction actionWithTitle:PBLocalizedString(@"OK")
                                                 style:UIAlertActionStyleDefault
                                               handler:nil]];
        [self presentViewController:done animated:YES completion:nil];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)buildImageTextIndex {
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)kPBBuildImageTextIndexNotification,
        NULL, NULL, YES
    );

    UIAlertController *done = [UIAlertController
        alertControllerWithTitle:PBLocalizedString(@"Image Text Index")
        message:PBLocalizedString(@"iOSCopy will process up to 20 pending images in the background.")
        preferredStyle:UIAlertControllerStyleAlert];
    [done addAction:[UIAlertAction actionWithTitle:PBLocalizedString(@"OK")
                                             style:UIAlertActionStyleDefault
                                           handler:nil]];
    [self presentViewController:done animated:YES completion:nil];
}

- (void)resetPreferences {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:PBLocalizedString(@"Reset Settings")
        message:PBLocalizedString(@"Reset all settings to defaults?")
        preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:PBLocalizedString(@"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    [alert addAction:[UIAlertAction actionWithTitle:PBLocalizedString(@"Reset")
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        NSString *prefsPath = PBPreferencesPath();
        [[NSFileManager defaultManager] removeItemAtPath:prefsPath error:nil];

        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFSTR("com.ssdsl.ioscopy/prefschanged"),
            NULL, NULL, YES
        );

        [self reloadSpecifiers];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

@end
