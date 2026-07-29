#import "PBInputBridgePrivate.h"
#import <UIKit/UIKit.h>

static NSTimeInterval const kPBRecentInputTargetMaxAge = 30.0 * 60.0;
static NSTimeInterval const kPBOpenTriggerTargetMaxAge = 1.5;

static NSString *PBCurrentAppName(NSString *bundleId) {
  NSString *name =
      [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"];
  if (!name) {
    name = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];
  }
  if (!name && bundleId.length > 0) {
    name = [bundleId componentsSeparatedByString:@"."].lastObject;
  }
  return name ?: @"Unknown";
}

@implementation PBInputBridge (SourceState)

+ (void)recordCurrentProcessAsRecentInputTarget {
  NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
  NSString *processName = [[NSProcessInfo processInfo] processName] ?: @"";
  NSString *bundlePath = [NSBundle mainBundle].bundlePath ?: @"";
  NSSet<NSString *> *excludedBundleIds = [NSSet setWithArray:@[
    @"com.apple.springboard",
    @"com.apple.kbd",
    @"com.apple.pasteboard.pasted",
    @"com.apple.TextInputUI"
  ]];
  if (bundleId.length == 0 ||
      [excludedBundleIds containsObject:bundleId] ||
      ![[bundlePath.pathExtension lowercaseString] isEqualToString:@"app"]) {
    return;
  }

  NSDictionary *targetInfo = @{
    @"targetBundleId" : bundleId,
    @"targetAppName" : PBCurrentAppName(bundleId),
    @"processName" : processName,
    @"timestamp" : @([[NSDate date] timeIntervalSince1970]),
    @"targetResolutionSource" : @"recentEditableResponder"
  };
  __unused BOOL wrote =
      PBIOSCopyWritePropertyListToFile(targetInfo,
                                       PBInputBridgeRecentInputTargetPath(),
                                       NO);
  PBInputBridgeDebugLog(@"record input target wrote=%d bundle=%@ app=%@ process=%@",
                        wrote,
                        bundleId,
                        targetInfo[@"targetAppName"] ?: @"",
                        processName);
}

+ (NSDictionary *)recentInputTargetInfo {
  NSDictionary *targetInfo = [NSDictionary
      dictionaryWithContentsOfFile:PBInputBridgeRecentInputTargetPath()];
  if (![targetInfo isKindOfClass:[NSDictionary class]]) {
    return nil;
  }

  NSString *bundleId = targetInfo[@"targetBundleId"];
  NSNumber *timestamp = targetInfo[@"timestamp"];
  if (![bundleId isKindOfClass:[NSString class]] || bundleId.length == 0 ||
      ![timestamp isKindOfClass:[NSNumber class]]) {
    return nil;
  }

  NSTimeInterval age =
      [[NSDate date] timeIntervalSince1970] - timestamp.doubleValue;
  if (age < 0.0 || age > kPBRecentInputTargetMaxAge) {
    return nil;
  }

  return targetInfo;
}

+ (BOOL)recordOpenTriggerTargetFromRecentInputTarget {
  NSDictionary *inputTarget = [self recentInputTargetInfo];
  NSString *bundleId = inputTarget[@"targetBundleId"];
  if (![bundleId isKindOfClass:[NSString class]] || bundleId.length == 0) {
    return NO;
  }

  NSMutableDictionary *openTarget = [inputTarget mutableCopy];
  openTarget[@"timestamp"] = @([[NSDate date] timeIntervalSince1970]);
  openTarget[@"targetResolutionSource"] = @"inputBridgeTrigger";
  BOOL wrote = PBIOSCopyWritePropertyListToFile(
      openTarget, PBInputBridgeOpenTriggerTargetPath(), NO);
  PBInputBridgeDebugLog(@"record open target wrote=%d bundle=%@ app=%@",
                        wrote,
                        bundleId,
                        openTarget[@"targetAppName"] ?: @"");
  return wrote;
}

+ (NSDictionary *)consumeRecentOpenTriggerTargetInfo {
  NSString *path = PBInputBridgeOpenTriggerTargetPath();
  NSDictionary *targetInfo = [NSDictionary dictionaryWithContentsOfFile:path];
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
  if (![targetInfo isKindOfClass:[NSDictionary class]]) {
    return nil;
  }

  NSString *bundleId = targetInfo[@"targetBundleId"];
  NSNumber *timestamp = targetInfo[@"timestamp"];
  if (![bundleId isKindOfClass:[NSString class]] || bundleId.length == 0 ||
      ![timestamp isKindOfClass:[NSNumber class]]) {
    return nil;
  }

  NSTimeInterval age =
      [[NSDate date] timeIntervalSince1970] - timestamp.doubleValue;
  if (age < 0.0 || age > kPBOpenTriggerTargetMaxAge) {
    return nil;
  }

  return targetInfo;
}

+ (void)recordPasteboardSourceWithPasteboard:(id)pasteboard {
  [self recordPasteboardSourceWithPasteboard:pasteboard
                                     content:nil
                                   imageData:nil];
}

+ (void)recordPasteboardSourceWithPasteboard:(id)pasteboard
                                     content:(NSString *)content
                                   imageData:(NSData *)imageData {
  NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
  NSString *processName = [[NSProcessInfo processInfo] processName] ?: @"";
  if (PBIsSpringBoardBundle(bundleId, processName)) {
    PBInputBridgeDebugLog(
        @"skip source record in SpringBoard process bundle=%@ process=%@",
        bundleId, processName);
    return;
  }

  [self recordPasteboardSourceWithPasteboard:pasteboard
                                    bundleId:bundleId
                                     appName:PBCurrentAppName(bundleId)
                                 processName:processName
                                     content:content
                                   imageData:imageData];
}

