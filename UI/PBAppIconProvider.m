#import "PBAppIconProvider.h"
#import <objc/message.h>

static NSString * const kPBUniversalClipboardBundleId = @"com.apple.continuityclipboard";
static NSString * const kPBSpringBoardBundleId = @"com.apple.springboard";

@interface PBAppIconProvider ()
@property (nonatomic, strong) NSCache<NSString *, UIImage *> *iconCache;
@property (nonatomic, strong) NSMutableSet<NSString *> *failedIconKeys;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<void (^)(UIImage *)> *> *pendingCompletions;
@property (nonatomic, strong) dispatch_queue_t iconQueue;
@end

@implementation PBAppIconProvider

+ (instancetype)sharedProvider {
    static PBAppIconProvider *provider = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        provider = [[PBAppIconProvider alloc] init];
    });
    return provider;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _iconCache = [[NSCache alloc] init];
        _iconCache.name = @"com.ssdsl.ioscopy.app-icons";
        _iconCache.countLimit = 160;
        _failedIconKeys = [NSMutableSet set];
        _pendingCompletions = [NSMutableDictionary dictionary];
        _iconQueue = dispatch_queue_create("com.ssdsl.ioscopy.app-icons", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (UIImage *)iconForItem:(PBClipboardItem *)item preferredSize:(CGFloat)preferredSize {
    return [self iconForBundleId:item.sourceBundleId
                         appName:item.sourceAppName
                     contentType:item.contentType
                    preferredSize:preferredSize];
}

- (void)loadIconForItem:(PBClipboardItem *)item
          preferredSize:(CGFloat)preferredSize
             completion:(void (^)(UIImage *icon))completion {
    [self loadIconForBundleId:item.sourceBundleId
                      appName:item.sourceAppName
                  contentType:item.contentType
                 preferredSize:preferredSize
                   completion:completion];
}

- (UIImage *)iconForBundleId:(NSString *)bundleId
                     appName:(NSString *)appName
                 contentType:(PBContentType)contentType
                preferredSize:(CGFloat)preferredSize {
    NSString *normalizedBundleId = [bundleId isKindOfClass:[NSString class]] ? bundleId : @"";
    CGFloat scale = [UIScreen mainScreen].scale;
    NSString *cacheKey = [self cacheKeyForBundleId:normalizedBundleId
                                      preferredSize:preferredSize
                                             scale:scale];

    UIImage *cachedIcon = [self.iconCache objectForKey:cacheKey];
    if (cachedIcon) {
        return cachedIcon;
    }

    return [self fallbackIconForBundleId:normalizedBundleId
                                 appName:appName
                             contentType:contentType
                            preferredSize:preferredSize];
}

- (void)loadIconForBundleId:(NSString *)bundleId
                    appName:(NSString *)appName
                contentType:(PBContentType)contentType
               preferredSize:(CGFloat)preferredSize
                 completion:(void (^)(UIImage *icon))completion {
    if (!completion) {
        return;
    }

    NSString *normalizedBundleId = [bundleId isKindOfClass:[NSString class]] ? bundleId : @"";
    CGFloat scale = [UIScreen mainScreen].scale;
    NSString *cacheKey = [self cacheKeyForBundleId:normalizedBundleId
                                      preferredSize:preferredSize
                                             scale:scale];

    UIImage *cachedIcon = [self.iconCache objectForKey:cacheKey];
    if (cachedIcon) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(cachedIcon);
        });
        return;
    }

    UIImage *fallbackIcon = [self fallbackIconForBundleId:normalizedBundleId
                                                  appName:appName
                                              contentType:contentType
                                             preferredSize:preferredSize];
    if (![self shouldLoadPrivateIconForBundleId:normalizedBundleId]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(fallbackIcon);
        });
        return;
    }

    @synchronized (self) {
        if ([self.failedIconKeys containsObject:cacheKey]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(fallbackIcon);
            });
            return;
        }

        NSMutableArray<void (^)(UIImage *)> *pending = self.pendingCompletions[cacheKey];
        if (pending) {
            [pending addObject:[completion copy]];
            return;
        }

        self.pendingCompletions[cacheKey] = [NSMutableArray arrayWithObject:[completion copy]];
    }

    dispatch_async(self.iconQueue, ^{
        UIImage *resolvedIcon = [self privateIconForBundleId:normalizedBundleId scale:scale];
        UIImage *finalIcon = resolvedIcon ?: fallbackIcon;

        @synchronized (self) {
            if (resolvedIcon) {
                [self.iconCache setObject:resolvedIcon forKey:cacheKey];
            } else {
                [self.failedIconKeys addObject:cacheKey];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            NSArray<void (^)(UIImage *)> *completions = nil;
            @synchronized (self) {
                completions = [self.pendingCompletions[cacheKey] copy];
                [self.pendingCompletions removeObjectForKey:cacheKey];
            }

            for (void (^pendingCompletion)(UIImage *) in completions) {
                pendingCompletion(finalIcon);
            }
        });
    });
}

