#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "../Manager/PBInputBridge.h"
#import "../Shared/PBPathUtilities.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <rootless.h>
#import <string.h>

static NSTimeInterval const kPBUniversalCaptureRepeatWindow = 1.0;
static NSInteger kPBLastUniversalCaptureChangeCount = NSIntegerMin;
static NSTimeInterval kPBLastUniversalCaptureRequestTime = 0;
static BOOL kPBContinuityLandingHookEnabled = NO;
static BOOL kPBIsProcessingContinuityLanding = NO;
static NSInteger kPBLastUniversalProbeChangeCount = NSIntegerMin;
static NSTimeInterval kPBLastUniversalProbeRequestTime = 0;

#if DEBUG_LOG
#define PBPastedBridgeDebugLog(...) \
    PBDiagnosticLog(PBDiagnosticStreamPasteAuth, @"PastedBridge", __VA_ARGS__)
#define PBPastedBridgeVerboseLog(...) \
    PBDiagnosticLog(PBDiagnosticStreamPasteAuth, @"PastedBridgeVerbose", __VA_ARGS__)
#define PBPasteAuthRecordDiagnosticPhase(...) \
    PBDiagnosticRecordEvent(PBDiagnosticStreamPasteAuth, __VA_ARGS__)
#else
#define PBPastedBridgeDebugLog(...) do { } while (0)
#define PBPastedBridgeVerboseLog(...) do { } while (0)
#define PBPasteAuthRecordDiagnosticPhase(...) do { } while (0)
#endif

#if DEBUG_LOG
static NSString *PBPastedBridgeSourceInfoPath(void) {
    return PBIOSCopyPreferenceFilePath(@"com.ssdsl.ioscopy.source.plist");
}

static NSDictionary *PBPastedBridgeRawSourceInfo(void) {
    NSDictionary *sourceInfo =
        [NSDictionary dictionaryWithContentsOfFile:PBPastedBridgeSourceInfoPath()];
    return [sourceInfo isKindOfClass:[NSDictionary class]] ? sourceInfo : nil;
}

static NSDictionary *PBPastedBridgeSanitizedSourceInfo(NSDictionary *sourceInfo) {
    if (![sourceInfo isKindOfClass:[NSDictionary class]]) {
        return @{};
    }

    NSMutableDictionary *sanitized = [NSMutableDictionary dictionary];
    [sourceInfo enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        if (![key isKindOfClass:[NSString class]]) {
            return;
        }

        NSString *keyString = (NSString *)key;
        if ([keyString isEqualToString:@"imageData"] && [value isKindOfClass:[NSData class]]) {
            sanitized[@"imageBytes"] = @([(NSData *)value length]);
        } else if ([keyString isEqualToString:@"content"] && [value isKindOfClass:[NSString class]]) {
            sanitized[@"contentLength"] = @([(NSString *)value length]);
        } else if ([value isKindOfClass:[NSString class]] ||
                   [value isKindOfClass:[NSNumber class]] ||
                   [value isKindOfClass:[NSDate class]]) {
            sanitized[keyString] = value;
        } else if (value) {
            sanitized[keyString] = [value description] ?: @"";
        }
    }];
    return sanitized;
}

static NSDictionary *PBPastedBridgeCurrentSourceDiagnosticInfo(void) {
    return PBPastedBridgeSanitizedSourceInfo(PBPastedBridgeRawSourceInfo());
}
#endif

static NSDictionary *PBPastedBridgeSourceInfo(NSString *bundleId,
                                              NSString *appName,
                                              NSString *processName,
                                              NSInteger changeCount,
                                              NSString *contentKind,
                                              NSUInteger imageBytes) {
    NSMutableDictionary *sourceInfo = [@{
        @"bundleId": bundleId ?: @"",
        @"appName": appName ?: @"Unknown",
        @"processName": processName ?: @"pasted",
        @"changeCount": @(changeCount),
        @"timestamp": @([[NSDate date] timeIntervalSince1970])
    } mutableCopy];

    if (contentKind.length > 0) {
        sourceInfo[@"contentKind"] = contentKind;
    }
    if (imageBytes > 0) {
        sourceInfo[@"imageBytes"] = @(imageBytes);
    }

    return sourceInfo;
}

typedef struct {
    BOOL hasRemoteMarker;
    BOOL hasImageType;
    BOOL hasCreator;
    BOOL hasSpringBoardCreator;
} PBPasteboardMetadataFlags;