+ (void)recordUniversalPasteboardSourceWithPasteboard:(id)pasteboard
                                              content:(NSString *)content
                                            imageData:(NSData *)imageData {
  [self recordPasteboardSourceWithPasteboard:pasteboard
                                    bundleId:@"com.apple.continuityclipboard"
                                     appName:@"Universal Clipboard"
                                 processName:[[NSProcessInfo processInfo]
                                                 processName]
                                                 ?: @"pasted"
                                     content:content
                                   imageData:imageData];
}

+ (void)recordPasteboardSourceWithPasteboard:(id)pasteboard
                                    bundleId:(NSString *)bundleId
                                     appName:(NSString *)appName
                                 processName:(NSString *)processName
                                     content:(NSString *)content
                                   imageData:(NSData *)imageData {
  UIPasteboard *generalPasteboard = [UIPasteboard generalPasteboard];
  NSInteger changeCount = -1;
  @try {
    changeCount = generalPasteboard.changeCount;
  } @catch (__unused NSException *exception) {
    changeCount = -1;
  }

  NSMutableDictionary *sourceInfo = [@{
    @"bundleId" : bundleId ?: @"",
    @"appName" : appName ?: @"Unknown",
    @"processName" : processName ?: @"",
    @"changeCount" : @(changeCount),
    @"timestamp" : @([[NSDate date] timeIntervalSince1970])
  } mutableCopy];

  // 来源记录只保存元数据，内容统一由 SpringBoard 在授权窗口内读取。
  if (content.length > 0) {
    sourceInfo[@"contentKind"] = @"text";
  } else if (imageData) {
    sourceInfo[@"contentKind"] = @"image";
    if (imageData.length > 0) {
      sourceInfo[@"imageBytes"] = @(imageData.length);
    }
  }

  // libSandy 精确授权的是目标 plist，atomic 写入会额外创建临时文件。
  __unused BOOL wrote =
      PBIOSCopyWritePropertyListToFile(sourceInfo, PBInputBridgeSourcePath(),
                                       NO);
  PBInputBridgeDebugLog(
      @"record source wrote=%d bundle=%@ app=%@ process=%@ changeCount=%ld "
      @"kind=%@ textLength=%lu imageBytes=%lu path=%@",
      wrote, bundleId, sourceInfo[@"appName"] ?: @"", processName,
      (long)changeCount, sourceInfo[@"contentKind"] ?: @"",
      (unsigned long)content.length, (unsigned long)imageData.length,
      PBInputBridgeSourcePath());
}

+ (NSDictionary *)recentPasteboardSourceInfoForChangeCount:
    (NSInteger)changeCount {
  NSDictionary *sourceInfo =
      [NSDictionary dictionaryWithContentsOfFile:PBInputBridgeSourcePath()];
  if (![sourceInfo isKindOfClass:[NSDictionary class]]) {
    PBInputBridgeDebugLog(
        @"recent source miss: plist missing or invalid for changeCount=%ld",
        (long)changeCount);
    return nil;
  }

  NSNumber *timestamp = sourceInfo[@"timestamp"];
  NSNumber *sourceChangeCount = sourceInfo[@"changeCount"];
  NSString *bundleId = sourceInfo[@"bundleId"];
  if (![timestamp isKindOfClass:[NSNumber class]] ||
      ![sourceChangeCount isKindOfClass:[NSNumber class]] ||
      sourceChangeCount.integerValue < 0 || bundleId.length == 0) {
    PBInputBridgeDebugLog(
        @"recent source miss: malformed source=%@ requestedChange=%ld",
        sourceInfo, (long)changeCount);
    return nil;
  }

  NSTimeInterval age =
      [[NSDate date] timeIntervalSince1970] - timestamp.doubleValue;
  if (age < 0 || age > kPBSourceInfoMaxAge) {
    PBInputBridgeDebugLog(@"recent source miss: age=%.3f sourceChange=%ld "
                          @"requestedChange=%ld bundle=%@",
                          age, (long)sourceChangeCount.integerValue,
                          (long)changeCount, bundleId);
    return nil;
  }

  if (changeCount > 0 && sourceChangeCount.integerValue != changeCount) {
    NSInteger sourceCount = sourceChangeCount.integerValue;
    NSInteger delta = labs(sourceCount - changeCount);
    BOOL tolerateMismatch = age <= kPBSourceInfoMismatchGraceAge &&
                            delta <= kPBSourceInfoMismatchGraceCount &&
                            changeCount <= sourceCount;
    if (!tolerateMismatch) {
      PBInputBridgeDebugLog(
          @"recent source miss: change mismatch sourceChange=%ld "
          @"requestedChange=%ld bundle=%@ age=%.3f",
          (long)sourceCount, (long)changeCount, bundleId, age);
      return nil;
    }

    PBInputBridgeDebugLog(@"recent source tolerated mismatch sourceChange=%ld "
                          @"requestedChange=%ld bundle=%@ age=%.3f",
                          (long)sourceCount, (long)changeCount, bundleId, age);
  }

  PBInputBridgeDebugLog(@"recent source hit: bundle=%@ app=%@ sourceChange=%ld "
                        @"requestedChange=%ld age=%.3f",
                        bundleId, sourceInfo[@"appName"] ?: @"",
                        (long)sourceChangeCount.integerValue, (long)changeCount,
                        age);
  return sourceInfo;
}

@end
