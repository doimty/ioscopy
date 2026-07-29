#import "PBInputBridgePrivate.h"
#import <objc/message.h>

@implementation PBInputBridge (PasteState)

+ (void)recordInternalPasteboardWriteWithPasteboard:(id)pasteboard
                                    imageDataLength:
                                        (NSUInteger)imageDataLength {
  NSInteger changeCount = -1;
  @try {
    if ([pasteboard respondsToSelector:@selector(changeCount)]) {
      changeCount = ((NSInteger (*)(id, SEL))objc_msgSend)(pasteboard, @selector
                                                           (changeCount));
    }
  } @catch (__unused NSException *exception) {
    changeCount = -1;
  }

  NSDictionary *info = @{
    @"bundleId" : [[NSBundle mainBundle] bundleIdentifier] ?: @"",
    @"processName" : [[NSProcessInfo processInfo] processName] ?: @"",
    @"changeCount" : @(changeCount),
    @"imageBytes" : @(imageDataLength),
    @"timestamp" : @([[NSDate date] timeIntervalSince1970])
  };

  // libSandy 精确授权的是目标 plist，atomic 写入会额外创建临时文件。
  __unused BOOL wrote =
      PBIOSCopyWritePropertyListToFile(info, PBInputBridgeInternalPastePath(),
                                       NO);
  PBInputBridgeDebugLog(@"record internal paste wrote=%d bundle=%@ "
                        @"changeCount=%ld imageBytes=%lu path=%@",
                        wrote, info[@"bundleId"] ?: @"", (long)changeCount,
                        (unsigned long)imageDataLength,
                        PBInputBridgeInternalPastePath());
}

+ (NSDictionary *)recentInternalPasteboardWriteInfoForChangeCount:
    (NSInteger)changeCount {
  NSDictionary *info =
      [NSDictionary dictionaryWithContentsOfFile:PBInputBridgeInternalPastePath()];
  if (![info isKindOfClass:[NSDictionary class]]) {
    return nil;
  }

  NSNumber *timestamp = info[@"timestamp"];
  NSNumber *sourceChangeCount = info[@"changeCount"];
  if (![timestamp isKindOfClass:[NSNumber class]] ||
      ![sourceChangeCount isKindOfClass:[NSNumber class]]) {
    [[NSFileManager defaultManager]
        removeItemAtPath:PBInputBridgeInternalPastePath()
                   error:nil];
    return nil;
  }

  NSTimeInterval age =
      [[NSDate date] timeIntervalSince1970] - timestamp.doubleValue;
  if (age < 0 || age > kPBInternalPasteInfoMaxAge) {
    [[NSFileManager defaultManager]
        removeItemAtPath:PBInputBridgeInternalPastePath()
                   error:nil];
    return nil;
  }

  if (changeCount <= 0 || sourceChangeCount.integerValue != changeCount) {
    return nil;
  }

  PBInputBridgeDebugLog(@"internal paste hit: bundle=%@ sourceChange=%ld "
                        @"requestedChange=%ld age=%.3f",
                        info[@"bundleId"] ?: @"",
                        (long)sourceChangeCount.integerValue,
                        (long)changeCount, age);
  return info;
}

+ (void)clearInternalPasteboardWriteInfo {
  [[NSFileManager defaultManager]
      removeItemAtPath:PBInputBridgeInternalPastePath()
                 error:nil];
}

@end