static PBPasteboardMetadataFlags PBMetadataFlagsMerge(PBPasteboardMetadataFlags first,
                                                       PBPasteboardMetadataFlags second) {
    PBPasteboardMetadataFlags flags;
    flags.hasRemoteMarker = first.hasRemoteMarker || second.hasRemoteMarker;
    flags.hasImageType = first.hasImageType || second.hasImageType;
    flags.hasCreator = first.hasCreator || second.hasCreator;
    flags.hasSpringBoardCreator = first.hasSpringBoardCreator || second.hasSpringBoardCreator;
    return flags;
}

static NSString *PBObjectClassName(id object) {
    return object ? NSStringFromClass([object class]) : @"nil";
}

static NSInteger PBCurrentGeneralPasteboardChangeCount(void) {
    @try {
        return [UIPasteboard generalPasteboard].changeCount;
    } @catch (__unused NSException *exception) {
        return -1;
    }
}

static NSInteger PBResolvedPasteboardChangeCount(long long changeCount) {
    if (changeCount >= 0) {
        return (NSInteger)changeCount;
    }
    return PBCurrentGeneralPasteboardChangeCount();
}

static BOOL PBStringLooksRemotePasteboardMarker(NSString *string) {
    NSString *lower = [string lowercaseString];
    return [lower containsString:@"com.apple.is-remote-clipboard"] ||
           [lower containsString:@"continuityclipboard"] ||
           [lower containsString:@"universalclipboard"] ||
           [lower containsString:@"remotepasteboard"] ||
           [lower containsString:@"uasharedpasteboard"];
}

static BOOL PBStringLooksImagePasteboardType(NSString *string) {
    NSString *lower = [string lowercaseString];
    return [lower containsString:@"image"] ||
           [lower containsString:@"png"] ||
           [lower containsString:@"jpeg"] ||
           [lower containsString:@"jpg"] ||
           [lower containsString:@"heic"] ||
           [lower containsString:@"heif"] ||
           [lower containsString:@"tiff"] ||
           [lower containsString:@"gif"];
}

static BOOL PBStringLooksSpringBoardCreator(NSString *string) {
    NSString *lower = [string lowercaseString];
    return [lower isEqualToString:@"com.apple.springboard"] ||
           [lower isEqualToString:@"springboard"];
}

