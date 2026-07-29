#import "PBInputBridgePrivate.h"
#import <UIKit/UIKit.h>

@implementation PBInputBridge (OutgoingSuppression)

+ (void)beginOutgoingPasteboardSuppressionForRequestId:(NSString *)requestId
                                           contentKind:(NSString *)contentKind
                                            targetInfo:(NSDictionary *)targetInfo {
  NSInteger startChangeCount = -1;
  @try {
    startChangeCount = [UIPasteboard generalPasteboard].changeCount;
  } @catch (__unused NSException *exception) {
    startChangeCount = -1;
  }

  NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
  NSMutableDictionary *info = [@{
    @"requestId" : requestId ?: @"",
    @"contentKind" : contentKind ?: @"",
    @"startChangeCount" : @(startChangeCount),
    @"timestamp" : @(now),
    @"expiresAt" : @(now + kPBOutgoingPasteboardSuppressionMaxAge)
  } mutableCopy];
  NSDictionary *sanitizedTargetInfo = PBSanitizedSourceInfoForState(targetInfo);
  if (sanitizedTargetInfo) {
    info[@"targetInfo"] = sanitizedTargetInfo;
  }

  // libSandy 精确授权的是目标 plist，atomic 写入会额外创建临时文件。
  __unused BOOL wrote =
      PBIOSCopyWritePropertyListToFile(
          info, PBInputBridgeOutgoingPasteSuppressionPath(), NO);
  PBInputBridgeDebugLog(
      @"begin outgoing paste suppression wrote=%d requestId=%@ kind=%@ "
      @"startChange=%ld",
      wrote, requestId ?: @"", contentKind ?: @"", (long)startChangeCount);
}

+ (NSDictionary *)activeOutgoingPasteboardSuppressionInfoForChangeCount:
    (NSInteger)changeCount {
  NSDictionary *info = [NSDictionary
      dictionaryWithContentsOfFile:PBInputBridgeOutgoingPasteSuppressionPath()];
  if (![info isKindOfClass:[NSDictionary class]]) {
    return nil;
  }

  NSNumber *expiresAt = info[@"expiresAt"];
  NSNumber *timestamp = info[@"timestamp"];
  NSNumber *startChangeCount = info[@"startChangeCount"];
  if (![expiresAt isKindOfClass:[NSNumber class]] ||
      ![timestamp isKindOfClass:[NSNumber class]] ||
      ![startChangeCount isKindOfClass:[NSNumber class]]) {
    [[NSFileManager defaultManager]
        removeItemAtPath:PBInputBridgeOutgoingPasteSuppressionPath()
                   error:nil];
    return nil;
  }

  NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
  if (now > expiresAt.doubleValue ||
      now - timestamp.doubleValue > kPBOutgoingPasteboardSuppressionMaxAge) {
    [[NSFileManager defaultManager]
        removeItemAtPath:PBInputBridgeOutgoingPasteSuppressionPath()
                   error:nil];
    return nil;
  }

  NSInteger startCount = startChangeCount.integerValue;
  if (changeCount <= startCount || changeCount - startCount > 64) {
    return nil;
  }

  PBInputBridgeDebugLog(
      @"outgoing paste suppression hit requestId=%@ kind=%@ start=%ld "
      @"requested=%ld",
      info[@"requestId"] ?: @"", info[@"contentKind"] ?: @"",
      (long)startCount, (long)changeCount);
  return info;
}

@end
