#import "PBInputBridgePrivate.h"

static NSString *PBInputBridgeUniversalInboxFingerprint(NSString *content,
                                                        NSData *imageData) {
  if (content.length > 0) {
    return [NSString stringWithFormat:@"text:%lu:%lu",
                                      (unsigned long)content.length,
                                      (unsigned long)content.hash];
  }
  if (imageData.length > 0) {
    return [NSString stringWithFormat:@"image:%lu:%lu",
                                      (unsigned long)imageData.length,
                                      (unsigned long)imageData.hash];
  }
  return nil;
}

@implementation PBInputBridge (UniversalInbox)

+ (BOOL)recordUniversalClipboardInboxItemWithContent:(NSString *)content
                                           imageData:(NSData *)imageData
                                              source:(NSString *)source {
  if (!PBInputBridgeMainFeatureEnabled()) {
    return NO;
  }

  BOOL hasText = content.length > 0;
  BOOL hasImage =
      [imageData isKindOfClass:[NSData class]] && imageData.length > 0;
  if (!hasText && !hasImage) {
    return NO;
  }

  if (hasImage && imageData.length > kPBUniversalInboxMaxImageBytes) {
    PBInputBridgeDebugLog(
        @"skip universal inbox image too large bytes=%lu source=%@",
        (unsigned long)imageData.length, source ?: @"");
    return NO;
  }

  NSString *fingerprint =
      PBInputBridgeUniversalInboxFingerprint(content, imageData);
  NSDictionary *recent = [NSDictionary
      dictionaryWithContentsOfFile:PBInputBridgeUniversalInboxDedupPath()];
  NSNumber *recentTimestamp = recent[@"timestamp"];
  NSString *recentFingerprint = recent[@"fingerprint"];
  NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
  if ([recentFingerprint isEqualToString:fingerprint] &&
      [recentTimestamp isKindOfClass:[NSNumber class]] &&
      now - recentTimestamp.doubleValue >= 0 &&
      now - recentTimestamp.doubleValue <= kPBUniversalInboxDedupAge) {
    PBInputBridgeDebugLog(
        @"skip universal inbox duplicate source=%@ fingerprint=%@",
        source ?: @"", fingerprint ?: @"");
    return NO;
  }

  NSFileManager *fileManager = [NSFileManager defaultManager];
  NSString *inboxDir = PBInputBridgeUniversalInboxDirectoryPath();
  NSError *directoryError = nil;
  if (![fileManager createDirectoryAtPath:inboxDir
              withIntermediateDirectories:YES
                               attributes:nil
                                    error:&directoryError]) {
    PBInputBridgeDebugLog(@"universal inbox mkdir failed path=%@ error=%@",
                          inboxDir, directoryError);
    return NO;
  }

  long long timestampMs = (long long)(now * 1000);
  NSString *identifier = [NSString
      stringWithFormat:@"%lld_%@", timestampMs, [NSUUID UUID].UUIDString];
  NSString *plistPath =
      [inboxDir stringByAppendingPathComponent:
                    [identifier stringByAppendingPathExtension:@"plist"]];

  NSMutableDictionary *metadata = [@{
    @"id" : identifier,
    @"bundleId" : @"com.apple.continuityclipboard",
    @"appName" : @"Universal Clipboard",
    @"processName" : [[NSProcessInfo processInfo] processName] ?: @"pasted",
    @"timestamp" : @(now),
    @"source" : source ?: @""
  } mutableCopy];

  if (hasText) {
    metadata[@"contentKind"] = @"text";
    metadata[@"content"] = content;
  } else {
    NSString *imagePath =
        [inboxDir stringByAppendingPathComponent:
                      [identifier stringByAppendingPathExtension:@"bin"]];
    if (![imageData writeToFile:imagePath atomically:YES]) {
      PBInputBridgeDebugLog(
          @"universal inbox image write failed path=%@ bytes=%lu source=%@",
          imagePath, (unsigned long)imageData.length, source ?: @"");
      return NO;
    }
    metadata[@"contentKind"] = @"image";
    metadata[@"imagePath"] = imagePath;
    metadata[@"imageBytes"] = @(imageData.length);
  }

  BOOL wrote = [metadata writeToFile:plistPath atomically:YES];
  if (!wrote) {
    NSString *imagePath = metadata[@"imagePath"];
    if (imagePath.length > 0) {
      [fileManager removeItemAtPath:imagePath error:nil];
    }
    PBInputBridgeDebugLog(
        @"universal inbox plist write failed path=%@ source=%@", plistPath,
        source ?: @"");
    return NO;
  }

  NSDictionary *dedup =
      @{@"fingerprint" : fingerprint ?: @"", @"timestamp" : @(now)};
  PBIOSCopyWritePropertyListToFile(
      dedup, PBInputBridgeUniversalInboxDedupPath(), YES);

  PBInputBridgeDebugLog(@"universal inbox wrote id=%@ kind=%@ textLength=%lu "
                        @"imageBytes=%lu source=%@",
                        identifier, metadata[@"contentKind"] ?: @"",
                        (unsigned long)content.length,
                        (unsigned long)imageData.length, source ?: @"");

  CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      (__bridge CFStringRef)PBInputBridgeUniversalInboxNotification, NULL, NULL,
      YES);
  return YES;
}

+ (NSArray<NSDictionary *> *)pendingUniversalClipboardInboxItems {
  NSString *inboxDir = PBInputBridgeUniversalInboxDirectoryPath();
  NSArray<NSString *> *filenames =
      [[NSFileManager defaultManager] contentsOfDirectoryAtPath:inboxDir
                                                          error:nil];
  if (![filenames isKindOfClass:[NSArray class]] || filenames.count == 0) {
    return @[];
  }

  NSArray<NSString *> *sortedFilenames =
      [filenames sortedArrayUsingSelector:@selector(compare:)];
  NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
  for (NSString *filename in sortedFilenames) {
    if (![[filename pathExtension] isEqualToString:@"plist"]) {
      continue;
    }

    NSString *plistPath = [inboxDir stringByAppendingPathComponent:filename];
    NSDictionary *metadata =
        [NSDictionary dictionaryWithContentsOfFile:plistPath];
    if (![metadata isKindOfClass:[NSDictionary class]]) {
      continue;
    }

    NSMutableDictionary *item = [metadata mutableCopy];
    item[@"plistPath"] = plistPath;

    [items addObject:item];
  }

  return [items copy];
}

+ (void)deleteUniversalClipboardInboxItem:(NSDictionary *)itemInfo {
  NSString *plistPath = itemInfo[@"plistPath"];
  NSString *imagePath = itemInfo[@"imagePath"];
  NSFileManager *fileManager = [NSFileManager defaultManager];
  if (plistPath.length > 0) {
    [fileManager removeItemAtPath:plistPath error:nil];
  }
  if (imagePath.length > 0) {
    [fileManager removeItemAtPath:imagePath error:nil];
  }
}

@end