static id PBObjectByCallingSelectorName(id target, NSString *selectorName) {
    if (!target || selectorName.length == 0) {
        return nil;
    }

    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) {
        return nil;
    }

    @try {
        id (*sendObject)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        id value = sendObject(target, selector);
        return value != target ? value : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL PBBoolByCallingSelectorName(id target, NSString *selectorName) {
    if (!target || selectorName.length == 0) {
        return NO;
    }

    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) {
        return NO;
    }

    @try {
        BOOL (*sendBool)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
        return sendBool(target, selector);
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static PBPasteboardMetadataFlags PBMetadataFlagsFromObject(id object, NSUInteger depth);

static PBPasteboardMetadataFlags PBMetadataFlagsFromString(NSString *string,
                                                           BOOL treatAsType,
                                                           BOOL treatAsCreator) {
    PBPasteboardMetadataFlags flags = {0};
    if (string.length == 0) {
        return flags;
    }

    if (PBStringLooksRemotePasteboardMarker(string)) {
        flags.hasRemoteMarker = YES;
    }
    if (treatAsType && PBStringLooksImagePasteboardType(string)) {
        flags.hasImageType = YES;
    }
    if (treatAsCreator) {
        flags.hasCreator = YES;
        if (PBStringLooksSpringBoardCreator(string)) {
            flags.hasSpringBoardCreator = YES;
        }
    }
    return flags;
}

static PBPasteboardMetadataFlags PBMetadataFlagsFromCollection(id collection,
                                                               NSUInteger depth,
                                                               BOOL treatStringsAsTypes) {
    PBPasteboardMetadataFlags flags = {0};
    NSUInteger inspectedCount = 0;

    if ([collection isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)collection) {
            flags = PBMetadataFlagsMerge(flags, [value isKindOfClass:[NSString class]] ?
                PBMetadataFlagsFromString(value, treatStringsAsTypes, NO) :
                PBMetadataFlagsFromObject(value, depth + 1));
            if (++inspectedCount >= 16) {
                break;
            }
        }
    } else if ([collection isKindOfClass:[NSSet class]]) {
        for (id value in (NSSet *)collection) {
            flags = PBMetadataFlagsMerge(flags, [value isKindOfClass:[NSString class]] ?
                PBMetadataFlagsFromString(value, treatStringsAsTypes, NO) :
                PBMetadataFlagsFromObject(value, depth + 1));
            if (++inspectedCount >= 16) {
                break;
            }
        }
    }

    return flags;
}

static PBPasteboardMetadataFlags PBMetadataFlagsFromDictionary(NSDictionary *dictionary,
                                                               NSUInteger depth) {
    PBPasteboardMetadataFlags flags = {0};
    NSUInteger inspectedCount = 0;

    for (id key in dictionary) {
        if ([key isKindOfClass:[NSString class]]) {
            flags = PBMetadataFlagsMerge(flags,
                                         PBMetadataFlagsFromString(key, YES, NO));
        }

        id value = dictionary[key];
        if ([value isKindOfClass:[NSString class]]) {
            flags = PBMetadataFlagsMerge(flags,
                                         PBMetadataFlagsFromString(value, NO, NO));
        } else if ([value isKindOfClass:[NSArray class]] ||
                   [value isKindOfClass:[NSSet class]] ||
                   [value isKindOfClass:[NSDictionary class]]) {
            flags = PBMetadataFlagsMerge(flags,
                                         PBMetadataFlagsFromObject(value, depth + 1));
        }

        if (++inspectedCount >= 16) {
            break;
        }
    }

    return flags;
}

static PBPasteboardMetadataFlags PBMetadataFlagsFromObject(id object, NSUInteger depth) {
    PBPasteboardMetadataFlags flags = {0};
    if (!object || depth > 3 || [object isKindOfClass:[NSData class]]) {
        return flags;
    }

    NSString *className = PBObjectClassName(object);
    if (PBStringLooksRemotePasteboardMarker(className)) {
        flags.hasRemoteMarker = YES;
    }

    if ([object isKindOfClass:[NSString class]]) {
        return PBMetadataFlagsMerge(flags,
                                    PBMetadataFlagsFromString(object, NO, NO));
    }
    if ([object isKindOfClass:[NSArray class]] || [object isKindOfClass:[NSSet class]]) {
        return PBMetadataFlagsMerge(flags,
                                    PBMetadataFlagsFromCollection(object, depth, NO));
    }
    if ([object isKindOfClass:[NSDictionary class]]) {
        return PBMetadataFlagsMerge(flags,
                                    PBMetadataFlagsFromDictionary(object, depth));
    }

    for (NSString *selectorName in @[@"isRemote",
                                     @"isRemotePasteboard",
                                     @"isRemoteClipboard",
                                     @"isFromRemotePasteboard",
                                     @"isContinuityPasteboard"]) {
        if (PBBoolByCallingSelectorName(object, selectorName)) {
            flags.hasRemoteMarker = YES;
        }
    }

    for (NSString *selectorName in @[@"sourceDeviceName",
                                     @"sourceDevice",
                                     @"sourceDeviceIdentifier",
                                     @"remoteDeviceName"]) {
        id value = PBObjectByCallingSelectorName(object, selectorName);
        if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
            flags.hasRemoteMarker = YES;
        }
    }

    for (NSString *selectorName in @[@"creator",
                                     @"creatorBundleID",
                                     @"creatorBundleId",
                                     @"creatorBundleIdentifier"]) {
        id value = PBObjectByCallingSelectorName(object, selectorName);
        if ([value isKindOfClass:[NSString class]]) {
            flags = PBMetadataFlagsMerge(flags,
                                         PBMetadataFlagsFromString(value, NO, YES));
        }
    }

    for (NSString *selectorName in @[@"types",
                                     @"allTypes",
                                     @"typeIdentifiers",
                                     @"registeredTypeIdentifiers",
                                     @"_types"]) {
        id value = PBObjectByCallingSelectorName(object, selectorName);
        if ([value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSSet class]]) {
            flags = PBMetadataFlagsMerge(flags,
                                         PBMetadataFlagsFromCollection(value, depth, YES));
        } else if ([value isKindOfClass:[NSDictionary class]]) {
            flags = PBMetadataFlagsMerge(flags,
                                         PBMetadataFlagsFromDictionary(value, depth));
        }
    }

    for (NSString *selectorName in @[@"items", @"pasteboardItems", @"_items"]) {
        id value = PBObjectByCallingSelectorName(object, selectorName);
        if ([value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSSet class]]) {
            flags = PBMetadataFlagsMerge(flags,
                                         PBMetadataFlagsFromCollection(value, depth, NO));
        }
    }

    return flags;
}

