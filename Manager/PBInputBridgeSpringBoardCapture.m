#import "PBInputBridgePrivate.h"

static NSInteger PBSpringBoardCaptureReasonPriority(NSString *reason) {
  if ([reason isEqualToString:@"app"]) {
    return 50;
  }
  if ([reason isEqualToString:@"snapper"] ||
      [reason isEqualToString:@"universal"]) {
    return 40;
  }
  if ([reason isEqualToString:@"universal-pull"]) {
    return 30;
  }
  if ([reason isEqualToString:@"pasted-local"]) {
    return 20;
  }
  return 0;
}

static BOOL PBCaptureRequestMatchesChangeCount(NSDictionary *request,
                                               NSInteger changeCount) {
  NSNumber *requestChangeCount = request[@"changeCount"];
  if (![requestChangeCount isKindOfClass:[NSNumber class]]) {
    return NO;
  }

  NSInteger oldChangeCount = requestChangeCount.integerValue;
  if (oldChangeCount < 0 || changeCount < 0 || oldChangeCount == changeCount) {
    return YES;
  }

  NSInteger delta = labs(oldChangeCount - changeCount);
  return delta <= kPBSourceInfoMismatchGraceCount;
}

static BOOL PBCaptureRequestAllowsPasteAnnouncement(NSDictionary *request) {
  if (![request isKindOfClass:[NSDictionary class]]) {
    return NO;
  }

  NSString *reason = request[@"reason"];
  NSDictionary *sourceInfo = request[@"sourceInfo"];
  NSString *bundleId = sourceInfo[@"bundleId"];
  return [reason isEqualToString:@"snapper"] &&
         [bundleId isEqualToString:@"com.apple.springboard"];
}

@implementation PBInputBridge (SpringBoardCapture)

+ (void)requestSpringBoardPasteboardCaptureWithReason:(NSString *)reason
                                          changeCount:(NSInteger)changeCount
                                           sourceInfo:(NSDictionary *)sourceInfo {
  if (!PBInputBridgeMainFeatureEnabled()) {
    return;
  }

  NSString *requestId = [NSUUID UUID].UUIDString;
  NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
  NSString *resolvedReason = reason.length > 0 ? reason : @"unknown";
  NSDictionary *resolvedSourceInfo = sourceInfo;
  NSNumber *resolvedCreatedAt = @(now);
  NSDictionary *existingRequest = [self pendingSpringBoardPasteboardCaptureRequest];
  NSString *existingReason = existingRequest[@"reason"];
  BOOL existingMatchesExactChangeCount = NO;
  NSNumber *existingChangeCount = existingRequest[@"changeCount"];
  if ([existingChangeCount isKindOfClass:[NSNumber class]]) {
    existingMatchesExactChangeCount =
        existingChangeCount.integerValue == changeCount ||
        existingChangeCount.integerValue < 0 || changeCount < 0;
  }
  NSInteger existingPriority =
      PBSpringBoardCaptureReasonPriority(existingReason);
  NSInteger resolvedPriority =
      PBSpringBoardCaptureReasonPriority(resolvedReason);
  PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"sb-capture-request-incoming"
                                      details:@{
                                        @"reason" : resolvedReason ?: @"",
                                        @"changeCount" : @(changeCount),
                                        @"priority" : @(resolvedPriority),
                                        @"existingReason" : existingReason ?: @"",
                                        @"existingPriority" : @(existingPriority),
                                        @"existingChangeCount" :
                                            existingChangeCount ?: @(-999999),
                                        @"existingRequestId" :
                                            existingRequest[@"id"] ?: @"",
                                        @"sourceInfo" : resolvedSourceInfo ?: @{}
                                      });
  if (existingMatchesExactChangeCount &&
      existingPriority >= resolvedPriority) {
    PBInputBridgeDebugLog(
        @"reuse SB capture request reason=%@ incoming=%@ changeCount=%ld id=%@",
        existingReason ?: @"", resolvedReason ?: @"", (long)changeCount,
        existingRequest[@"id"] ?: @"");
    PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"sb-capture-request-reuse"
                                        details:@{
                                          @"reason" : existingReason ?: @"",
                                          @"incomingReason" :
                                              resolvedReason ?: @"",
                                          @"changeCount" : @(changeCount),
                                          @"requestId" :
                                              existingRequest[@"id"] ?: @""
                                        });
    return;
  }

  if (PBCaptureRequestMatchesChangeCount(existingRequest, changeCount) &&
      existingPriority > resolvedPriority) {
    NSString *existingRequestId = existingRequest[@"id"];
    if (existingRequestId.length > 0) {
      requestId = existingRequestId;
    }
    resolvedReason = existingReason;
    NSNumber *existingTimestamp = existingRequest[@"timestamp"];
    if ([existingTimestamp isKindOfClass:[NSNumber class]]) {
      resolvedCreatedAt = existingTimestamp;
    }
    NSDictionary *existingSourceInfo = existingRequest[@"sourceInfo"];
    if ([existingSourceInfo isKindOfClass:[NSDictionary class]]) {
      resolvedSourceInfo = existingSourceInfo;
    }
  }

  NSMutableDictionary *request = [@{
    @"id" : requestId ?: @"",
    @"reason" : resolvedReason,
    @"changeCount" : @(changeCount),
    @"timestamp" : resolvedCreatedAt,
    @"expiresAt" : @(now + kPBSpringBoardCaptureRequestMaxAge),
    @"requestingProcess" : [[NSProcessInfo processInfo] processName] ?: @"",
    @"requestingBundleId" : [[NSBundle mainBundle] bundleIdentifier] ?: @""
  } mutableCopy];

  NSDictionary *sanitizedSourceInfo = PBSanitizedSourceInfoForState(resolvedSourceInfo);
  if (sanitizedSourceInfo) {
    request[@"sourceInfo"] = sanitizedSourceInfo;
  }

  // libSandy 精确授权的是目标 plist，atomic 写入会额外创建临时文件。
  __unused BOOL wrote =
      PBIOSCopyWritePropertyListToFile(
          request, PBInputBridgeSpringBoardCaptureRequestPath(), NO);
  PBInputBridgeDebugLog(@"request SB capture wrote=%d reason=%@ changeCount=%ld id=%@",
                        wrote,
                        request[@"reason"] ?: @"",
                        (long)changeCount,
                        requestId ?: @"");
  PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"sb-capture-request-wrote"
                                      details:@{
                                        @"wrote" : @(wrote),
                                        @"reason" : request[@"reason"] ?: @"",
                                        @"changeCount" : @(changeCount),
                                        @"requestId" : requestId ?: @"",
                                        @"sourceInfo" : request[@"sourceInfo"] ?: @{}
                                      });
  CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      (__bridge CFStringRef)PBInputBridgeSavePasteboardNotification, NULL, NULL,
      YES);
  PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"sb-capture-notification-posted"
                                      details:@{
                                        @"reason" : request[@"reason"] ?: @"",
                                        @"changeCount" : @(changeCount),
                                        @"requestId" : requestId ?: @""
                                      });
}