- (NSString *)cacheKeyForBundleId:(NSString *)bundleId
                    preferredSize:(CGFloat)preferredSize
                            scale:(CGFloat)scale {
    return [NSString stringWithFormat:@"%@|%.0f|%.1f",
                                      bundleId ?: @"",
                                      preferredSize,
                                      scale];
}

- (BOOL)shouldLoadPrivateIconForBundleId:(NSString *)bundleId {
    return bundleId.length > 0 &&
           ![bundleId isEqualToString:kPBUniversalClipboardBundleId] &&
           ![bundleId isEqualToString:kPBSpringBoardBundleId];
}

- (UIImage *)privateIconForBundleId:(NSString *)bundleId scale:(CGFloat)scale {
    UIImage *icon = [self iconUsingUIKitForBundleId:bundleId scale:scale];
    if (icon) {
        return [icon imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    }

    icon = [self iconUsingLaunchServicesForBundleId:bundleId scale:scale];
    if (icon) {
        return [icon imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    }

    return nil;
}

- (UIImage *)iconUsingUIKitForBundleId:(NSString *)bundleId scale:(CGFloat)scale {
    SEL selector = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if (![UIImage respondsToSelector:selector]) {
        return nil;
    }

    typedef UIImage *(*PBIconMessageSend)(id, SEL, NSString *, NSInteger, CGFloat);
    PBIconMessageSend sendIconMessage = (PBIconMessageSend)objc_msgSend;
    NSArray<NSNumber *> *formats = @[ @2, @1, @0, @3 ];

    for (NSNumber *formatNumber in formats) {
        UIImage *icon = sendIconMessage([UIImage class],
                                        selector,
                                        bundleId,
                                        formatNumber.integerValue,
                                        scale);
        if ([icon isKindOfClass:[UIImage class]]) {
            return icon;
        }
    }

    return nil;
}

- (UIImage *)iconUsingLaunchServicesForBundleId:(NSString *)bundleId scale:(CGFloat)scale {
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL proxySelector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (!proxyClass || ![proxyClass respondsToSelector:proxySelector]) {
        return nil;
    }

    typedef id (*PBProxyMessageSend)(id, SEL, NSString *);
    id proxy = ((PBProxyMessageSend)objc_msgSend)(proxyClass, proxySelector, bundleId);
    if (!proxy) {
        return nil;
    }

    SEL iconDataSelector = NSSelectorFromString(@"iconDataForVariant:");
    if (![proxy respondsToSelector:iconDataSelector]) {
        return nil;
    }

    typedef id (*PBIconDataMessageSend)(id, SEL, NSInteger);
    PBIconDataMessageSend sendIconDataMessage = (PBIconDataMessageSend)objc_msgSend;
    NSArray<NSNumber *> *variants = @[ @2, @1, @0, @3 ];

    for (NSNumber *variantNumber in variants) {
        id iconData = sendIconDataMessage(proxy,
                                          iconDataSelector,
                                          variantNumber.integerValue);
        if ([iconData isKindOfClass:[NSData class]]) {
            UIImage *icon = [UIImage imageWithData:iconData scale:scale];
            if (icon) {
                return icon;
            }
        }
    }

    return nil;
}

- (UIImage *)fallbackIconForBundleId:(NSString *)bundleId
                              appName:(NSString *)appName
                          contentType:(PBContentType)contentType
                         preferredSize:(CGFloat)preferredSize {
    NSString *symbolName = [self fallbackSymbolNameForBundleId:bundleId
                                                       appName:appName
                                                   contentType:contentType];
    CGFloat pointSize = MAX(14.0, MIN(preferredSize * 0.58, 22.0));
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:pointSize
                                                        weight:UIImageSymbolWeightSemibold];

    UIImage *icon = [UIImage systemImageNamed:symbolName withConfiguration:configuration];
    if (!icon) {
        icon = [UIImage systemImageNamed:@"doc.text" withConfiguration:configuration];
    }
    return [icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

- (NSString *)fallbackSymbolNameForBundleId:(NSString *)bundleId
                                    appName:(NSString *)appName
                                contentType:(PBContentType)contentType {
    NSString *lowerAppName = [appName isKindOfClass:[NSString class]] ? appName.lowercaseString : @"";
    if ([lowerAppName containsString:@"snapper"]) {
        return @"camera";
    }

    if ([bundleId isEqualToString:kPBUniversalClipboardBundleId]) {
        return @"macbook.and.iphone";
    }

    if ([bundleId isEqualToString:kPBSpringBoardBundleId] || bundleId.length == 0) {
        return @"square.grid.2x2";
    }

    switch (contentType) {
        case PBContentTypeURL:
            return @"link";
        case PBContentTypeImage:
            return @"photo";
        case PBContentTypeText:
            return @"doc.text";
        default:
            return @"app";
    }
}

@end