static BOOL PBPasteAuthorizationShouldAllowSpringBoardPendingRead(id paste) {
    NSString *requestId =
        [PBInputBridge consumeSpringBoardPasteboardReadAuthorizationForChangeCount:-1
                                                                        policyName:@"PBCFUserNotificationPasteAnnouncer"
                                                                       dataPurpose:-1];
    BOOL shouldAllow = requestId.length > 0;
    NSString *captureReason = @"";
    NSInteger captureChangeCount = -1;
    if (!shouldAllow) {
        NSDictionary *captureRequest =
            [PBInputBridge recentSpringBoardPasteboardCaptureForPasteAnnouncement];
        NSString *captureRequestId = captureRequest[@"id"];
        NSString *reason = captureRequest[@"reason"];
        NSNumber *changeCount = captureRequest[@"changeCount"];
        if (captureRequestId.length > 0) {
            shouldAllow = YES;
            requestId = captureRequestId;
            captureReason = reason ?: @"";
            if ([changeCount isKindOfClass:[NSNumber class]]) {
                captureChangeCount = changeCount.integerValue;
            }
        }
    }

    PBPasteAuthRecordDiagnosticPhase(shouldAllow ?
                                     (captureReason.length > 0 ? @"request-allow-capture" : @"request-allow-pending") :
                                     @"request-default", @{
        @"pasteClass": paste ? NSStringFromClass([paste class]) : @"nil",
        @"requestId": requestId ?: @"",
        @"captureReason": captureReason ?: @"",
        @"captureChangeCount": @(captureChangeCount)
    });
    (void)captureReason;
    (void)captureChangeCount;
    PBPastedBridgeDebugLog(@"paste authorization pending allow=%d requestId=%@ captureReason=%@",
                           shouldAllow,
                           requestId ?: @"",
                           captureReason ?: @"");
    return shouldAllow;
}

static BOOL PBPastedAuthorizationHookIsSafe(void) {
    Class cls = NSClassFromString(@"PBCFUserNotificationPasteAnnouncer");
    Method method =
        class_getInstanceMethod(cls, @selector(requestAuthorizationForPaste:replyHandler:));
    return cls && method;
}

static BOOL PBInstanceMethodEncodingMatches(NSString *className,
                                            NSString *selectorName,
                                            const char *expectedEncoding) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        PBPastedBridgeDebugLog(@"skip continuity hook missing class=%@", className);
        return NO;
    }

    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        PBPastedBridgeDebugLog(@"skip continuity hook missing method=%@ %@", className, selectorName);
        return NO;
    }

    const char *encoding = method_getTypeEncoding(method);
    BOOL matches = encoding && expectedEncoding && strcmp(encoding, expectedEncoding) == 0;
    if (!matches) {
        __unused NSString *actual = encoding ? [NSString stringWithUTF8String:encoding] : @"";
        __unused NSString *expected = expectedEncoding ? [NSString stringWithUTF8String:expectedEncoding] : @"";
        PBPastedBridgeDebugLog(@"skip continuity hook encoding mismatch method=%@ %@ actual=%@ expected=%@",
                               className,
                               selectorName,
                               actual,
                               expected);
    }
    return matches;
}

static BOOL PBContinuityCaptureHooksAreSafe(void) {
    return PBInstanceMethodEncodingMatches(@"PBPasteboardModel",
                                           @"workQueue_savePasteboard:isServerToServerCopy:outNotificationState:outChangeCount:",
                                           "@44@0:8@16B24^Q28^q36");
}

static BOOL PBRemoteAvailabilityHookIsSafe(void) {
    return PBInstanceMethodEncodingMatches(@"PBPasteboardModel",
                                           @"_remotePasteboardDidBecomeAvailable:",
                                           "v20@0:8B16");
}

static BOOL PBRemoteGeneralPasteboardCreationHookIsSafe(void) {
    return PBInstanceMethodEncodingMatches(@"PBPasteboardModel",
                                           @"workQueue_createRemoteGeneralPasteboardWithChangeCount:",
                                           "v24@0:8q16");
}

static BOOL PBRemoteProbeHooksAreSafe(void) {
    return PBRemoteAvailabilityHookIsSafe() &&
           PBRemoteGeneralPasteboardCreationHookIsSafe();
}