+ (NSDictionary *)pendingSpringBoardPasteboardCaptureRequest {
  NSDictionary *request =
      [NSDictionary dictionaryWithContentsOfFile:
                        PBInputBridgeSpringBoardCaptureRequestPath()];
  if (![request isKindOfClass:[NSDictionary class]]) {
    return nil;
  }

  NSNumber *expiresAt = request[@"expiresAt"];
  if (![expiresAt isKindOfClass:[NSNumber class]] ||
      [[NSDate date] timeIntervalSince1970] > expiresAt.doubleValue) {
    PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"sb-capture-request-expired"
                                        details:@{
                                          @"reason" : request[@"reason"] ?: @"",
                                          @"changeCount" :
                                              request[@"changeCount"] ?: @(-1),
                                          @"requestId" : request[@"id"] ?: @"",
                                          @"expiresAt" : expiresAt ?: @0
                                        });
    [[NSFileManager defaultManager]
        removeItemAtPath:PBInputBridgeSpringBoardCaptureRequestPath()
                   error:nil];
    return nil;
  }

  return request;
}

+ (NSDictionary *)recentSpringBoardPasteboardCaptureForPasteAnnouncement {
  NSDictionary *pendingRequest = [self pendingSpringBoardPasteboardCaptureRequest];
  if (PBCaptureRequestAllowsPasteAnnouncement(pendingRequest)) {
    return pendingRequest;
  }

  NSDictionary *announcement =
      [NSDictionary dictionaryWithContentsOfFile:
                        PBInputBridgeSpringBoardCaptureAnnouncementPath()];
  if (![announcement isKindOfClass:[NSDictionary class]]) {
    return nil;
  }

  NSNumber *expiresAt = announcement[@"expiresAt"];
  if (![expiresAt isKindOfClass:[NSNumber class]] ||
      [[NSDate date] timeIntervalSince1970] > expiresAt.doubleValue) {
    [[NSFileManager defaultManager]
        removeItemAtPath:PBInputBridgeSpringBoardCaptureAnnouncementPath()
                   error:nil];
    return nil;
  }

  return PBCaptureRequestAllowsPasteAnnouncement(announcement) ? announcement : nil;
}

+ (void)completeSpringBoardPasteboardCaptureRequestWithRequestId:(NSString *)requestId {
  if (requestId.length == 0) {
    return;
  }

  NSDictionary *request =
      [NSDictionary dictionaryWithContentsOfFile:
                        PBInputBridgeSpringBoardCaptureRequestPath()];
  NSString *activeRequestId = request[@"id"];
  if (activeRequestId.length > 0 &&
      [activeRequestId isEqualToString:requestId]) {
    if (PBCaptureRequestAllowsPasteAnnouncement(request)) {
      NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
      NSMutableDictionary *announcement = [request mutableCopy];
      announcement[@"timestamp"] = @(now);
      announcement[@"expiresAt"] =
          @(now + kPBSpringBoardCaptureAnnouncementGraceAge);
      PBIOSCopyWritePropertyListToFile(
          announcement, PBInputBridgeSpringBoardCaptureAnnouncementPath(), YES);
    }

    [[NSFileManager defaultManager]
        removeItemAtPath:PBInputBridgeSpringBoardCaptureRequestPath()
                   error:nil];
    PBInputBridgeDebugLog(@"complete SB capture request id=%@", requestId);
    PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"sb-capture-request-completed"
                                        details:@{
                                          @"requestId" : requestId ?: @"",
                                          @"reason" : request[@"reason"] ?: @"",
                                          @"changeCount" :
                                              request[@"changeCount"] ?: @(-1)
                                        });
  }
}

@end
