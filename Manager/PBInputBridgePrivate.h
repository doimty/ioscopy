#import "PBInputBridge.h"
#import "../Shared/PBPathUtilities.h"
#import "../Shared/PBPreferenceKeys.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <rootless.h>

#ifndef DEBUG_LOG
#define DEBUG_LOG 0
#endif

#ifndef IOSCOPY_INPUTBRIDGE_TWEAK
#define IOSCOPY_INPUTBRIDGE_TWEAK 0
#endif

static NSTimeInterval const kPBSourceInfoMaxAge = 20.0;
static NSTimeInterval const kPBInternalPasteInfoMaxAge = 8.0;
static NSTimeInterval const kPBOutgoingPasteboardSuppressionMaxAge = 1.2;
static NSTimeInterval const kPBSourceInfoMismatchGraceAge = 3.0;
static NSInteger const kPBSourceInfoMismatchGraceCount = 128;
static NSInteger const kPBMaxInsertRetries = 8;
static NSInteger const kPBMaxOneShotPasteboardPolicyAllows = 2;
static NSTimeInterval const kPBOneShotPasteboardReadAuthorizationTimeout = 0.85;
static NSTimeInterval const kPBOneShotPasteboardReadCloseDelay = 0.45;
static NSTimeInterval const kPBTemporaryPasteboardCleanupDelay = 0.35;
static NSTimeInterval const kPBKeyboardTextPasteboardCleanupDelay = 0.08;
static NSTimeInterval const kPBSpringBoardCaptureRequestMaxAge = 8.0;
static NSTimeInterval const kPBSpringBoardCaptureAnnouncementGraceAge = 1.5;
static NSTimeInterval const kPBSpringBoardReadAuthorizationTimeout = 3.0;
static NSInteger const kPBSpringBoardReadAuthorizationMaxAllows = 16;
static NSTimeInterval const kPBUniversalInboxDedupAge = 2.0;
static NSUInteger const kPBUniversalInboxMaxImageBytes = 25 * 1024 * 1024;
#define kPBImagePasteDiagnosticsEnabled DEBUG_LOG
#define kPBTextInsertDiagnosticsEnabled DEBUG_LOG

#if DEBUG_LOG
#define PBInputBridgeDebugLog(...) \
  PBDiagnosticLog(PBDiagnosticStreamPasteAuth, @"InputBridge", __VA_ARGS__)
#else
#define PBInputBridgeDebugLog(...) do { } while (0)
#endif

#if IOSCOPY_INPUTBRIDGE_TWEAK
#ifdef __cplusplus
extern "C" {
#endif
FOUNDATION_EXPORT void PBInputBridgeEnsureSandboxAccess(void);
#ifdef __cplusplus
}
#endif
#else
static inline void PBInputBridgeEnsureSandboxAccess(void) {}
#endif

static inline NSString *PBInputBridgePreferencePath(NSString *fileName) {
  PBInputBridgeEnsureSandboxAccess();
  return PBIOSCopyPreferenceFilePath(fileName);
}

static inline BOOL PBInputBridgeMainFeatureEnabled(void) {
  PBInputBridgeEnsureSandboxAccess();
  NSDictionary *prefs =
      [NSDictionary dictionaryWithContentsOfFile:PBIOSCopyMainPreferencesPath()];
  id value = [prefs isKindOfClass:[NSDictionary class]] ? prefs[kPBPreferenceEnabled] : nil;
  return value ? [value boolValue] : YES;
}

static inline NSString *PBInputBridgeRequestPath(void) {
  return PBInputBridgePreferencePath(@"com.ssdsl.ioscopy.insert.plist");
}

static inline NSString *PBInputBridgeSourcePath(void) {
  return PBInputBridgePreferencePath(@"com.ssdsl.ioscopy.source.plist");
}

static inline NSString *PBInputBridgeRecentInputTargetPath(void) {
  return PBInputBridgePreferencePath(@"com.ssdsl.ioscopy.inputtarget.plist");
}

static inline NSString *PBInputBridgeOpenTriggerTargetPath(void) {
  return PBInputBridgePreferencePath(@"com.ssdsl.ioscopy.opentarget.plist");
}