static BOOL PBContinuityLandingHookIsSafe(void) {
    return PBInstanceMethodEncodingMatches(@"PBPasteboardModel",
                                           @"workQueue_saveGeneralPasteboardFromContinuityPasteboard:",
                                           "v24@0:8@16");
}

static void PBRequestSpringBoardCapture(NSString *reason,
                                        NSInteger changeCount,
                                        NSString *bundleId,
                                        NSString *appName,
                                        NSString *contentKind) {
    if (reason.length == 0 || (changeCount < 0 && changeCount != -1)) {
        return;
    }

    NSDictionary *sourceInfo = PBPastedBridgeSourceInfo(
        bundleId ?: @"",
        appName ?: @"Unknown",
        [[NSProcessInfo processInfo] processName] ?: @"pasted",
        changeCount,
        contentKind ?: @"",
        0);
    PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"pasted-request-sb-capture"
                                                details:@{
                                                    @"reason": reason ?: @"",
                                                    @"changeCount": @(changeCount),
                                                    @"bundleId": bundleId ?: @"",
                                                    @"appName": appName ?: @"",
                                                    @"contentKind": contentKind ?: @""
                                                });
    [PBInputBridge requestSpringBoardPasteboardCaptureWithReason:reason
                                                     changeCount:changeCount
                                                      sourceInfo:sourceInfo];
}

static BOOL PBShouldRequestUniversalProbe(NSInteger changeCount) {
    if (changeCount < 0) {
        return NO;
    }

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (kPBLastUniversalProbeChangeCount == changeCount &&
        now - kPBLastUniversalProbeRequestTime < kPBUniversalCaptureRepeatWindow) {
        return NO;
    }

    kPBLastUniversalProbeChangeCount = changeCount;
    kPBLastUniversalProbeRequestTime = now;
    return YES;
}

static void PBRequestUniversalProbeFromRemoteAvailability(void) {
    NSInteger changeCount = PBCurrentGeneralPasteboardChangeCount();
    if (!PBShouldRequestUniversalProbe(changeCount)) {
        PBPastedBridgeVerboseLog(@"skip duplicate universal probe changeCount=%ld",
                                 (long)changeCount);
        PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"pasted-universal-pull-skip-duplicate"
                                                    details:@{
                                                        @"changeCount": @(changeCount),
                                                        @"event": @"_remotePasteboardDidBecomeAvailable:"
                                                    });
        return;
    }

    PBPastedBridgeVerboseLog(@"request universal probe changeCount=%ld",
                             (long)changeCount);
    PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"pasted-universal-pull-request"
                                                details:@{
                                                    @"changeCount": @(changeCount),
                                                    @"event": @"_remotePasteboardDidBecomeAvailable:"
                                                });
    PBRequestSpringBoardCapture(@"universal-pull",
                                -1,
                                @"com.apple.continuityclipboard",
                                @"Universal Clipboard",
                                @"");
}

static void PBRequestUniversalProbeWithChangeCount(long long changeCount, NSString *eventName) {
    NSInteger resolvedChangeCount = PBResolvedPasteboardChangeCount(changeCount);
    if (!PBShouldRequestUniversalProbe(resolvedChangeCount)) {
        PBPastedBridgeVerboseLog(@"skip duplicate universal probe event=%@ changeCount=%ld",
                                 eventName ?: @"",
                                 (long)resolvedChangeCount);
        PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"pasted-universal-pull-skip-duplicate"
                                                    details:@{
                                                        @"changeCount": @(resolvedChangeCount),
                                                        @"event": eventName ?: @""
                                                    });
        return;
    }

    PBPastedBridgeVerboseLog(@"request universal probe event=%@ changeCount=%ld",
                             eventName ?: @"",
                             (long)resolvedChangeCount);
    PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"pasted-universal-pull-request"
                                                details:@{
                                                    @"changeCount": @(resolvedChangeCount),
                                                    @"event": eventName ?: @""
                                                });
    PBRequestSpringBoardCapture(@"universal-pull",
                                -1,
                                @"com.apple.continuityclipboard",
                                @"Universal Clipboard",
                                @"");
}

static BOOL PBShouldRequestUniversalCapture(NSInteger changeCount) {
    if (changeCount < 0 && changeCount != -1) {
        return NO;
    }

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (kPBLastUniversalCaptureChangeCount == changeCount &&
        now - kPBLastUniversalCaptureRequestTime < kPBUniversalCaptureRepeatWindow) {
        return NO;
    }

    kPBLastUniversalCaptureChangeCount = changeCount;
    kPBLastUniversalCaptureRequestTime = now;
    return YES;
}

