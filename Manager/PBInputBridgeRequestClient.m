#import "PBInputBridgePrivate.h"
#import <UIKit/UIKit.h>

@interface PBInputBridge (RequestClientPrivate)
+ (void)sendPasteRequestWithText:(NSString *)text
                       imageData:(NSData *)imageData
                      targetInfo:(NSDictionary *)targetInfo;
@end

static void PBApplyTargetInfoToRequest(NSMutableDictionary *request,
                                       NSDictionary *targetInfo) {
  if (![request isKindOfClass:[NSMutableDictionary class]] ||
      ![targetInfo isKindOfClass:[NSDictionary class]]) {
    return;
  }

  NSString *targetBundleId = targetInfo[@"targetBundleId"];
  if (![targetBundleId isKindOfClass:[NSString class]] ||
      targetBundleId.length == 0) {
    return;
  }

  request[@"targetBundleId"] = targetBundleId;

  NSString *targetAppName = targetInfo[@"targetAppName"];
  if ([targetAppName isKindOfClass:[NSString class]] &&
      targetAppName.length > 0) {
    request[@"targetAppName"] = targetAppName;
  }
}

@implementation PBInputBridge (RequestClient)

+ (void)sendInsertRequestWithText:(NSString *)text
                       targetInfo:(NSDictionary *)targetInfo {
  if (!PBInputBridgeMainFeatureEnabled()) {
    return;
  }

  if (text.length == 0) {
    return;
  }

  NSString *targetBundleId = targetInfo[@"targetBundleId"];
  if (![targetBundleId isKindOfClass:[NSString class]] ||
      targetBundleId.length == 0) {
    PBInputBridgeDebugLog(@"drop insert request without target length=%lu",
                          (unsigned long)text.length);
    return;
  }

  PBClearTextInsertDiagnostic();
  NSString *requestId = [NSUUID UUID].UUIDString;
  NSMutableDictionary *request = [@{
    @"id" : requestId,
    @"type" : @"insertText",
    @"text" : text,
    @"timestamp" : @([[NSDate date] timeIntervalSince1970])
  } mutableCopy];
  PBApplyTargetInfoToRequest(request, targetInfo);
  PBInputBridgeDebugLog(@"send insert request id=%@ textLength=%lu target=%@",
                        requestId, (unsigned long)text.length,
                        request[@"targetBundleId"] ?: @"");

  NSString *requestPath = PBInputBridgeRequestPath();
  __unused BOOL wroteRequest =
      PBIOSCopyWritePropertyListToFile(request, requestPath, YES);
  PBRecordTextInsertDiagnosticPhase(@"send-request", requestId, @{
    @"textLength" : @(text.length),
    @"targetBundleId" : request[@"targetBundleId"] ?: @"",
    @"targetAppName" : request[@"targetAppName"] ?: @"",
    @"requestPath" : requestPath ?: @"",
    @"wroteRequest" : @(wroteRequest)
  });

  PBInputBridgePostInsertNotification();

  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        NSString *currentRequestPath = PBInputBridgeRequestPath();
        NSDictionary *currentRequest =
            [NSDictionary dictionaryWithContentsOfFile:currentRequestPath];
        if ([currentRequest[@"id"] isEqualToString:requestId]) {
          [[NSFileManager defaultManager] removeItemAtPath:currentRequestPath
                                                     error:nil];
        }
      });
}

+ (void)sendPasteRequestWithText:(NSString *)text
                      targetInfo:(NSDictionary *)targetInfo {
  [self sendPasteRequestWithText:text imageData:nil targetInfo:targetInfo];
}

+ (void)sendPasteRequestWithImageData:(NSData *)imageData
                           targetInfo:(NSDictionary *)targetInfo {
  [self sendPasteRequestWithText:nil imageData:imageData targetInfo:targetInfo];
}

+ (void)sendPasteRequestWithText:(NSString *)text
                       imageData:(NSData *)imageData
                      targetInfo:(NSDictionary *)targetInfo {
  if (!PBInputBridgeMainFeatureEnabled()) {
    return;
  }

  BOOL hasText = [text isKindOfClass:[NSString class]] && text.length > 0;
  BOOL hasImage =
      [imageData isKindOfClass:[NSData class]] && imageData.length > 0;
  if (hasText == hasImage) {
    return;
  }

  NSString *targetBundleId = targetInfo[@"targetBundleId"];
  if (![targetBundleId isKindOfClass:[NSString class]] ||
      targetBundleId.length == 0) {
    PBInputBridgeDebugLog(
        @"drop paste request without target textLength=%lu imageBytes=%lu",
        (unsigned long)text.length, (unsigned long)imageData.length);
    return;
  }

  NSString *requestId = [NSUUID UUID].UUIDString;
  NSMutableDictionary *request = [@{
    @"id" : requestId,
    @"type" : @"paste",
    @"timestamp" : @([[NSDate date] timeIntervalSince1970])
  } mutableCopy];
  if (hasText) {
    request[@"text"] = text;
  }
  if (hasImage) {
    request[@"imageData"] = imageData;
  }
  PBApplyTargetInfoToRequest(request, targetInfo);
  if (hasImage) {
    [self beginOutgoingPasteboardSuppressionForRequestId:requestId
                                             contentKind:@"image"
                                              targetInfo:targetInfo];
  }
  PBInputBridgeDebugLog(
      @"send paste request id=%@ textLength=%lu imageBytes=%lu target=%@",
      requestId, (unsigned long)text.length, (unsigned long)imageData.length,
      request[@"targetBundleId"] ?: @"");

  NSString *requestPath = PBInputBridgeRequestPath();
  __unused BOOL wroteRequest =
      PBIOSCopyWritePropertyListToFile(request, requestPath, YES);
  if (hasImage) {
    PB_RECORD_IMAGE_PASTE_DIAGNOSTIC(@"send-request"
                              requestId:requestId
                                details:@{
                                  @"imageBytes" : @(imageData.length),
                                  @"imageType" :
                                      PBImagePasteboardTypeForData(imageData),
                                  @"pasteboardTypes" :
                                      PBImagePasteboardTypesForData(imageData),
                                  @"targetBundleId" : request[@"targetBundleId"]
                                      ?: @"",
                                  @"targetAppName" : request[@"targetAppName"]
                                      ?: @"",
                                  @"requestPath" : requestPath ?: @"",
                                  @"wroteRequest" : @(wroteRequest)
                                });
  }

  PBInputBridgePostInsertNotification();

  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        NSString *currentRequestPath = PBInputBridgeRequestPath();
        NSDictionary *currentRequest =
            [NSDictionary dictionaryWithContentsOfFile:currentRequestPath];
        if ([currentRequest[@"id"] isEqualToString:requestId]) {
          [[NSFileManager defaultManager] removeItemAtPath:currentRequestPath
                                                     error:nil];
        }
      });
}

@end
