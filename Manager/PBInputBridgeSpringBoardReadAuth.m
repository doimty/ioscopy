#import "PBInputBridgePrivate.h"

@implementation PBInputBridge (SpringBoardReadAuth)

+ (NSString *)beginSpringBoardPasteboardReadAuthorizationForChangeCount:(NSInteger)changeCount
                                                                 reason:(NSString *)reason
                                                             sourceInfo:(NSDictionary *)sourceInfo {
  NSString *requestId = [NSUUID UUID].UUIDString;
  NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
  NSMutableDictionary *authorization = [@{
    @"id" : requestId ?: @"",
    @"reason" : reason.length > 0 ? reason : @"unknown",
    @"changeCount" : @(changeCount),
    @"timestamp" : @(now),
    @"expiresAt" : @(now + kPBSpringBoardReadAuthorizationTimeout),
    @"allowCount" : @0,
    @"maxAllowCount" : @(kPBSpringBoardReadAuthorizationMaxAllows),
    @"requestingProcess" : [[NSProcessInfo processInfo] processName] ?: @"",
    @"requestingBundleId" : [[NSBundle mainBundle] bundleIdentifier] ?: @""
  } mutableCopy];

  NSDictionary *sanitizedSourceInfo = PBSanitizedSourceInfoForState(sourceInfo);
  if (sanitizedSourceInfo) {
    authorization[@"sourceInfo"] = sanitizedSourceInfo;
  }

  BOOL wrote = PBIOSCopyWritePropertyListToFile(
      authorization, PBInputBridgeSpringBoardReadAuthorizationPath(), YES);
  PBInputBridgeDebugLog(@"begin SB read auth wrote=%d reason=%@ changeCount=%ld id=%@",
                        wrote,
                        authorization[@"reason"] ?: @"",
                        (long)changeCount,
                        requestId ?: @"");
  PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"sb-read-auth-begin"
                                      details:@{
                                        @"wrote" : @(wrote),
                                        @"reason" :
                                            authorization[@"reason"] ?: @"",
                                        @"changeCount" : @(changeCount),
                                        @"requestId" : requestId ?: @"",
                                        @"maxAllowCount" :
                                            authorization[@"maxAllowCount"] ?: @0,
                                        @"sourceInfo" :
                                            authorization[@"sourceInfo"] ?: @{}
                                      });
  return wrote ? requestId : nil;
}