static void PBRequestUniversalCaptureFromContinuityEvent(NSString *eventName, id pasteboard) {
    long long rawChangeCount = -1;
    if (pasteboard && [pasteboard respondsToSelector:NSSelectorFromString(@"changeCount")]) {
        @try {
            long long (*sendChangeCount)(id, SEL) = (long long (*)(id, SEL))objc_msgSend;
            rawChangeCount = sendChangeCount(pasteboard, NSSelectorFromString(@"changeCount"));
        } @catch (__unused NSException *exception) {
            rawChangeCount = -1;
        }
    }

    NSInteger changeCount = (rawChangeCount > 0) ? (NSInteger)rawChangeCount : -1;
    if (changeCount < 0 && changeCount != -1) {
        PBPastedBridgeVerboseLog(@"skip universal continuity event without valid changeCount event=%@ class=%@",
                                 eventName ?: @"",
                                 PBObjectClassName(pasteboard));
        PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"pasted-universal-capture-skip-invalid-count"
                                                    details:@{
                                                        @"event": eventName ?: @"",
                                                        @"pasteboardClass": PBObjectClassName(pasteboard) ?: @"",
                                                        @"changeCount": @(changeCount)
                                                    });
        return;
    }
    if (!PBShouldRequestUniversalCapture(changeCount)) {
        PBPastedBridgeVerboseLog(@"skip duplicate universal continuity event=%@ changeCount=%ld class=%@",
                                 eventName ?: @"",
                                 (long)changeCount,
                                 PBObjectClassName(pasteboard));
        PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"pasted-universal-capture-skip-duplicate"
                                                    details:@{
                                                        @"event": eventName ?: @"",
                                                        @"pasteboardClass": PBObjectClassName(pasteboard) ?: @"",
                                                        @"changeCount": @(changeCount)
                                                    });
        return;
    }

    PBPastedBridgeVerboseLog(@"request universal capture after continuity landing event=%@ changeCount=%ld class=%@",
                             eventName ?: @"",
                             (long)changeCount,
                             PBObjectClassName(pasteboard));
    PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"pasted-universal-capture-request"
                                                details:@{
                                                    @"event": eventName ?: @"",
                                                    @"pasteboardClass": PBObjectClassName(pasteboard) ?: @"",
                                                    @"changeCount": @(changeCount)
                                                });
    PBRequestSpringBoardCapture(@"universal",
                                changeCount,
                                @"com.apple.continuityclipboard",
                                @"Universal Clipboard",
                                @"");
}

%group PastedPasteAuthorizationHooks

%hook PBCFUserNotificationPasteAnnouncer

- (void)requestAuthorizationForPaste:(id)paste replyHandler:(void (^)(BOOL))replyHandler {
    PBPasteAuthRecordDiagnosticPhase(@"request-hook", @{
        @"pasteClass": paste ? NSStringFromClass([paste class]) : @"nil",
        @"hasReplyHandler": @(replyHandler != nil),
        @"rawSourceInfo": PBPastedBridgeCurrentSourceDiagnosticInfo()
    });
    if (replyHandler && PBPasteAuthorizationShouldAllowSpringBoardPendingRead(paste)) {
        replyHandler(YES);
        return;
    }

    %orig;
}

%end

%end

%group PastedContinuitySavePasteboardHooks

%hook PBPasteboardModel

