/*
 * iOSCopy — CopyLog Replacement
 * Tweak.xm — Main Hook Entry Point
 *
 * Features:
 * 1. Listens for DockX's CopyLog notification to show clipboard UI
 * 2. Bypasses iOS 16+ clipboard prompts only for iOSCopy's own reads
 * 3. Initializes clipboard monitoring in SpringBoard
 * 4. App text insertion lives in the iOSCopyInputBridge subproject
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <rootless.h>

#import "UI/PBMainViewController.h"
#import "Manager/PBClipboardManager.h"
#import "Manager/PBInputBridge.h"
#import "Shared/PBPathUtilities.h"
#import "Shared/PBPreferenceKeys.h"

extern BOOL PBIsInternalPasteboardRead;

static NSString * const kPBInternalPasteboardReadThreadKey = @"com.ssdsl.ioscopy.internalPasteboardRead";

#if DEBUG_LOG
#define PBSpringBoardDebugLog(...) \
    PBDiagnosticLog(PBDiagnosticStreamPasteAuth, @"SpringBoard", __VA_ARGS__)
#define PBSpringBoardPasteAuthDiagnostic(...) \
    PBDiagnosticRecordEvent(PBDiagnosticStreamPasteAuth, __VA_ARGS__)
#else
#define PBSpringBoardDebugLog(...) do { } while (0)
#define PBSpringBoardPasteAuthDiagnostic(...) do { } while (0)
#endif

// ─── DockX Compatibility ─────────────────────────────────────────────
// DockX sends this Darwin notification when user taps the CopyLog button.
// We listen for it and show our clipboard UI.
static NSString * const kCopyLogOpenViewIdentifier = @"me.tomt000.copylog.showView";
static NSString * const kPBDismissViewIdentifier = @"com.ssdsl.ioscopy/dismissView";

static BOOL PBIOSCopyPreferenceBool(NSString *key, BOOL defaultValue) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:PBIOSCopyMainPreferencesPath()];
    id value = [prefs isKindOfClass:[NSDictionary class]] ? prefs[key] : nil;
    return value ? [value boolValue] : defaultValue;
}

static BOOL PBIOSCopyEnabled(void) {
    return PBIOSCopyPreferenceBool(kPBPreferenceEnabled, YES);
}

static void showClipboardView(CFNotificationCenterRef center,
                               void *observer,
                               CFNotificationName name,
                               const void *object,
                               CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        PBMainViewController *vc = [PBMainViewController sharedInstance];
        if (!PBIOSCopyEnabled()) {
            if (vc.isPresented) {
                [vc dismissAnimated:YES];
            }
            return;
        }

        if (vc.isPresented) {
            [vc dismissAnimated:YES];
        } else {
            [vc showAnimated:YES];
        }
    });
}

static void dismissClipboardView(CFNotificationCenterRef center,
                                 void *observer,
                                 CFNotificationName name,
                                 const void *object,
                                 CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        PBMainViewController *vc = [PBMainViewController sharedInstance];
        if (vc.isPresented) {
            [vc dismissAnimated:YES];
        }
    });
}

static BOOL PBIsSpringBoardProcess(NSString *processName, NSString *bundleId) {
    return [bundleId isEqualToString:@"com.apple.springboard"] ||
           [processName isEqualToString:@"SpringBoard"];
}

static BOOL PBCurrentThreadAllowsPasteboardPolicyBypass(void) {
    return [[[NSThread currentThread].threadDictionary objectForKey:kPBInternalPasteboardReadThreadKey] boolValue];
}

static BOOL PBSpringBoardAllowsPasteboardPolicyBypass(void) {
    return PBCurrentThreadAllowsPasteboardPolicyBypass() || PBIsInternalPasteboardRead;
}

static BOOL PBSpringBoardConsumePasteboardReadAuthorization(NSString *policyName,
                                                            long long dataPurpose) {
    if (!PBSpringBoardAllowsPasteboardPolicyBypass()) {
        PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"springboard-policy-no-bypass"
                                                    details:@{
                                                        @"policyName": policyName ?: @"",
                                                        @"dataPurpose": @(dataPurpose),
                                                        @"threadAllowsBypass": @(PBCurrentThreadAllowsPasteboardPolicyBypass()),
                                                        @"globalInternalRead": @(PBIsInternalPasteboardRead)
                                                    });
        return NO;
    }

    NSString *requestId =
        [PBInputBridge consumeSpringBoardPasteboardReadAuthorizationForChangeCount:-1
                                                                        policyName:policyName
                                                                       dataPurpose:dataPurpose];
    PBSpringBoardDebugLog(@"policy pending name=%@ purpose=%lld allow=%d id=%@",
                          policyName ?: @"",
                          dataPurpose,
                          requestId.length > 0,
                          requestId ?: @"");
    PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"springboard-policy-consume-result"
                                                details:@{
                                                    @"policyName": policyName ?: @"",
                                                    @"dataPurpose": @(dataPurpose),
                                                    @"allowed": @(requestId.length > 0),
                                                    @"requestId": requestId ?: @"",
                                                    @"threadAllowsBypass": @(PBCurrentThreadAllowsPasteboardPolicyBypass()),
                                                    @"globalInternalRead": @(PBIsInternalPasteboardRead)
                                                });
    return requestId.length > 0;
}

// ─── SpringBoard-only pasteboard read guard ──────────────────────────
// Only iOSCopy's own read path is allowed. Normal app pasteboard reads still
// go through the system policy.

%group SpringBoardPasteboardPolicy

%hook UIPasteboard

// Hook the internal method that checks paste permission
// On iOS 16+, this triggers the "Allow Paste" system alert
- (void)_checkPolicyForPasteboardName:(id)arg1 dataPurpose:(long long)arg2 options:(id)arg3 completionHandler:(void (^)(BOOL, NSError *))arg4 {
    BOOL internalRead = PBSpringBoardAllowsPasteboardPolicyBypass();
    PBSpringBoardDebugLog(@"policy dataPurpose name=%@ purpose=%lld internalRead=%d global=%d",
                          arg1,
                          arg2,
                          internalRead,
                          PBIsInternalPasteboardRead);
    if (arg4 && PBSpringBoardConsumePasteboardReadAuthorization(@"dataPurpose", arg2)) {
        arg4(YES, nil);
        return;
    }

    if (internalRead) {
        PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"springboard-policy-fallback-orig"
                                                    details:@{
                                                        @"policyName": @"dataPurpose",
                                                        @"dataPurpose": @(arg2)
                                                    });
    }
    %orig;
}

- (void)_checkPolicyForPasteboardName:(id)arg1 options:(id)arg2 completionHandler:(void (^)(BOOL, NSError *))arg3 {
    BOOL internalRead = PBSpringBoardAllowsPasteboardPolicyBypass();
    PBSpringBoardDebugLog(@"policy options name=%@ internalRead=%d global=%d",
                          arg1,
                          internalRead,
                          PBIsInternalPasteboardRead);
    if (arg3 && PBSpringBoardConsumePasteboardReadAuthorization(@"options", -1)) {
        arg3(YES, nil);
        return;
    }

    if (internalRead) {
        PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"springboard-policy-fallback-orig"
                                                    details:@{
                                                        @"policyName": @"options",
                                                        @"dataPurpose": @(-1)
                                                    });
    }
    %orig;
}

- (void)_checkPolicyForPasteboardName:(id)arg1 completionHandler:(void (^)(BOOL, NSError *))arg2 {
    BOOL internalRead = PBSpringBoardAllowsPasteboardPolicyBypass();
    PBSpringBoardDebugLog(@"policy completion name=%@ internalRead=%d global=%d",
                          arg1,
                          internalRead,
                          PBIsInternalPasteboardRead);
    if (arg2 && PBSpringBoardConsumePasteboardReadAuthorization(@"completion", -1)) {
        arg2(YES, nil);
        return;
    }

    if (internalRead) {
        PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"springboard-policy-fallback-orig"
                                                    details:@{
                                                        @"policyName": @"completion",
                                                        @"dataPurpose": @(-1)
                                                    });
    }
    %orig;
}

- (void)_checkPolicyForPasteboardName:(id)arg1 withCompletionHandler:(void (^)(BOOL, NSError *))arg2 {
    BOOL internalRead = PBSpringBoardAllowsPasteboardPolicyBypass();
    PBSpringBoardDebugLog(@"policy withCompletion name=%@ internalRead=%d global=%d",
                          arg1,
                          internalRead,
                          PBIsInternalPasteboardRead);
    if (arg2 && PBSpringBoardConsumePasteboardReadAuthorization(@"withCompletion", -1)) {
        arg2(YES, nil);
        return;
    }

    if (internalRead) {
        PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"springboard-policy-fallback-orig"
                                                    details:@{
                                                        @"policyName": @"withCompletion",
                                                        @"dataPurpose": @(-1)
                                                    });
    }
    %orig;
}

%end

%end

// ─── Constructor ────────────────────────────────────────────────────

%ctor {
    @autoreleasepool {
        NSString *processName = [[NSProcessInfo processInfo] processName];
        NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];

        PBSpringBoardDebugLog(@"loading in process=%@ bundle=%@",
                              processName ?: @"",
                              bundleId ?: @"");

        if (!PBIsSpringBoardProcess(processName, bundleId)) return;

        %init(SpringBoardPasteboardPolicy);
        PBSpringBoardDebugLog(@"loaded in process=%@ bundle=%@",
                              processName ?: @"",
                              bundleId ?: @"");
        PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"springboard-ctor"
                                                    details:@{
                                                        @"processName": processName ?: @"",
                                                        @"bundleId": bundleId ?: @""
                                                    });
        PBSpringBoardPasteAuthDiagnostic(@"springboard-ctor", @{
            @"processName": processName ?: @"",
            @"bundleId": bundleId ?: @""
        });

        // Register for DockX's CopyLog notification
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            showClipboardView,
            (__bridge CFStringRef)kCopyLogOpenViewIdentifier,
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            dismissClipboardView,
            (__bridge CFStringRef)kPBDismissViewIdentifier,
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );

        // Start clipboard monitoring
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[PBClipboardManager sharedManager] startMonitoring];
        });
    }
}