static inline NSString *PBInputBridgeInternalPastePath(void) {
  return PBInputBridgePreferencePath(@"com.ssdsl.ioscopy.internalpaste.plist");
}

static inline NSString *PBInputBridgeOutgoingPasteSuppressionPath(void) {
  return PBInputBridgePreferencePath(@"com.ssdsl.ioscopy.outgoingpaste.plist");
}

static inline NSString *PBInputBridgeSpringBoardCaptureRequestPath(void) {
  return PBInputBridgePreferencePath(@"com.ssdsl.ioscopy.sb.capture-request.plist");
}

static inline NSString *PBInputBridgeSpringBoardCaptureAnnouncementPath(void) {
  return PBInputBridgePreferencePath(@"com.ssdsl.ioscopy.sb.capture-announcement.plist");
}

static inline NSString *PBInputBridgeSpringBoardReadAuthorizationPath(void) {
  return PBInputBridgePreferencePath(@"com.ssdsl.ioscopy.sb.readauth.plist");
}

static inline NSString *PBInputBridgeUniversalInboxDirectoryPath(void) {
  return PBIOSCopyDataPath(@"universal-inbox");
}

static inline NSString *PBInputBridgeUniversalInboxDedupPath(void) {
  return PBInputBridgePreferencePath(@"com.ssdsl.ioscopy.universalinbox.dedup.plist");
}

static inline void PBInputBridgePostInsertNotification(void) {
  CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      (__bridge CFStringRef)PBInputBridgeInsertNotification, NULL, NULL, YES);
}

static inline BOOL PBIsSpringBoardBundle(NSString *bundleId,
                                         NSString *processName) {
  return [bundleId isEqualToString:@"com.apple.springboard"] ||
         [processName isEqualToString:@"SpringBoard"];
}

static inline NSDictionary *PBSanitizedSourceInfoForState(NSDictionary *sourceInfo) {
  if (![sourceInfo isKindOfClass:[NSDictionary class]]) {
    return nil;
  }

  NSMutableDictionary *sanitized = [NSMutableDictionary dictionary];
  [sourceInfo enumerateKeysAndObjectsUsingBlock:^(id key, id value,
                                                  BOOL *stop) {
    if (![key isKindOfClass:[NSString class]] || !value) {
      return;
    }

    NSString *keyString = (NSString *)key;
    if ([keyString isEqualToString:@"content"] ||
        [keyString isEqualToString:@"imageData"]) {
      return;
    }

    if ([value isKindOfClass:[NSString class]] ||
        [value isKindOfClass:[NSNumber class]] ||
        [value isKindOfClass:[NSDate class]]) {
      sanitized[keyString] = value;
    }
  }];

  return sanitized.count > 0 ? [sanitized copy] : nil;
}

#if DEBUG_LOG
static inline void PBClearTextInsertDiagnostic(void) {
  PBDiagnosticClearStream(PBDiagnosticStreamTextInsert);
}

static inline void PBRecordTextInsertDiagnosticPhase(NSString *phase,
                                                     NSString *requestId,
                                                     NSDictionary *details) {
  if (phase.length == 0) {
    return;
  }

  NSMutableDictionary *entry = [NSMutableDictionary dictionary];
  entry[@"requestId"] = requestId ?: @"";
  if ([details isKindOfClass:[NSDictionary class]]) {
    [entry addEntriesFromDictionary:details];
  }
  PBDiagnosticRecordEvent(PBDiagnosticStreamTextInsert, phase, entry);
}
#else
#define PBClearTextInsertDiagnostic() do { } while (0)
#define PBRecordTextInsertDiagnosticPhase(...) do { } while (0)
#endif

NSString *PBImagePasteboardTypeForData(NSData *data);
#if DEBUG_LOG
NSArray<NSString *> *PBImagePasteboardTypesForData(NSData *imageData);
#endif
BOOL PBSetPasteboardImageData(UIPasteboard *pasteboard,
                              NSData *imageData,
                              NSString **stagingMode);
BOOL PBSetPasteboardText(UIPasteboard *pasteboard,
                         NSString *text,
                         NSString **stagingMode);
NSInteger PBGeneralPasteboardChangeCount(UIPasteboard *pasteboard,
                                         BOOL *success);