- (id)workQueue_savePasteboard:(id)pasteboard
            isServerToServerCopy:(BOOL)isServerToServerCopy
            outNotificationState:(unsigned long long *)outNotificationState
                   outChangeCount:(long long *)outChangeCount {
    PBPastedBridgeVerboseLog(@"model workQueue_savePasteboard pasteboardClass=%@ serverToServer=%d",
                             PBObjectClassName(pasteboard),
                             isServerToServerCopy);
    PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"pasted-savePasteboard-enter"
                                                details:@{
                                                    @"pasteboardClass": PBObjectClassName(pasteboard) ?: @"",
                                                    @"isServerToServerCopy": @(isServerToServerCopy)
                                                });
    id result = %orig;
    long long changeCount = outChangeCount ? *outChangeCount : -1;
    NSInteger resolvedChangeCount = PBResolvedPasteboardChangeCount(changeCount);
    PBPastedBridgeVerboseLog(@"model workQueue_savePasteboard resultClass=%@ changeCount=%lld",
                             PBObjectClassName(result),
                             changeCount);
    PBPasteboardMetadataFlags metadataFlags = PBMetadataFlagsFromObject(pasteboard, 0);
    PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"pasted-savePasteboard-exit"
                                                details:@{
                                                    @"pasteboardClass": PBObjectClassName(pasteboard) ?: @"",
                                                    @"resultClass": PBObjectClassName(result) ?: @"",
                                                    @"changeCount": @(changeCount),
                                                    @"resolvedChangeCount": @(resolvedChangeCount),
                                                    @"isServerToServerCopy": @(isServerToServerCopy),
                                                    @"hasRemoteMarker": @(metadataFlags.hasRemoteMarker),
                                                    @"hasImageType": @(metadataFlags.hasImageType),
                                                    @"hasCreator": @(metadataFlags.hasCreator),
                                                    @"hasSpringBoardCreator": @(metadataFlags.hasSpringBoardCreator),
                                                    @"landingHookEnabled": @(kPBContinuityLandingHookEnabled)
                                                });
    if (isServerToServerCopy || metadataFlags.hasRemoteMarker || kPBIsProcessingContinuityLanding) {
        if (kPBContinuityLandingHookEnabled) {
            PBPastedBridgeVerboseLog(@"defer universal capture until continuity landing class=%@",
                                     PBObjectClassName(pasteboard));
            PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"pasted-savePasteboard-defer-universal"
                                                        details:@{
                                                            @"pasteboardClass": PBObjectClassName(pasteboard) ?: @"",
                                                            @"resolvedChangeCount": @(resolvedChangeCount),
                                                            @"isServerToServerCopy": @(isServerToServerCopy),
                                                            @"hasRemoteMarker": @(metadataFlags.hasRemoteMarker),
                                                            @"isContinuityLanding": @(kPBIsProcessingContinuityLanding)
                                                        });
            return result;
        }
        if (resolvedChangeCount < 0) {
            PBPastedBridgeVerboseLog(@"skip universal capture without valid changeCount class=%@",
                                     PBObjectClassName(pasteboard));
            return result;
        }
        PBPastedBridgeVerboseLog(@"request universal capture serverToServer=%d remote=%d changeCount=%ld class=%@",
                                 isServerToServerCopy,
                                 metadataFlags.hasRemoteMarker,
                                 (long)resolvedChangeCount,
                                 PBObjectClassName(pasteboard));
        PBRequestSpringBoardCapture(@"universal",
                                    resolvedChangeCount,
                                    @"com.apple.continuityclipboard",
                                    @"Universal Clipboard",
                                    @"");
        return result;
    }
    if (resolvedChangeCount < 0) {
        PBPastedBridgeVerboseLog(@"skip snapper capture without valid changeCount class=%@",
                                 PBObjectClassName(pasteboard));
        return result;
    }

    PBPastedBridgeVerboseLog(@"request snapper candidate changeCount=%ld image=%d creator=%d springboard=%d class=%@",
                             (long)resolvedChangeCount,
                             metadataFlags.hasImageType,
                             metadataFlags.hasCreator,
                             metadataFlags.hasSpringBoardCreator,
                             PBObjectClassName(pasteboard));
    PBRequestSpringBoardCapture(@"snapper",
                                resolvedChangeCount,
                                @"com.apple.springboard",
                                @"Snapper (截图)",
                                @"image");
    return result;
}

%end

%end

%group PastedRemoteAvailabilityHooks

%hook PBPasteboardModel

- (void)_remotePasteboardDidBecomeAvailable:(BOOL)available {
    %orig;
    PBPastedBridgeVerboseLog(@"remote pasteboard available=%d", available);
    PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"pasted-remote-available"
                                                details:@{
                                                    @"available": @(available),
                                                    @"currentChangeCount": @(PBCurrentGeneralPasteboardChangeCount())
                                                });
    if (available) {
        PBRequestUniversalProbeFromRemoteAvailability();
    }
}

- (void)workQueue_createRemoteGeneralPasteboardWithChangeCount:(long long)changeCount {
    %orig;
    PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"pasted-create-remote-general"
                                                details:@{
                                                    @"changeCount": @(changeCount),
                                                    @"currentChangeCount": @(PBCurrentGeneralPasteboardChangeCount())
                                                });
    PBRequestUniversalProbeWithChangeCount(changeCount,
                                           @"workQueue_createRemoteGeneralPasteboardWithChangeCount:");
}