+ (NSString *)consumeSpringBoardPasteboardReadAuthorizationForChangeCount:(NSInteger)changeCount
                                                               policyName:(NSString *)policyName
                                                              dataPurpose:(long long)dataPurpose {
  NSMutableDictionary *authorization =
      [[NSDictionary dictionaryWithContentsOfFile:
                         PBInputBridgeSpringBoardReadAuthorizationPath()]
          mutableCopy];
  if (![authorization isKindOfClass:[NSMutableDictionary class]]) {
    PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"sb-read-auth-missing"
                                        details:@{
                                          @"policyName" : policyName ?: @"",
                                          @"dataPurpose" : @(dataPurpose),
                                          @"requestedChangeCount" :
                                              @(changeCount)
                                        });
    return nil;
  }

  NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
  NSNumber *expiresAt = authorization[@"expiresAt"];
  NSNumber *authorizedChangeCount = authorization[@"changeCount"];
  NSNumber *allowCount = authorization[@"allowCount"];
  NSNumber *maxAllowCount = authorization[@"maxAllowCount"];
  NSString *requestId = authorization[@"id"];
  NSString *requestingProcess = authorization[@"requestingProcess"];
  NSString *requestingBundleId = authorization[@"requestingBundleId"];
  BOOL springBoardOwned =
      PBIsSpringBoardBundle(requestingBundleId, requestingProcess);
  BOOL changeMatches = changeCount < 0 ||
                       authorizedChangeCount.integerValue < 0 ||
                       authorizedChangeCount.integerValue == changeCount;
  if (![expiresAt isKindOfClass:[NSNumber class]] ||
      ![authorizedChangeCount isKindOfClass:[NSNumber class]] ||
      ![allowCount isKindOfClass:[NSNumber class]] ||
      ![maxAllowCount isKindOfClass:[NSNumber class]] ||
      requestId.length == 0 ||
      !springBoardOwned ||
      now > expiresAt.doubleValue ||
      !changeMatches ||
      allowCount.integerValue >= maxAllowCount.integerValue) {
    [[NSFileManager defaultManager]
        removeItemAtPath:PBInputBridgeSpringBoardReadAuthorizationPath()
                   error:nil];
    PBInputBridgeDebugLog(@"deny SB read auth policy=%@ requestedChange=%ld authChange=%ld expired=%d owner=%d count=%ld/%ld",
                          policyName ?: @"",
                          (long)changeCount,
                          (long)[authorizedChangeCount integerValue],
                          expiresAt ? now > expiresAt.doubleValue : YES,
                          springBoardOwned,
                          (long)[allowCount integerValue],
                          (long)[maxAllowCount integerValue]);
    PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"sb-read-auth-deny"
                                        details:@{
                                          @"policyName" : policyName ?: @"",
                                          @"dataPurpose" : @(dataPurpose),
                                          @"requestedChangeCount" :
                                              @(changeCount),
                                          @"authorizedChangeCount" :
                                              authorizedChangeCount ?: @(-1),
                                          @"requestId" : requestId ?: @"",
                                          @"expired" :
                                              @(expiresAt ? now > expiresAt.doubleValue : YES),
                                          @"springBoardOwned" :
                                              @(springBoardOwned),
                                          @"changeMatches" : @(changeMatches),
                                          @"allowCount" : allowCount ?: @(-1),
                                          @"maxAllowCount" :
                                              maxAllowCount ?: @(-1),
                                          @"requestingProcess" :
                                              requestingProcess ?: @"",
                                          @"requestingBundleId" :
                                              requestingBundleId ?: @""
                                        });
    return nil;
  }

  authorization[@"allowCount"] = @(allowCount.integerValue + 1);
  authorization[@"lastPolicyName"] = policyName ?: @"";
  authorization[@"lastDataPurpose"] = @(dataPurpose);
  authorization[@"lastAllowedAt"] = @(now);
  PBIOSCopyWritePropertyListToFile(
      authorization, PBInputBridgeSpringBoardReadAuthorizationPath(), YES);
  PBInputBridgeDebugLog(@"consume SB read auth policy=%@ reason=%@ changeCount=%ld count=%ld/%ld id=%@",
                        policyName ?: @"",
                        authorization[@"reason"] ?: @"",
                        (long)changeCount,
                        (long)(allowCount.integerValue + 1),
                        (long)maxAllowCount.integerValue,
                        requestId ?: @"");
  PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"sb-read-auth-consume"
                                      details:@{
                                        @"policyName" : policyName ?: @"",
                                        @"dataPurpose" : @(dataPurpose),
                                        @"reason" : authorization[@"reason"] ?: @"",
                                        @"changeCount" : @(changeCount),
                                        @"authorizedChangeCount" :
                                            authorizedChangeCount ?: @(-1),
                                        @"allowCount" :
                                            @(allowCount.integerValue + 1),
                                        @"maxAllowCount" : maxAllowCount ?: @0,
                                        @"requestId" : requestId ?: @""
                                      });
  return requestId;
}

+ (void)endSpringBoardPasteboardReadAuthorizationWithRequestId:(NSString *)requestId {
  NSDictionary *authorization =
      [NSDictionary dictionaryWithContentsOfFile:
                        PBInputBridgeSpringBoardReadAuthorizationPath()];
  NSString *activeRequestId = authorization[@"id"];
  if (requestId.length == 0 ||
      activeRequestId.length == 0 ||
      [activeRequestId isEqualToString:requestId]) {
    [[NSFileManager defaultManager]
        removeItemAtPath:PBInputBridgeSpringBoardReadAuthorizationPath()
                   error:nil];
    PBInputBridgeDebugLog(@"end SB read auth id=%@", requestId ?: @"");
    PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"sb-read-auth-end"
                                        details:@{
                                          @"requestId" : requestId ?: @"",
                                          @"activeRequestId" :
                                              activeRequestId ?: @""
                                        });
  }
}

@end