%end

%end

%group PastedContinuityLandingHooks

%hook PBPasteboardModel

- (void)workQueue_saveGeneralPasteboardFromContinuityPasteboard:(id)continuityPasteboard {
    kPBIsProcessingContinuityLanding = YES;
    @try {
        %orig;
    } @finally {
        kPBIsProcessingContinuityLanding = NO;
    }
    PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"pasted-continuity-landing"
                                                details:@{
                                                    @"pasteboardClass": PBObjectClassName(continuityPasteboard) ?: @"",
                                                    @"currentChangeCount": @(PBCurrentGeneralPasteboardChangeCount())
                                                });
    PBRequestUniversalCaptureFromContinuityEvent(@"workQueue_saveGeneralPasteboardFromContinuityPasteboard:",
                                                 continuityPasteboard);
}

%end

%end

%ctor {
    @autoreleasepool {
        PBPastedBridgeDebugLog(@"loaded in process=%@ bundle=%@",
                               [[NSProcessInfo processInfo] processName] ?: @"",
                               [[NSBundle mainBundle] bundleIdentifier] ?: @"");
        BOOL authHookSafe = PBPastedAuthorizationHookIsSafe();
        BOOL continuitySaveHookSafe = PBContinuityCaptureHooksAreSafe();
        BOOL remoteProbeHooksSafe = PBRemoteProbeHooksAreSafe();
        BOOL continuityLandingHookSafe = PBContinuityLandingHookIsSafe();
        PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"pasted-ctor"
                                                    details:@{
                                                        @"authHookSafe": @(authHookSafe),
                                                        @"continuitySaveHookSafe": @(continuitySaveHookSafe),
                                                        @"remoteProbeHooksSafe": @(remoteProbeHooksSafe),
                                                        @"continuityLandingHookSafe": @(continuityLandingHookSafe)
                                                    });
        PBPasteAuthRecordDiagnosticPhase(@"ctor", @{
            @"announcerClassPresent": @(NSClassFromString(@"PBCFUserNotificationPasteAnnouncer") != Nil),
            @"authHookSafe": @(authHookSafe)
        });

        PBPastedBridgeVerboseLog(@"pasted UIPasteboard setter hooks disabled");

        if (authHookSafe) {
            %init(PastedPasteAuthorizationHooks);
            PBPasteAuthRecordDiagnosticPhase(@"hook-init", @{@"authHookSafe": @YES});
        } else {
            PBPasteAuthRecordDiagnosticPhase(@"hook-unavailable", @{@"authHookSafe": @NO});
            PBPastedBridgeVerboseLog(@"paste authorization announcer hook unavailable");
        }

        PBPastedBridgeVerboseLog(@"pasted _UIConcretePasteboard setter hooks disabled");

        if (continuitySaveHookSafe) {
            %init(PastedContinuitySavePasteboardHooks);
            PBPastedBridgeDebugLog(@"continuity savePasteboard hook enabled");
        } else {
            PBPastedBridgeDebugLog(@"continuity savePasteboard hook skipped");
        }

        if (remoteProbeHooksSafe) {
            %init(PastedRemoteAvailabilityHooks);
            PBPastedBridgeDebugLog(@"remote availability hooks enabled");
        } else {
            PBPastedBridgeDebugLog(@"remote availability hooks skipped");
        }

        if (continuityLandingHookSafe) {
            kPBContinuityLandingHookEnabled = YES;
            %init(PastedContinuityLandingHooks);
            PBPastedBridgeDebugLog(@"continuity landing hook enabled");
        } else {
            kPBContinuityLandingHookEnabled = NO;
            PBPastedBridgeDebugLog(@"continuity landing hook skipped");
        }

        if (NSClassFromString(@"PBServerPasteboard")) {
            PBPastedBridgeVerboseLog(@"PBServerPasteboard class present but service hook disabled");
        } else {
            PBPastedBridgeVerboseLog(@"PBServerPasteboard class missing");
        }

        if (NSClassFromString(@"PBServerPasteboardItem")) {
            PBPastedBridgeVerboseLog(@"PBServerPasteboardItem class present but service hook disabled");
        } else {
            PBPastedBridgeVerboseLog(@"PBServerPasteboardItem class missing");
        }
    }
}
