#import "PBClipboardManager.h"
#import "PBStorageManager.h"
#import "PBInputBridgePrivate.h"
#import "../Shared/PBPathUtilities.h"
#import "../Shared/PBPreferenceKeys.h"
#import <UIKit/UIKit.h>
#import <rootless.h>
#import <objc/message.h>

NSString * const PBClipboardManagerDidUpdateNotification = @"PBClipboardManagerDidUpdateNotification";
BOOL PBIsInternalPasteboardRead = NO;

#define kPrefsPath PBIOSCopyMainPreferencesPath()
static NSString * const kPBClearAllDataNotification = @"com.ssdsl.ioscopy/clearAllData";

static NSString * const kPBUniversalClipboardBundleId = @"com.apple.continuityclipboard";
static NSString * const kPBUniversalClipboardAppName = @"Universal Clipboard";
static NSString * const kPBBuildImageTextIndexNotification = @"com.ssdsl.ioscopy/buildImageTextIndex";
static NSString * const kPBOCRIndexUpdatedNotification = @"com.ssdsl.ioscopy/ocrindexupdated";
static NSString * const kPBOCRWorkerRequestNotification = @"com.ssdsl.ioscopy/ocrworkerrequest";
static NSInteger const kPBAutomaticOCRBackfillLimit = 3;
static NSInteger const kPBManualOCRBackfillLimit = 20;
static NSInteger const kPBMaxPasteboardReadAttempts = 6;
static NSInteger const kPBSnapperFallbackAttempt = 2;
static NSTimeInterval const kPBSnapperAppRouteSettleDelay = 0.25;
static NSString * const kPBInternalPasteboardReadThreadKey = @"com.ssdsl.ioscopy.internalPasteboardRead";
static NSTimeInterval const kPBRecentCaptureFingerprintMaxAge = 8.0;

static void PBSetInternalPasteboardRead(BOOL allowed) {
    PBIsInternalPasteboardRead = allowed;
    NSMutableDictionary *threadDictionary = [NSThread currentThread].threadDictionary;
    if (allowed) {
        threadDictionary[kPBInternalPasteboardReadThreadKey] = @YES;
    } else {
        [threadDictionary removeObjectForKey:kPBInternalPasteboardReadThreadKey];
    }
}

static NSString *PBOCRWorkerRequestPath(void) {
    return ROOT_PATH_NS(@"/var/mobile/Library/iOSCopy/ocr-request.plist");
}

#if DEBUG_LOG
#define PBClipboardDebugLog(...) \
    PBDiagnosticLog(PBDiagnosticStreamPasteAuth, @"Clipboard", __VA_ARGS__)
#else
#define PBClipboardDebugLog(...) do { } while (0)
#endif

@interface PBClipboardManager ()
@property (nonatomic, strong) NSMutableArray<PBClipboardItem *> *items;
@property (nonatomic, strong) dispatch_queue_t clipboardQueue;
@property (nonatomic, strong) dispatch_queue_t pasteboardQueue;
@property (nonatomic, strong) dispatch_queue_t ocrWorkerQueue;
@property (nonatomic, strong) NSTimer *debounceTimer;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, assign) NSInteger lastChangeCount;
@property (nonatomic, assign) NSInteger pendingChangeCount;
@property (nonatomic, assign) NSInteger lastLocalPasteboardChangeCount;
@property (nonatomic, assign) NSInteger lastLocalSourceChangeCount;
@property (nonatomic, assign) NSInteger suppressedChangeCount;
@property (nonatomic, assign) BOOL suppressNextPasteboardChange;
@property (nonatomic, assign) BOOL recordImages;
@property (nonatomic, assign) BOOL imageTextSearchEnabled;
@property (nonatomic, assign) BOOL recordURLs;
@property (nonatomic, assign) BOOL autoClose;
@property (nonatomic, assign) BOOL hapticFeedback;
@property (nonatomic, assign) NSInteger cleanupDays;
@property (nonatomic, strong) NSArray<NSString *> *excludedApps;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *recentCaptureFingerprints;

- (void)processUniversalClipboardInbox;
- (void)processUnifiedPullCaptureWithExpectedCount:(NSInteger)expectedCount
                                           attempt:(NSInteger)attempt;
- (void)runMaintenanceCleanup;
- (BOOL)saveClipboardTextContentSynchronously:(NSString *)content
                                   sourceInfo:(NSDictionary *)sourceInfo;
- (BOOL)saveClipboardImageSynchronously:(UIImage *)image
                              imageData:(NSData *)originalImageData
                             sourceInfo:(NSDictionary *)sourceInfo;
- (void)saveClipboardImage:(UIImage *)image
                 imageData:(NSData *)originalImageData
                sourceInfo:(NSDictionary *)sourceInfo;
- (BOOL)shouldSkipRecentCaptureWithContent:(NSString *)content
                                  imageData:(NSData *)imageData
                                 sourceInfo:(NSDictionary *)sourceInfo
                                changeCount:(NSInteger)changeCount;
- (void)recordRecentCaptureWithContent:(NSString *)content
                              imageData:(NSData *)imageData
                             sourceInfo:(NSDictionary *)sourceInfo
                            changeCount:(NSInteger)changeCount;
- (void)runImageOCRWorkerWithLimit:(NSInteger)limit retryFailed:(BOOL)retryFailed;
@end

static NSString *PBImageFileExtensionForData(NSData *data) {
    NSString *type = PBImagePasteboardTypeForData(data);
    if ([type isEqualToString:@"public.jpeg"]) {
        return @"jpg";
    }
    if ([type isEqualToString:@"public.png"]) {
        return @"png";
    }
    if ([type isEqualToString:@"com.compuserve.gif"]) {
        return @"gif";
    }
    if ([type isEqualToString:@"public.tiff"]) {
        return @"tiff";
    }
    if ([type isEqualToString:@"public.heic"]) {
        return @"heic";
    }
    return @"bin";
}

static NSString *PBShortHashForData(NSData *data) {
    if (![data isKindOfClass:[NSData class]] || data.length == 0) {
        return @"";
    }

    const unsigned char *bytes = data.bytes;
    unsigned long long hash = 1469598103934665603ULL;
    NSUInteger length = data.length;
    NSUInteger headCount = MIN(length, (NSUInteger)4096);
    for (NSUInteger index = 0; index < headCount; index++) {
        hash ^= bytes[index];
        hash *= 1099511628211ULL;
    }
    if (length > headCount) {
        NSUInteger start = length > 4096 ? length - 4096 : headCount;
        for (NSUInteger index = start; index < length; index++) {
            hash ^= bytes[index];
            hash *= 1099511628211ULL;
        }
    }
    return [NSString stringWithFormat:@"%llu:%016llx",
                                      (unsigned long long)length,
                                      hash];
}

static NSString *PBFingerprintForClipboardPayload(NSString *content,
                                                  NSData *imageData,
                                                  NSDictionary *sourceInfo,
                                                  NSInteger changeCount) {
    if (content.length > 0) {
        return [NSString stringWithFormat:@"text:%lu:%lu",
                                          (unsigned long)content.length,
                                          (unsigned long)content.hash];
    }
    if (imageData.length > 0) {
        return [NSString stringWithFormat:@"image:%@",
                                          PBShortHashForData(imageData)];
    }
    return @"";
}

static BOOL PBPasteboardTypeLooksImage(NSString *type) {
    NSString *lower = [type lowercaseString];
    return [lower containsString:@"image"] ||
           [lower containsString:@"png"] ||
           [lower containsString:@"jpeg"] ||
           [lower containsString:@"jpg"] ||
           [lower containsString:@"heic"] ||
           [lower containsString:@"heif"] ||
           [lower containsString:@"tiff"] ||
           [lower containsString:@"gif"];
}

static BOOL PBPasteboardTypeLooksHTML(NSString *type) {
    NSString *lower = [type lowercaseString];
    return [lower containsString:@"html"];
}

static BOOL PBPasteboardTypeLooksPlainText(NSString *type) {
    NSString *lower = [type lowercaseString];
    return [lower isEqualToString:@"public.utf8-plain-text"] ||
           [lower isEqualToString:@"public.plain-text"] ||
           [lower isEqualToString:@"public.text"] ||
           [lower containsString:@"plain-text"] ||
           [lower containsString:@"utf8-plain-text"] ||
           ([lower containsString:@"text"] && ![lower containsString:@"html"]);
}

static BOOL PBPasteboardTypeLooksText(NSString *type) {
    NSString *lower = [type lowercaseString];
    return !PBPasteboardTypeLooksHTML(type) &&
           (PBPasteboardTypeLooksPlainText(type) ||
            [lower containsString:@"string"] ||
            [lower containsString:@"utf8"] ||
            [lower isEqualToString:@"public.url"] ||
            [lower isEqualToString:@"public.uri"] ||
            [lower containsString:@"url"]);
}

static NSInteger PBPasteboardTypePriorityForPullCapture(NSString *type) {
    if ([type isEqualToString:@"public.png"]) {
        return 0;
    }
    if ([type isEqualToString:@"public.jpeg"]) {
        return 1;
    }
    if (PBPasteboardTypeLooksImage(type)) {
        return 2;
    }
    if ([type isEqualToString:@"public.utf8-plain-text"]) {
        return 3;
    }
    if (PBPasteboardTypeLooksPlainText(type)) {
        return 4;
    }
    if (PBPasteboardTypeLooksText(type)) {
        return 5;
    }
    if (PBPasteboardTypeLooksHTML(type)) {
        return 6;
    }
    return 7;
}

static NSArray<NSString *> *PBSortedPasteboardTypesForPullCapture(NSArray *types) {
    NSMutableArray<NSString *> *typeStrings = [NSMutableArray array];
    for (id type in types) {
        NSString *typeString = [type isKindOfClass:[NSString class]] ? type : [type description];
        if (typeString.length > 0) {
            [typeStrings addObject:typeString];
        }
    }

    return [typeStrings sortedArrayUsingComparator:^NSComparisonResult(NSString *firstType,
                                                                        NSString *secondType) {
        NSInteger firstPriority = PBPasteboardTypePriorityForPullCapture(firstType ?: @"");
        NSInteger secondPriority = PBPasteboardTypePriorityForPullCapture(secondType ?: @"");
        if (firstPriority < secondPriority) {
            return NSOrderedAscending;
        }
        if (firstPriority > secondPriority) {
            return NSOrderedDescending;
        }
        return [firstType compare:secondType ?: @""];
    }];
}

static NSString *PBTextFromData(NSData *data) {
    if (![data isKindOfClass:[NSData class]] || data.length == 0) {
        return nil;
    }

    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text.length == 0) {
        text = [[NSString alloc] initWithData:data encoding:NSUTF16StringEncoding];
    }
    return text.length > 0 ? text : nil;
}

static NSString *PBStringByReplacingRegularExpression(NSString *text,
                                                       NSString *pattern,
                                                       NSString *replacement) {
    if (text.length == 0 || pattern.length == 0) {
        return text;
    }

    NSRegularExpression *expression =
        [NSRegularExpression regularExpressionWithPattern:pattern
                                                  options:0
                                                    error:nil];
    if (!expression) {
        return text;
    }

    NSRange range = NSMakeRange(0, text.length);
    return [expression stringByReplacingMatchesInString:text
                                                options:0
                                                  range:range
                                           withTemplate:replacement ?: @""];
}

static NSString *PBStringByDecodingCommonHTMLEntities(NSString *text) {
    if (text.length == 0) {
        return text;
    }

    NSDictionary<NSString *, NSString *> *entities = @{
        @"&nbsp;": @" ",
        @"&#160;": @" ",
        @"&lt;": @"<",
        @"&gt;": @">",
        @"&amp;": @"&",
        @"&quot;": @"\"",
        @"&#34;": @"\"",
        @"&#39;": @"'",
        @"&apos;": @"'"
    };

    NSMutableString *result = [text mutableCopy];
    for (NSString *entity in entities) {
        [result replaceOccurrencesOfString:entity
                                 withString:entities[entity]
                                    options:NSCaseInsensitiveSearch
                                      range:NSMakeRange(0, result.length)];
    }
    return [result copy];
}

static NSString *PBStringByStrippingHTMLTags(NSString *html) {
    if (html.length == 0) {
        return html;
    }

    NSMutableString *result = [NSMutableString string];
    BOOL insideTag = NO;
    unichar quote = 0;
    for (NSUInteger index = 0; index < html.length; index++) {
        unichar character = [html characterAtIndex:index];
        if (insideTag) {
            if (quote != 0) {
                if (character == quote) {
                    quote = 0;
                }
                continue;
            }
            if (character == '"' || character == '\'') {
                quote = character;
                continue;
            }
            if (character == '>') {
                insideTag = NO;
            }
            continue;
        }

        if (character == '<') {
            insideTag = YES;
            quote = 0;
            continue;
        }

        [result appendFormat:@"%C", character];
    }
    return [result copy];
}

static NSString *PBPlainTextFromHTMLString(NSString *html) {
    if (html.length == 0) {
        return nil;
    }

    NSString *text = html;
    text = PBStringByReplacingRegularExpression(text, @"(?is)<(script|style)[^>]*>.*?</\\1>", @"");
    text = PBStringByReplacingRegularExpression(text, @"(?i)<br\\s*/?>", @"\n");
    text = PBStringByReplacingRegularExpression(text, @"(?i)</(div|p|li|tr|h[1-6])\\s*>", @"\n");
    text = PBStringByStrippingHTMLTags(text);
    text = PBStringByDecodingCommonHTMLEntities(text);
    text = [text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
    text = [text stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return text.length > 0 ? text : nil;
}

static id PBObjectByPerformingSelector(id target, SEL selector) {
    if (!target || !selector || ![target respondsToSelector:selector]) {
        return nil;
    }

    @try {
        id (*sendObject)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        return sendObject(target, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static id PBObjectByPerformingSelectorWithObject(id target, SEL selector, id object) {
    if (!target || !selector || ![target respondsToSelector:selector]) {
        return nil;
    }

    @try {
        id (*sendObject)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
        return sendObject(target, selector, object);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *PBStringFromPasteboardValue(id value, NSString *type) {
    NSString *text = nil;
    if ([value isKindOfClass:[NSString class]]) {
        text = value;
    } else if ([value isKindOfClass:[NSURL class]]) {
        text = [(NSURL *)value absoluteString];
    } else if ([value isKindOfClass:[NSAttributedString class]]) {
        text = [(NSAttributedString *)value string];
    } else if ([value isKindOfClass:[NSData class]]) {
        text = PBTextFromData(value);
    }

    if (PBPasteboardTypeLooksHTML(type)) {
        text = PBPlainTextFromHTMLString(text);
    }
    return text.length > 0 ? text : nil;
}

static NSData *PBImageDataFromPasteboardValue(id value) {
    if ([value isKindOfClass:[NSData class]] && [(NSData *)value length] > 0) {
        return value;
    }
    if ([value isKindOfClass:[UIImage class]]) {
        NSData *imageData = UIImagePNGRepresentation(value);
        if (!imageData) {
            imageData = UIImageJPEGRepresentation(value, 0.95);
        }
        return imageData.length > 0 ? imageData : nil;
    }
    return nil;
}

static id PBValueForPasteboardItemType(id item, NSString *type) {
    if (type.length == 0) {
        return nil;
    }

    SEL valueSelector = @selector(valueForPasteboardType:);
    id value = PBObjectByPerformingSelectorWithObject(item, valueSelector, type);
    if (!value) {
        value = PBObjectByPerformingSelectorWithObject(item, @selector(dataForPasteboardType:), type);
    }
    if (!value && [item isKindOfClass:[NSDictionary class]]) {
        value = [(NSDictionary *)item objectForKey:type];
    }
    return value;
}

static NSDictionary *PBContentCaptureFromPasteboardItem(id item,
                                                        NSArray<NSString *> *types,
                                                        BOOL allowImages) {
    NSArray<NSString *> *sortedTypes = PBSortedPasteboardTypesForPullCapture(types);
    NSData *fallbackImageData = nil;
    NSString *fallbackText = nil;

    for (NSString *type in sortedTypes) {
        id value = PBValueForPasteboardItemType(item, type);
        if (allowImages && PBPasteboardTypeLooksImage(type)) {
            NSData *imageData = PBImageDataFromPasteboardValue(value);
            if (imageData.length > 0) {
                fallbackImageData = imageData;
                if ([type isEqualToString:@"public.png"] ||
                    [type isEqualToString:@"public.jpeg"]) {
                    break;
                }
            }
            continue;
        }

        if (PBPasteboardTypeLooksText(type) || PBPasteboardTypeLooksHTML(type)) {
            NSString *text = PBStringFromPasteboardValue(value, type);
            if (text.length > 0) {
                fallbackText = text;
                break;
            }
        }
    }

    if (fallbackText.length > 0) {
        return @{@"contentKind": @"text", @"content": fallbackText};
    }
    if (fallbackImageData.length > 0) {
        return @{@"contentKind": @"image", @"imageData": fallbackImageData};
    }
    return nil;
}

static void PBTriggerUniversalClipboardDownloadProbe(UIPasteboard *pasteboard,
                                                     BOOL allowImages) {
    if (![pasteboard isKindOfClass:[UIPasteboard class]]) {
        PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"sb-universal-pull-invalid-pasteboard"
                                                    details:@{
                                                        @"pasteboardClass": pasteboard ? NSStringFromClass([pasteboard class]) : @""
                                                    });
        return;
    }

    // 这里只触发系统拉取 Universal Clipboard，读取结果必须丢弃，不能进入入库链。
    __unused BOOL readString = NO;
    __unused BOOL readURL = NO;
    __unused BOOL readImage = NO;
    @try {
        (void)pasteboard.string;
        readString = YES;
    } @catch (__unused NSException *exception) {
    }

    @try {
        (void)pasteboard.URL;
        readURL = YES;
    } @catch (__unused NSException *exception) {
    }

    if (allowImages) {
        @try {
            (void)pasteboard.image;
            readImage = YES;
        } @catch (__unused NSException *exception) {
        }
    }

    NSMutableArray<NSString *> *candidateTypes = [NSMutableArray array];
    id rawTypes = PBObjectByPerformingSelector(pasteboard, @selector(pasteboardTypes));
    if ([rawTypes isKindOfClass:[NSArray class]]) {
        [candidateTypes addObjectsFromArray:rawTypes];
    }
    PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"sb-universal-pull-public-reads"
                                                details:@{
                                                    @"changeCount": @(pasteboard.changeCount),
                                                    @"readString": @(readString),
                                                    @"readURL": @(readURL),
                                                    @"readImage": @(readImage),
                                                    @"allowImages": @(allowImages),
                                                    @"rawTypesCount": @([candidateTypes count]),
                                                    @"rawTypes": [candidateTypes copy]
                                                });

    NSArray<NSString *> *fallbackTypes = @[
        @"public.utf8-plain-text",
        @"public.plain-text",
        @"public.text",
        @"public.url",
        @"public.png",
        @"public.jpeg",
        @"public.heic",
        @"public.heif",
        @"public.image"
    ];
    for (NSString *type in fallbackTypes) {
        if (![candidateTypes containsObject:type]) {
            [candidateTypes addObject:type];
        }
    }

    for (NSString *type in PBSortedPasteboardTypesForPullCapture(candidateTypes)) {
        if (type.length == 0) {
            continue;
        }
        if (!allowImages && PBPasteboardTypeLooksImage(type)) {
            continue;
        }

        @try {
            (void)[pasteboard dataForPasteboardType:type];
        } @catch (__unused NSException *exception) {
        }
    }
    PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"sb-universal-pull-data-reads"
                                                details:@{
                                                    @"changeCount": @(pasteboard.changeCount),
                                                    @"candidateTypesCount": @([candidateTypes count]),
                                                    @"candidateTypes": [candidateTypes copy],
                                                    @"allowImages": @(allowImages)
                                                });
}

@implementation PBClipboardManager

+ (instancetype)sharedManager {
    static PBClipboardManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[PBClipboardManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _items = [NSMutableArray array];
        _recentCaptureFingerprints = [NSMutableDictionary dictionary];
        _clipboardQueue = dispatch_queue_create("com.ssdsl.ioscopy.clipboard", DISPATCH_QUEUE_SERIAL);
        _pasteboardQueue = dispatch_queue_create("com.ssdsl.ioscopy.pasteboard-read", DISPATCH_QUEUE_SERIAL);
        _ocrWorkerQueue = dispatch_queue_create("com.ssdsl.ioscopy.ocr-worker", DISPATCH_QUEUE_SERIAL);
        _pendingChangeCount = -1;
        _lastLocalPasteboardChangeCount = -1;
        _lastLocalSourceChangeCount = -1;
        _suppressedChangeCount = -1;
        @try {
            PBSetInternalPasteboardRead(YES);
            _lastChangeCount = [UIPasteboard generalPasteboard].changeCount;
        } @catch (NSException *exception) {
            _lastChangeCount = 0;
        } @finally {
            PBSetInternalPasteboardRead(NO);
        }
        _isEnabled = YES;
        _maxItemCount = 50;
        _recordImages = YES;
        _imageTextSearchEnabled = YES;
        _recordURLs = YES;
        _autoClose = YES;
        _hapticFeedback = YES;
        _cleanupDays = 30;
        _excludedApps = @[];

        [self loadPreferences];

        // Listen for preference changes
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)(self),
            (CFNotificationCallback)prefsChanged,
            CFSTR("com.ssdsl.ioscopy/prefschanged"),
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );
    }
    return self;
}

static void prefsChanged(CFNotificationCenterRef center, void *observer,
                         CFStringRef name, const void *object,
                         CFDictionaryRef userInfo) {
    PBClipboardManager *mgr = (__bridge PBClipboardManager *)observer;
    [mgr loadPreferences];
}

static void universalInboxChanged(CFNotificationCenterRef center,
                                  void *observer,
                                  CFNotificationName name,
                                  const void *object,
                                  CFDictionaryRef userInfo) {
    PBClipboardManager *mgr = (__bridge PBClipboardManager *)observer;
    dispatch_async(mgr.pasteboardQueue, ^{
        [mgr processUniversalClipboardInbox];
    });
}

static void savePasteboardRequested(CFNotificationCenterRef center,
                                    void *observer,
                                    CFNotificationName name,
                                    const void *object,
                                    CFDictionaryRef userInfo) {
    PBClipboardManager *mgr = (__bridge PBClipboardManager *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        [mgr processClipboardChange];
    });
}

static void clearAllDataRequested(CFNotificationCenterRef center,
                                  void *observer,
                                  CFNotificationName name,
                                  const void *object,
                                  CFDictionaryRef userInfo) {
    PBClipboardManager *mgr = (__bridge PBClipboardManager *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        [mgr deleteAllItems];
    });
}

static void buildImageTextIndexRequested(CFNotificationCenterRef center,
                                         void *observer,
                                         CFNotificationName name,
                                         const void *object,
                                         CFDictionaryRef userInfo) {
    PBClipboardManager *mgr = (__bridge PBClipboardManager *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (mgr.imageTextSearchEnabled) {
            [mgr runImageOCRWorkerWithLimit:kPBManualOCRBackfillLimit retryFailed:YES];
        }
    });
}

static void ocrIndexUpdated(CFNotificationCenterRef center,
                            void *observer,
                            CFNotificationName name,
                            const void *object,
                            CFDictionaryRef userInfo) {
    PBClipboardManager *mgr = (__bridge PBClipboardManager *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        [mgr refreshItems];
        [[NSNotificationCenter defaultCenter] postNotificationName:PBClipboardManagerDidUpdateNotification
                                                            object:nil];
    });
}

- (void)loadPreferences {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];

    self.isEnabled = YES;
    self.maxItemCount = 50;
    self.recordImages = YES;
    self.imageTextSearchEnabled = YES;
    self.recordURLs = YES;
    self.autoClose = YES;
    self.hapticFeedback = YES;
    self.cleanupDays = 30;
    self.excludedApps = @[];

    if ([prefs isKindOfClass:[NSDictionary class]]) {
        if (prefs[kPBPreferenceEnabled]) self.isEnabled = [prefs[kPBPreferenceEnabled] boolValue];
        if (prefs[kPBPreferenceMaxItems]) self.maxItemCount = [prefs[kPBPreferenceMaxItems] integerValue];
        if (prefs[kPBPreferenceRecordImages]) self.recordImages = [prefs[kPBPreferenceRecordImages] boolValue];
        if (prefs[kPBPreferenceImageTextSearchEnabled]) self.imageTextSearchEnabled = [prefs[kPBPreferenceImageTextSearchEnabled] boolValue];
        if (prefs[kPBPreferenceRecordURLs]) self.recordURLs = [prefs[kPBPreferenceRecordURLs] boolValue];
        if (prefs[kPBPreferenceAutoClose]) self.autoClose = [prefs[kPBPreferenceAutoClose] boolValue];
        if (prefs[kPBPreferenceHapticFeedback]) self.hapticFeedback = [prefs[kPBPreferenceHapticFeedback] boolValue];
        if (prefs[kPBPreferenceCleanupDays]) self.cleanupDays = [prefs[kPBPreferenceCleanupDays] integerValue];
        if ([prefs[kPBPreferenceExcludedApps] isKindOfClass:[NSArray class]]) self.excludedApps = prefs[kPBPreferenceExcludedApps];
    }

    // Enforce bounds
    if (self.maxItemCount < 10) self.maxItemCount = 10;
    if (self.maxItemCount > 500) self.maxItemCount = 500;
    if (self.cleanupDays < 0) self.cleanupDays = 0;
    if (self.cleanupDays > 3650) self.cleanupDays = 3650;

    if (!self.isEnabled) {
        [self.debounceTimer invalidate];
        self.debounceTimer = nil;
        self.pendingChangeCount = -1;
    }

    [self runMaintenanceCleanup];
}

- (void)runMaintenanceCleanup {
    [[PBStorageManager sharedManager] cleanupOldItemsWithMaxCount:self.maxItemCount];
    [[PBStorageManager sharedManager] cleanupItemsOlderThanDays:self.cleanupDays];
}

- (void)runImageOCRWorkerWithLimit:(NSInteger)limit retryFailed:(BOOL)retryFailed {
    if (!self.imageTextSearchEnabled || limit <= 0) {
        return;
    }

    dispatch_async(self.ocrWorkerQueue, ^{
        NSInteger boundedLimit = MAX(1, MIN(limit, 50));
        NSString *requestPath = PBOCRWorkerRequestPath();
        NSString *requestDirectory = [requestPath stringByDeletingLastPathComponent];
        NSError *directoryError = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:requestDirectory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&directoryError];
        if (directoryError) {
            PBClipboardDebugLog(@"failed to create ocr request directory %@: %@", requestDirectory, directoryError);
            return;
        }

        NSDictionary *request = @{
            @"limit": @(boundedLimit),
            @"retryFailed": @(retryFailed),
            @"timestamp": @([[NSDate date] timeIntervalSince1970])
        };
        if (![request writeToFile:requestPath atomically:YES]) {
            PBClipboardDebugLog(@"failed to write ocr request %@", requestPath);
            return;
        }

        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             (__bridge CFStringRef)kPBOCRWorkerRequestNotification,
                                             NULL,
                                             NULL,
                                             YES);
        PBClipboardDebugLog(@"posted ocr worker request limit=%ld retry=%d",
                            (long)boundedLimit,
                            retryFailed ? 1 : 0);
    });
}

#pragma mark - Monitoring

- (void)startMonitoring {
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)(self),
        clearAllDataRequested,
        (__bridge CFStringRef)kPBClearAllDataNotification,
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)(self),
        universalInboxChanged,
        (__bridge CFStringRef)PBInputBridgeUniversalInboxNotification,
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)(self),
        savePasteboardRequested,
        (__bridge CFStringRef)PBInputBridgeSavePasteboardNotification,
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)(self),
        buildImageTextIndexRequested,
        (__bridge CFStringRef)kPBBuildImageTextIndexNotification,
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)(self),
        ocrIndexUpdated,
        (__bridge CFStringRef)kPBOCRIndexUpdatedNotification,
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(pasteboardDidChange:)
                                                 name:UIPasteboardChangedNotification
                                               object:nil];

    // Also poll periodically as a fallback (some changes aren't notified)
    if (!self.pollTimer) {
        self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                          target:self
                                                        selector:@selector(pollPasteboard)
                                                        userInfo:nil
                                                         repeats:YES];
    }

    [self refreshItems];
    if (!self.isEnabled) {
        return;
    }

    if (self.imageTextSearchEnabled) {
        [self runImageOCRWorkerWithLimit:kPBAutomaticOCRBackfillLimit retryFailed:NO];
    }
    [self processUniversalClipboardInbox];
}

- (void)stopMonitoring {
    CFNotificationCenterRemoveObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)(self),
        (__bridge CFStringRef)kPBClearAllDataNotification,
        NULL
    );

    CFNotificationCenterRemoveObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)(self),
        (__bridge CFStringRef)PBInputBridgeUniversalInboxNotification,
        NULL
    );

    CFNotificationCenterRemoveObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)(self),
        (__bridge CFStringRef)PBInputBridgeSavePasteboardNotification,
        NULL
    );

    CFNotificationCenterRemoveObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)(self),
        (__bridge CFStringRef)kPBBuildImageTextIndexNotification,
        NULL
    );

    CFNotificationCenterRemoveObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)(self),
        (__bridge CFStringRef)kPBOCRIndexUpdatedNotification,
        NULL
    );

    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIPasteboardChangedNotification
                                                  object:nil];
    [self.pollTimer invalidate];
    self.pollTimer = nil;
    [self.debounceTimer invalidate];
    self.debounceTimer = nil;
}

- (void)pasteboardDidChange:(NSNotification *)notification {
    if (!self.isEnabled) return;
    if ([self shouldIgnorePasteboardChange]) return;

    PBClipboardDebugLog(@"UIPasteboardChangedNotification received lastChange=%ld",
                        (long)self.lastChangeCount);

    // Debounce: wait 300ms to avoid rapid-fire notifications
    [self.debounceTimer invalidate];
    self.debounceTimer = [NSTimer scheduledTimerWithTimeInterval:0.3
                                                         target:self
                                                       selector:@selector(processClipboardChange)
                                                       userInfo:nil
                                                        repeats:NO];
}

- (void)pollPasteboard {
    if (!self.isEnabled) return;

    [self processUniversalClipboardInbox];

    NSInteger currentCount = self.lastChangeCount;
    @try {
        PBSetInternalPasteboardRead(YES);
        currentCount = [UIPasteboard generalPasteboard].changeCount;
    } @catch (NSException *exception) {
        PBClipboardDebugLog(@"exception polling pasteboard: %@", exception);
    } @finally {
        PBSetInternalPasteboardRead(NO);
    }

    if (currentCount != self.lastChangeCount) {
        PBClipboardDebugLog(@"poll detected change old=%ld new=%ld",
                            (long)self.lastChangeCount,
                            (long)currentCount);
        if ([self consumeSuppressedPasteboardChangeWithCount:currentCount]) {
            PBClipboardDebugLog(@"poll consumed suppressed change=%ld", (long)currentCount);
            return;
        }

        self.lastChangeCount = currentCount;
        [self processClipboardChange];
    }
}

- (void)processUniversalClipboardInbox {
    if (!self.isEnabled) {
        return;
    }

    NSArray<NSDictionary *> *inboxItems = [PBInputBridge pendingUniversalClipboardInboxItems];
    if (inboxItems.count == 0) {
        return;
    }

    NSDictionary *sourceInfo = @{
        @"bundleId": kPBUniversalClipboardBundleId,
        @"appName": kPBUniversalClipboardAppName
    };

    for (NSDictionary *itemInfo in inboxItems) {
        @autoreleasepool {
            NSString *kind = itemInfo[@"contentKind"];
            NSString *content = itemInfo[@"content"];
            BOOL shouldDeleteInboxItem = NO;
            PBClipboardDebugLog(@"import universal inbox id=%@ kind=%@ textLength=%lu imageBytes=%lu source=%@",
                                itemInfo[@"id"] ?: @"",
                                kind ?: @"",
                                (unsigned long)content.length,
                                (unsigned long)[itemInfo[@"imageBytes"] unsignedIntegerValue],
                                itemInfo[@"source"] ?: @"");

            if ([kind isEqualToString:@"text"] && content.length > 0) {
                shouldDeleteInboxItem = [self saveClipboardTextContentSynchronously:content
                                                                         sourceInfo:sourceInfo];
            } else if ([kind isEqualToString:@"image"] && !self.recordImages) {
                shouldDeleteInboxItem = YES;
            } else if ([kind isEqualToString:@"image"] && self.recordImages) {
                NSString *imagePath = itemInfo[@"imagePath"];
                NSDictionary *attributes = imagePath.length > 0
                    ? [[NSFileManager defaultManager] attributesOfItemAtPath:imagePath error:nil]
                    : nil;
                unsigned long long fileSize = [attributes fileSize];
                NSData *imageData = nil;
                if (fileSize > 0 && fileSize <= kPBUniversalInboxMaxImageBytes) {
                    imageData = [NSData dataWithContentsOfFile:imagePath];
                }

                if (imageData.length > 0) {
                    UIImage *image = [UIImage imageWithData:imageData];
                    if (image) {
                        shouldDeleteInboxItem = [self saveClipboardImageSynchronously:image
                                                                            imageData:imageData
                                                                           sourceInfo:sourceInfo];
                    } else {
                        PBClipboardDebugLog(@"universal inbox image decode failed id=%@ bytes=%lu",
                                            itemInfo[@"id"] ?: @"",
                                            (unsigned long)imageData.length);
                        shouldDeleteInboxItem = YES;
                    }
                } else {
                    PBClipboardDebugLog(@"universal inbox image read failed id=%@ path=%@ bytes=%llu",
                                        itemInfo[@"id"] ?: @"",
                                        imagePath ?: @"",
                                        fileSize);
                    shouldDeleteInboxItem = YES;
                }
            } else {
                shouldDeleteInboxItem = YES;
            }

            if (shouldDeleteInboxItem) {
                [PBInputBridge deleteUniversalClipboardInboxItem:itemInfo];
            } else {
                PBClipboardDebugLog(@"keep universal inbox item for retry id=%@ kind=%@",
                                    itemInfo[@"id"] ?: @"",
                                    kind ?: @"");
            }
        }
    }
}

- (void)processClipboardChange {
    if (!self.isEnabled) {
        return;
    }

    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self processClipboardChange];
        });
        return;
    }

    NSInteger changeCount = [self currentPasteboardChangeCount];
    self.lastChangeCount = changeCount;
    PBClipboardDebugLog(@"process change start changeCount=%ld mainThread=%d",
                        (long)changeCount,
                        [NSThread isMainThread]);
    PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"sb-process-change-start"
                                                details:@{
                                                    @"changeCount": @(changeCount),
                                                    @"mainThread": @([NSThread isMainThread])
                                                });
    if ([self consumeSuppressedPasteboardChangeWithCount:changeCount]) {
        PBClipboardDebugLog(@"process change consumed suppressed count=%ld", (long)changeCount);
        PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"sb-process-change-suppressed"
                                                    details:@{
                                                        @"changeCount": @(changeCount)
                                                    });
        return;
    }
    // iOSCopy 自己为了执行粘贴而临时写入的内容不应进入历史记录。
    NSDictionary *internalPasteInfo = [PBInputBridge recentInternalPasteboardWriteInfoForChangeCount:changeCount];
    if (internalPasteInfo) {
        NSNumber *sourceChangeCount = internalPasteInfo[@"changeCount"];
        self.pendingChangeCount = -1;
        self.lastLocalPasteboardChangeCount = changeCount;
        if ([sourceChangeCount isKindOfClass:[NSNumber class]]) {
            self.lastLocalSourceChangeCount = sourceChangeCount.integerValue;
        }
        [PBInputBridge clearInternalPasteboardWriteInfo];
        PBClipboardDebugLog(@"ignore internal pasteboard write changeCount=%ld sourceChange=%ld bundle=%@ imageBytes=%lu",
                            (long)changeCount,
                            (long)[sourceChangeCount integerValue],
                            internalPasteInfo[@"bundleId"] ?: @"",
                            (unsigned long)[internalPasteInfo[@"imageBytes"] unsignedIntegerValue]);
        PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"sb-process-change-internal-write"
                                                    details:@{
                                                        @"changeCount": @(changeCount),
                                                        @"sourceChangeCount": sourceChangeCount ?: @(-1),
                                                        @"bundleId": internalPasteInfo[@"bundleId"] ?: @"",
                                                        @"imageBytes": internalPasteInfo[@"imageBytes"] ?: @0
                                                    });
        return;
    }

    NSDictionary *captureRequestForSuppression =
        [PBInputBridge pendingSpringBoardPasteboardCaptureRequest];
    NSString *suppressionBypassReason = captureRequestForSuppression[@"reason"];
    NSNumber *suppressionRequestChangeCount =
        captureRequestForSuppression[@"changeCount"];
    BOOL suppressionBypassIsUniversal =
        [suppressionBypassReason isEqualToString:@"universal"] ||
        [suppressionBypassReason isEqualToString:@"universal-pull"];
    BOOL suppressionBypassMatchesChange =
        [suppressionRequestChangeCount isKindOfClass:[NSNumber class]] &&
        (suppressionRequestChangeCount.integerValue < 0 || changeCount < 0 ||
         suppressionRequestChangeCount.integerValue == changeCount);
    BOOL shouldBypassOutgoingSuppression =
        suppressionBypassIsUniversal && suppressionBypassMatchesChange;
    if (!shouldBypassOutgoingSuppression) {
        NSDictionary *outgoingSuppression =
            [PBInputBridge activeOutgoingPasteboardSuppressionInfoForChangeCount:changeCount];
        if (outgoingSuppression) {
            self.pendingChangeCount = -1;
            self.lastLocalPasteboardChangeCount = changeCount;
            self.lastLocalSourceChangeCount = changeCount;
            PBClipboardDebugLog(@"ignore outgoing pasteboard write changeCount=%ld requestId=%@ kind=%@",
                                (long)changeCount,
                                outgoingSuppression[@"requestId"] ?: @"",
                                outgoingSuppression[@"contentKind"] ?: @"");
            PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"sb-process-change-outgoing-suppressed"
                                                        details:@{
                                                            @"changeCount": @(changeCount),
                                                            @"requestId": outgoingSuppression[@"requestId"] ?: @"",
                                                            @"contentKind": outgoingSuppression[@"contentKind"] ?: @"",
                                                            @"startChangeCount": outgoingSuppression[@"startChangeCount"] ?: @(-1)
                                                        });
            return;
        }
    } else {
        PBClipboardDebugLog(@"bypass outgoing suppression for universal route changeCount=%ld reason=%@",
                            (long)changeCount,
                            suppressionBypassReason ?: @"");
        PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"sb-process-change-outgoing-bypass-universal"
                                                    details:@{
                                                        @"changeCount": @(changeCount),
                                                        @"requestReason": suppressionBypassReason ?: @"",
                                                        @"requestChangeCount": suppressionRequestChangeCount ?: @(-1),
                                                        @"requestId": captureRequestForSuppression[@"id"] ?: @""
                                                    });
    }

    self.pendingChangeCount = changeCount;
    PBClipboardDebugLog(@"schedule unified pull capture changeCount=%ld", (long)changeCount);
    PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"sb-process-change-schedule-unified"
                                                details:@{
                                                    @"changeCount": @(changeCount)
                                                });
    dispatch_async(self.pasteboardQueue, ^{
        [self processUnifiedPullCaptureWithExpectedCount:changeCount attempt:1];
    });
}

- (void)processUnifiedPullCaptureWithExpectedCount:(NSInteger)expectedCount
                                           attempt:(NSInteger)attempt {
    @autoreleasepool {
        PBClipboardDebugLog(@"unified pull attempt=%ld expected=%ld pending=%ld",
                            (long)attempt,
                            (long)expectedCount,
                            (long)self.pendingChangeCount);
        PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"sb-unified-pull-attempt"
                                                    details:@{
                                                        @"attempt": @(attempt),
                                                        @"expectedChangeCount": @(expectedCount),
                                                        @"pendingChangeCount": @(self.pendingChangeCount)
                                                    });
        if (expectedCount != self.pendingChangeCount) {
            PBClipboardDebugLog(@"unified pull abort: expected no longer pending expected=%ld pending=%ld",
                                (long)expectedCount,
                                (long)self.pendingChangeCount);
            PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"sb-unified-pull-abort-pending-mismatch"
                                                        details:@{
                                                            @"attempt": @(attempt),
                                                            @"expectedChangeCount": @(expectedCount),
                                                            @"pendingChangeCount": @(self.pendingChangeCount)
                                                        });
            return;
        }

        NSDictionary *recentSource = [PBInputBridge recentPasteboardSourceInfoForChangeCount:expectedCount];
        NSDictionary *captureRequest = [PBInputBridge pendingSpringBoardPasteboardCaptureRequest];
        NSNumber *requestChangeCount = captureRequest[@"changeCount"];
        BOOL captureMatches = [requestChangeCount isKindOfClass:[NSNumber class]] &&
                              (requestChangeCount.integerValue < 0 ||
                               expectedCount < 0 ||
                               labs(requestChangeCount.integerValue - expectedCount) <= 128);
        NSString *requestReason = captureMatches ? captureRequest[@"reason"] : nil;
        NSDictionary *requestSourceInfo = captureMatches ? captureRequest[@"sourceInfo"] : nil;
        NSString *captureRequestId = captureMatches ? captureRequest[@"id"] : nil;
        BOOL requestIsApp = [requestReason isEqualToString:@"app"];
        BOOL requestIsSnapper = [requestReason isEqualToString:@"snapper"];
        BOOL requestIsUniversal = [requestReason isEqualToString:@"universal"];
        BOOL isUniversalProbe = [requestReason isEqualToString:@"universal-pull"];
        BOOL hasRecentAppSource = [recentSource isKindOfClass:[NSDictionary class]] &&
                                  [recentSource[@"bundleId"] length] > 0;
        BOOL hasRequestAppSource = requestIsApp &&
                                   [requestSourceInfo isKindOfClass:[NSDictionary class]] &&
                                   [requestSourceInfo[@"bundleId"] length] > 0;
        NSDictionary *appRouteSourceInfo = hasRecentAppSource ? recentSource :
            (hasRequestAppSource ? requestSourceInfo : nil);
        NSNumber *appRouteSourceChangeCount = appRouteSourceInfo[@"changeCount"];
        BOOL appRouteMatchesExpectedChangeCount =
            [appRouteSourceChangeCount isKindOfClass:[NSNumber class]] &&
            appRouteSourceChangeCount.integerValue == expectedCount;
        BOOL captureHasExplicitNonAppRoute =
            requestIsSnapper ||
            requestIsUniversal ||
            isUniversalProbe;
        (void)appRouteMatchesExpectedChangeCount;
        (void)captureHasExplicitNonAppRoute;
        BOOL hasAppRoute = appRouteSourceInfo != nil &&
                           !requestIsUniversal &&
                           !isUniversalProbe &&
                           !requestIsSnapper;
        BOOL hasCaptureRoute = captureMatches;
        PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"sb-unified-pull-route"
                                                    details:@{
                                                        @"attempt": @(attempt),
                                                        @"expectedChangeCount": @(expectedCount),
                                                        @"recentSourcePresent": @(recentSource != nil),
                                                        @"captureRequestPresent": @(captureRequest != nil),
                                                        @"captureMatches": @(captureMatches),
                                                        @"requestReason": requestReason ?: @"",
                                                        @"requestChangeCount": requestChangeCount ?: @(-1),
                                                        @"requestId": captureRequestId ?: @"",
                                                        @"hasAppRoute": @(hasAppRoute),
                                                        @"hasCaptureRoute": @(hasCaptureRoute),
                                                        @"captureHasExplicitNonAppRoute": @(captureHasExplicitNonAppRoute),
                                                        @"hasRecentAppSource": @(hasRecentAppSource),
                                                        @"hasRequestAppSource": @(hasRequestAppSource),
                                                        @"appRouteMatchesExpectedChangeCount": @(appRouteMatchesExpectedChangeCount),
                                                        @"sourceInfo": requestSourceInfo ?: @{}
                                                    });
        if (!hasAppRoute && !hasCaptureRoute) {
            self.pendingChangeCount = -1;
            PBClipboardDebugLog(@"unified pull ignored: no owned route expected=%ld reason=%@",
                                (long)expectedCount,
                                requestReason ?: @"");
            PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"sb-unified-pull-no-route"
                                                        details:@{
                                                            @"attempt": @(attempt),
                                                            @"expectedChangeCount": @(expectedCount),
                                                            @"requestReason": requestReason ?: @"",
                                                            @"captureRequestPresent": @(captureRequest != nil)
                                                        });
            return;
        }

        if (requestIsSnapper && !hasAppRoute && attempt < kPBSnapperFallbackAttempt) {
            PBClipboardDebugLog(@"unified pull wait for app route before snapper fallback attempt=%ld expected=%ld",
                                (long)attempt,
                                (long)expectedCount);
            PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"sb-unified-pull-snapper-wait-app-route"
                                                        details:@{
                                                            @"attempt": @(attempt),
                                                            @"nextAttempt": @(attempt + 1),
                                                            @"expectedChangeCount": @(expectedCount),
                                                            @"requestId": captureRequestId ?: @"",
                                                            @"settleDelay": @(kPBSnapperAppRouteSettleDelay)
                                                        });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPBSnapperAppRouteSettleDelay * NSEC_PER_SEC)),
                           self.pasteboardQueue, ^{
                [self processUnifiedPullCaptureWithExpectedCount:expectedCount
                                                         attempt:attempt + 1];
            });
            return;
        }

        NSString *textContent = nil;
        NSData *imageData = nil;
        NSString *resolvedBundleId = nil;
        NSString *resolvedAppName = nil;
        BOOL isMatched = NO;
        BOOL matchedOnlyHasImage = NO;
        BOOL capturedOnlyHasImage = NO;
        BOOL didUniversalProbe = NO;
        NSDictionary *readSourceInfo = hasAppRoute ? appRouteSourceInfo : requestSourceInfo;
        NSString *authReason = hasAppRoute ? @"app" : (requestReason ?: @"springboard-capture");
        NSString *readAuthorizationId =
            [PBInputBridge beginSpringBoardPasteboardReadAuthorizationForChangeCount:expectedCount
                                                                              reason:authReason
                                                                          sourceInfo:readSourceInfo];
        if (readAuthorizationId.length == 0) {
            PBClipboardDebugLog(@"unified pull abort: failed to begin read auth expected=%ld reason=%@",
                                (long)expectedCount,
                                authReason ?: @"");
            PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"sb-unified-pull-auth-begin-failed"
                                                        details:@{
                                                            @"attempt": @(attempt),
                                                            @"expectedChangeCount": @(expectedCount),
                                                            @"reason": authReason ?: @""
                                                        });
            return;
        }

        PBSetInternalPasteboardRead(YES);
        @try {
            UIPasteboard *generalPasteboard = [UIPasteboard generalPasteboard];
            if (generalPasteboard.changeCount != expectedCount) {
                PBClipboardDebugLog(@"unified pull change mismatch expected=%ld actual=%ld",
                                    (long)expectedCount,
                                    (long)generalPasteboard.changeCount);
                PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"sb-unified-pull-change-mismatch"
                                                            details:@{
                                                                @"attempt": @(attempt),
                                                                @"expectedChangeCount": @(expectedCount),
                                                                @"actualChangeCount": @(generalPasteboard.changeCount),
                                                                @"reason": authReason ?: @""
                                                            });
                return;
            }

            if (isUniversalProbe) {
                didUniversalProbe = YES;
                PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"sb-universal-pull-start"
                                                            details:@{
                                                                @"attempt": @(attempt),
                                                                @"changeCount": @(expectedCount),
                                                                @"recordImages": @(self.recordImages),
                                                                @"requestId": captureRequestId ?: @""
                                                            });
                PBTriggerUniversalClipboardDownloadProbe(generalPasteboard,
                                                         self.recordImages);
            } else {
                NSArray *pasteboardItems = PBObjectByPerformingSelector(generalPasteboard, @selector(_items));
                if (![pasteboardItems isKindOfClass:[NSArray class]] || pasteboardItems.count == 0) {
                    pasteboardItems = generalPasteboard.items;
                }

                id mainItem = pasteboardItems.firstObject;
                NSArray *types = PBObjectByPerformingSelector(mainItem, @selector(types));
                if (![types isKindOfClass:[NSArray class]] && [mainItem isKindOfClass:[NSDictionary class]]) {
                    types = [(NSDictionary *)mainItem allKeys];
                }
                if (![types isKindOfClass:[NSArray class]]) {
                    types = @[];
                }

                id creatorValue = PBObjectByPerformingSelector(mainItem, @selector(creator));
                NSString *creator = [creatorValue isKindOfClass:[NSString class]] ? creatorValue : nil;
                id deviceNameValue = PBObjectByPerformingSelector(mainItem, @selector(sourceDeviceName));
                NSString *deviceName = [deviceNameValue isKindOfClass:[NSString class]] ? deviceNameValue : nil;
                BOOL hasRemoteMarker = [types containsObject:@"com.apple.is-remote-clipboard"];
                BOOL hasImageType = NO;
                BOOL hasTextType = NO;
                for (NSString *type in types) {
                    if (![type isKindOfClass:[NSString class]]) {
                        continue;
                    }
                    if (PBPasteboardTypeLooksImage(type)) {
                        hasImageType = YES;
                    } else if (PBPasteboardTypeLooksText(type) || PBPasteboardTypeLooksHTML(type)) {
                        hasTextType = YES;
                    }
                }
                capturedOnlyHasImage = hasImageType && !hasTextType;
                PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"sb-unified-pull-item"
                                                            details:@{
                                                                @"attempt": @(attempt),
                                                                @"changeCount": @(expectedCount),
                                                                @"requestReason": requestReason ?: @"",
                                                                @"itemCount": @([pasteboardItems count]),
                                                                @"itemClass": mainItem ? NSStringFromClass([mainItem class]) : @"",
                                                                @"types": types ?: @[],
                                                                @"creator": creator ?: @"",
                                                                @"sourceDeviceName": deviceName ?: @"",
                                                                @"hasRemoteMarker": @(hasRemoteMarker),
                                                                @"hasImageType": @(hasImageType),
                                                                @"hasTextType": @(hasTextType)
                                                            });

                if (hasAppRoute) {
                    isMatched = YES;
                    matchedOnlyHasImage = capturedOnlyHasImage;
                    resolvedBundleId = appRouteSourceInfo[@"bundleId"];
                    resolvedAppName = appRouteSourceInfo[@"appName"];

                    NSDictionary *capture = PBContentCaptureFromPasteboardItem(mainItem,
                                                                               types,
                                                                               self.recordImages);
                    if ([capture[@"contentKind"] isEqualToString:@"text"]) {
                        textContent = capture[@"content"];
                    } else if ([capture[@"contentKind"] isEqualToString:@"image"]) {
                        imageData = capture[@"imageData"];
                    }
                    PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"sb-unified-pull-capture-app"
                                                                details:@{
                                                                    @"attempt": @(attempt),
                                                                    @"changeCount": @(expectedCount),
                                                                    @"bundleId": resolvedBundleId ?: @"",
                                                                    @"appName": resolvedAppName ?: @"",
                                                                    @"contentKind": capture[@"contentKind"] ?: @"",
                                                                    @"textLength": @([textContent length]),
                                                                    @"imageBytes": @([imageData length])
                                                                });
                } else if (hasRemoteMarker ||
                           requestIsUniversal) {
                    isMatched = YES;
                    matchedOnlyHasImage = capturedOnlyHasImage;
                    resolvedBundleId = kPBUniversalClipboardBundleId;
                    resolvedAppName = deviceName.length > 0 ?
                        [NSString stringWithFormat:@"%@ (Universal)", deviceName] :
                        kPBUniversalClipboardAppName;

                    NSDictionary *capture = PBContentCaptureFromPasteboardItem(mainItem,
                                                                               types,
                                                                               self.recordImages);
                    if ([capture[@"contentKind"] isEqualToString:@"text"]) {
                        textContent = capture[@"content"];
                    } else if ([capture[@"contentKind"] isEqualToString:@"image"]) {
                        imageData = capture[@"imageData"];
                    }
                    PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"sb-unified-pull-capture-universal"
                                                                details:@{
                                                                    @"attempt": @(attempt),
                                                                    @"changeCount": @(expectedCount),
                                                                    @"sourceDeviceName": deviceName ?: @"",
                                                                    @"hasRemoteMarker": @(hasRemoteMarker),
                                                                    @"contentKind": capture[@"contentKind"] ?: @"",
                                                                    @"textLength": @([textContent length]),
                                                                    @"imageBytes": @([imageData length])
                                                                });
                } else {
                    NSString *creatorLower = creator.lowercaseString ?: @"";
                    BOOL hasSpringBoardCreator =
                        [creatorLower isEqualToString:@"com.apple.springboard"] ||
                        [creatorLower isEqualToString:@"springboard"];
                    BOOL allowSnapperFallback =
                        requestIsSnapper &&
                        attempt >= kPBSnapperFallbackAttempt &&
                        !hasAppRoute;
                    if ((hasSpringBoardCreator || allowSnapperFallback) &&
                        hasImageType &&
                        !hasRemoteMarker) {
                        isMatched = YES;
                        matchedOnlyHasImage = YES;
                        resolvedBundleId = @"com.apple.springboard";
                        resolvedAppName = @"Snapper (截图)";

                        NSDictionary *capture = PBContentCaptureFromPasteboardItem(mainItem,
                                                                                   types,
                                                                                   self.recordImages);
                        if ([capture[@"contentKind"] isEqualToString:@"image"]) {
                            imageData = capture[@"imageData"];
                        }
                        PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"sb-unified-pull-capture-snapper"
                                                                    details:@{
                                                                        @"attempt": @(attempt),
                                                                        @"changeCount": @(expectedCount),
                                                                        @"creator": creator ?: @"",
                                                                        @"creatorMatched": @(hasSpringBoardCreator),
                                                                        @"fallback": @(allowSnapperFallback),
                                                                        @"contentKind": capture[@"contentKind"] ?: @"",
                                                                        @"imageBytes": @([imageData length])
                                                                    });
                    } else if (requestIsSnapper && hasImageType && !hasRemoteMarker) {
                        PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"sb-unified-pull-snapper-defer"
                                                                    details:@{
                                                                        @"attempt": @(attempt),
                                                                        @"changeCount": @(expectedCount),
                                                                        @"creator": creator ?: @"",
                                                                        @"fallbackAttempt": @(kPBSnapperFallbackAttempt),
                                                                        @"hasRecentAppSource": @(hasRecentAppSource),
                                                                        @"hasRequestAppSource": @(hasRequestAppSource),
                                                                        @"appRouteMatchesExpectedChangeCount": @(appRouteMatchesExpectedChangeCount)
                                                                    });
                    }
                }
            }
        } @catch (NSException *exception) {
            PBClipboardDebugLog(@"unified pull capture failed: %@", exception);
            PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"sb-unified-pull-exception"
                                                        details:@{
                                                            @"attempt": @(attempt),
                                                            @"expectedChangeCount": @(expectedCount),
                                                            @"exceptionName": exception.name ?: @"",
                                                            @"exceptionReason": exception.reason ?: @""
                                                        });
        } @finally {
            PBSetInternalPasteboardRead(NO);
            [PBInputBridge endSpringBoardPasteboardReadAuthorizationWithRequestId:readAuthorizationId];
        }

        if (didUniversalProbe) {
            if (captureRequestId.length > 0) {
                [PBInputBridge completeSpringBoardPasteboardCaptureRequestWithRequestId:captureRequestId];
            }
            PBClipboardDebugLog(@"universal probe completed changeCount=%ld",
                                (long)expectedCount);
            PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"sb-universal-pull-completed"
                                                        details:@{
                                                            @"changeCount": @(expectedCount),
                                                            @"requestId": captureRequestId ?: @""
                                                        });
            return;
        }

        BOOL hasCapturedPayload = textContent.length > 0 || imageData.length > 0;
        BOOL shouldFinishMatchedCapture = isMatched &&
            (hasCapturedPayload || (!self.recordImages && matchedOnlyHasImage));
        if (shouldFinishMatchedCapture) {
            NSDictionary *sourceInfo = @{
                @"bundleId": resolvedBundleId ?: @"",
                @"appName": resolvedAppName ?: @"Unknown"
            };
            NSString *bundleId = sourceInfo[@"bundleId"] ?: @"";
            self.pendingChangeCount = -1;
            self.lastLocalPasteboardChangeCount = expectedCount;
            self.lastLocalSourceChangeCount = expectedCount;
            if ([self.excludedApps containsObject:bundleId]) {
                PBClipboardDebugLog(@"skip excluded unified source changeCount=%ld bundle=%@",
                                    (long)expectedCount,
                                    bundleId);
                return;
            }

            PBClipboardDebugLog(@"unified pull matched changeCount=%ld bundle=%@ app=%@ textLength=%lu imageBytes=%lu",
                                (long)expectedCount,
                                bundleId,
                                sourceInfo[@"appName"] ?: @"",
                                (unsigned long)textContent.length,
                                (unsigned long)imageData.length);
            BOOL saveSucceeded = NO;
            if (textContent.length > 0) {
                saveSucceeded =
                    [self saveClipboardTextContentSynchronously:textContent
                                                     sourceInfo:sourceInfo];
            } else if (imageData.length > 0 && self.recordImages) {
                UIImage *image = [UIImage imageWithData:imageData];
                if (image) {
                    saveSucceeded =
                        [self saveClipboardImageSynchronously:image
                                                    imageData:imageData
                                                   sourceInfo:sourceInfo];
                }
            }
            if (saveSucceeded && captureRequestId.length > 0) {
                [PBInputBridge completeSpringBoardPasteboardCaptureRequestWithRequestId:captureRequestId];
            }
            PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"sb-unified-pull-save-result"
                                                        details:@{
                                                            @"changeCount": @(expectedCount),
                                                            @"bundleId": bundleId ?: @"",
                                                            @"appName": sourceInfo[@"appName"] ?: @"",
                                                            @"textLength": @([textContent length]),
                                                            @"imageBytes": @([imageData length]),
                                                            @"recordImages": @(self.recordImages),
                                                            @"saveSucceeded": @(saveSucceeded),
                                                            @"requestId": captureRequestId ?: @""
                                                        });
        } else if (attempt < kPBMaxPasteboardReadAttempts &&
                   expectedCount == self.pendingChangeCount) {
            PBClipboardDebugLog(@"unified pull retry attempt=%ld expected=%ld matched=%d payload=%d",
                                (long)attempt + 1,
                                (long)expectedCount,
                                isMatched,
                                hasCapturedPayload);
            PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"sb-unified-pull-retry"
                                                        details:@{
                                                            @"nextAttempt": @(attempt + 1),
                                                            @"expectedChangeCount": @(expectedCount),
                                                            @"isMatched": @(isMatched),
                                                            @"hasPayload": @(hasCapturedPayload)
                                                        });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                           self.pasteboardQueue, ^{
                [self processUnifiedPullCaptureWithExpectedCount:expectedCount
                                                         attempt:attempt + 1];
            });
        } else if (expectedCount == self.pendingChangeCount) {
            self.pendingChangeCount = -1;
            PBClipboardDebugLog(@"unified pull ignored changeCount=%ld matched=%d payload=%d",
                                (long)expectedCount,
                                isMatched,
                                hasCapturedPayload);
            PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"sb-unified-pull-ignored"
                                                        details:@{
                                                            @"expectedChangeCount": @(expectedCount),
                                                            @"isMatched": @(isMatched),
                                                            @"hasPayload": @(hasCapturedPayload),
                                                            @"requestReason": requestReason ?: @"",
                                                            @"requestId": captureRequestId ?: @""
                                                        });
        }
    }
}

- (BOOL)saveClipboardTextContentSynchronously:(NSString *)content sourceInfo:(NSDictionary *)sourceInfo {
    if (content.length == 0) {
        return YES;
    }

    NSString *bundleId = sourceInfo[@"bundleId"] ?: @"";
    NSString *appName = sourceInfo[@"appName"] ?: @"Unknown";

    if ([self shouldSkipRecentCaptureWithContent:content
                                       imageData:nil
                                      sourceInfo:sourceInfo
                                     changeCount:self.lastLocalSourceChangeCount]) {
        PBClipboardDebugLog(@"skip recent duplicate text length=%lu bundle=%@",
                            (unsigned long)content.length,
                            bundleId);
        return YES;
    }

    if ([[PBStorageManager sharedManager] isDuplicateContent:content]) {
        PBClipboardDebugLog(@"skip duplicate text length=%lu bundle=%@",
                            (unsigned long)content.length,
                            bundleId);
        return YES;
    }

    PBContentType type = PBContentTypeText;
    if ([self isURL:content]) {
        if (!self.recordURLs) {
            PBClipboardDebugLog(@"skip url because recordURLs disabled length=%lu bundle=%@",
                                (unsigned long)content.length,
                                bundleId);
            return YES;
        }
        type = PBContentTypeURL;
    }

    PBClipboardItem *item = [PBClipboardItem itemWithContent:content
                                                 contentType:type
                                              sourceBundleId:bundleId
                                               sourceAppName:appName];

    if (![[PBStorageManager sharedManager] saveItem:item]) {
        PBClipboardDebugLog(@"failed to save text item length=%lu bundle=%@ app=%@",
                            (unsigned long)content.length,
                            bundleId,
                            appName);
        return NO;
    }

    PBClipboardDebugLog(@"saved text item length=%lu type=%ld bundle=%@ app=%@",
                        (unsigned long)content.length,
                        (long)type,
                        bundleId,
                        appName);
    [self recordRecentCaptureWithContent:content
                               imageData:nil
                              sourceInfo:sourceInfo
                             changeCount:self.lastLocalSourceChangeCount];
    [self runMaintenanceCleanup];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self refreshItems];
        [[NSNotificationCenter defaultCenter]
            postNotificationName:PBClipboardManagerDidUpdateNotification
            object:nil];
    });
    return YES;
}

- (void)saveClipboardTextContent:(NSString *)content sourceInfo:(NSDictionary *)sourceInfo {
    dispatch_async(self.clipboardQueue, ^{
        @try {
            [self saveClipboardTextContentSynchronously:content sourceInfo:sourceInfo];
        } @catch (NSException *exception) {
            PBClipboardDebugLog(@"exception saving pasteboard string: %@", exception);
        }
    });
}

- (BOOL)shouldSkipRecentCaptureWithContent:(NSString *)content
                                  imageData:(NSData *)imageData
                                 sourceInfo:(NSDictionary *)sourceInfo
                                changeCount:(NSInteger)changeCount {
    NSString *fingerprint =
        PBFingerprintForClipboardPayload(content, imageData, sourceInfo,
                                         changeCount);
    if (fingerprint.length == 0) {
        return NO;
    }

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    @synchronized(self.recentCaptureFingerprints) {
        NSMutableArray<NSString *> *expiredKeys = [NSMutableArray array];
        [self.recentCaptureFingerprints
            enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDate *date,
                                                BOOL *stop) {
          if (![date isKindOfClass:[NSDate class]] ||
              now - date.timeIntervalSince1970 >
                  kPBRecentCaptureFingerprintMaxAge) {
              [expiredKeys addObject:key];
          }
        }];
        [self.recentCaptureFingerprints removeObjectsForKeys:expiredKeys];

        NSDate *recentDate = self.recentCaptureFingerprints[fingerprint];
        return [recentDate isKindOfClass:[NSDate class]] &&
               now - recentDate.timeIntervalSince1970 <=
                   kPBRecentCaptureFingerprintMaxAge;
    }
}

- (void)recordRecentCaptureWithContent:(NSString *)content
                              imageData:(NSData *)imageData
                             sourceInfo:(NSDictionary *)sourceInfo
                            changeCount:(NSInteger)changeCount {
    NSString *fingerprint =
        PBFingerprintForClipboardPayload(content, imageData, sourceInfo,
                                         changeCount);
    if (fingerprint.length == 0) {
        return;
    }

    @synchronized(self.recentCaptureFingerprints) {
        self.recentCaptureFingerprints[fingerprint] = [NSDate date];
    }
}

- (BOOL)saveClipboardImageSynchronously:(UIImage *)image
                              imageData:(NSData *)originalImageData
                             sourceInfo:(NSDictionary *)sourceInfo {
    NSData *imageData = originalImageData.length > 0 ? originalImageData : UIImagePNGRepresentation(image);
    if (!imageData) {
        imageData = UIImageJPEGRepresentation(image, 0.95);
    }
    if (!imageData) return NO;

    NSString *imageExtension = PBImageFileExtensionForData(imageData);
    CGFloat imageWidth = MAX(image.size.width, 1.0);
    CGFloat scale = MIN(1.0, 200.0 / imageWidth);
    CGSize thumbSize = CGSizeMake(MAX(image.size.width * scale, 1.0),
                                  MAX(image.size.height * scale, 1.0));
    UIGraphicsBeginImageContextWithOptions(thumbSize, NO, 0);
    [image drawInRect:CGRectMake(0, 0, thumbSize.width, thumbSize.height)];
    UIImage *thumbnail = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    NSData *thumbData = UIImageJPEGRepresentation(thumbnail, 0.6);
    NSInteger maxItemCount = self.maxItemCount;
    NSString *bundleId = sourceInfo[@"bundleId"] ?: @"";
    NSString *appName = sourceInfo[@"appName"] ?: @"Unknown";
    if ([self shouldSkipRecentCaptureWithContent:nil
                                       imageData:imageData
                                      sourceInfo:sourceInfo
                                     changeCount:self.lastLocalSourceChangeCount]) {
        PBClipboardDebugLog(@"skip recent duplicate image bytes=%lu bundle=%@",
                            (unsigned long)imageData.length,
                            bundleId);
        return YES;
    }

    NSString *fileIdentifier = [NSUUID UUID].UUIDString;
    NSString *imageFilename = [NSString stringWithFormat:@"image_%@.%@", fileIdentifier, imageExtension];
    NSString *thumbFilename = [NSString stringWithFormat:@"thumb_%@.jpg", fileIdentifier];

    NSString *imageDir = ROOT_PATH_NS(@"/var/mobile/Library/iOSCopy/images");
    NSString *thumbDir = ROOT_PATH_NS(@"/var/mobile/Library/iOSCopy/thumbnails");
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:imageDir]) {
        NSError *imageDirError = nil;
        [fm createDirectoryAtPath:imageDir
      withIntermediateDirectories:YES
                       attributes:nil
                            error:&imageDirError];
        if (imageDirError) {
            PBClipboardDebugLog(@"failed to create image directory %@: %@", imageDir, imageDirError);
            return NO;
        }
    }

    if (![fm fileExistsAtPath:thumbDir]) {
        NSError *thumbDirError = nil;
        [fm createDirectoryAtPath:thumbDir
      withIntermediateDirectories:YES
                       attributes:nil
                            error:&thumbDirError];
        if (thumbDirError) {
            PBClipboardDebugLog(@"failed to create thumbnail directory %@: %@", thumbDir, thumbDirError);
            return NO;
        }
    }

    NSString *imagePath = [imageDir stringByAppendingPathComponent:imageFilename];
    NSString *thumbPath = [thumbDir stringByAppendingPathComponent:thumbFilename];
    BOOL wroteImage = [imageData writeToFile:imagePath atomically:YES];
    BOOL wroteThumb = thumbData.length == 0 || [thumbData writeToFile:thumbPath atomically:YES];
    if (!wroteImage || !wroteThumb) {
        PBClipboardDebugLog(@"failed to write image files image=%d thumb=%d path=%@",
                            wroteImage,
                            wroteThumb,
                            imagePath);
        [fm removeItemAtPath:imagePath error:nil];
        [fm removeItemAtPath:thumbPath error:nil];
        return NO;
    }

    PBClipboardItem *item = [PBClipboardItem itemWithContent:imagePath
                                                 contentType:PBContentTypeImage
                                              sourceBundleId:bundleId
                                               sourceAppName:appName];
    item.thumbnailPath = thumbPath;
    item.dataSize = imageData.length;

    if (![[PBStorageManager sharedManager] saveItem:item]) {
        PBClipboardDebugLog(@"failed to save image item bytes=%lu bundle=%@ app=%@",
                            (unsigned long)imageData.length,
                            bundleId,
                            appName);
        [fm removeItemAtPath:imagePath error:nil];
        [fm removeItemAtPath:thumbPath error:nil];
        return NO;
    }

    PBClipboardDebugLog(@"saved image item bytes=%lu bundle=%@ app=%@",
                        (unsigned long)imageData.length,
                        bundleId,
                        appName);
    if (self.imageTextSearchEnabled) {
        [self runImageOCRWorkerWithLimit:1 retryFailed:NO];
    }
    [self recordRecentCaptureWithContent:nil
                               imageData:imageData
                              sourceInfo:sourceInfo
                             changeCount:self.lastLocalSourceChangeCount];
    [[PBStorageManager sharedManager] cleanupOldItemsWithMaxCount:maxItemCount];
    [[PBStorageManager sharedManager] cleanupItemsOlderThanDays:self.cleanupDays];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self refreshItems];
        [[NSNotificationCenter defaultCenter]
            postNotificationName:PBClipboardManagerDidUpdateNotification
            object:nil];
    });
    return YES;
}

- (void)saveClipboardImage:(UIImage *)image imageData:(NSData *)originalImageData sourceInfo:(NSDictionary *)sourceInfo {
    dispatch_async(self.clipboardQueue, ^{
        @try {
            [self saveClipboardImageSynchronously:image
                                        imageData:originalImageData
                                       sourceInfo:sourceInfo];
        } @catch (NSException *exception) {
            PBClipboardDebugLog(@"exception saving pasteboard image: %@", exception);
        }
    });
}

#pragma mark - Items

- (NSArray<PBClipboardItem *> *)currentItems {
    @synchronized(self.items) {
        return [self.items copy];
    }
}

- (void)refreshItems {
    NSArray *newItems = [[PBStorageManager sharedManager] allItemsWithLimit:self.maxItemCount];
    @synchronized(self.items) {
        [self.items removeAllObjects];
        [self.items addObjectsFromArray:newItems];
    }
}

- (void)recordCapturedPasteboardContent:(NSString *)content
                              imageData:(NSData *)imageData
                             sourceInfo:(NSDictionary *)sourceInfo
                            changeCount:(NSInteger)changeCount {
    if (content.length == 0 && imageData.length == 0) {
        return;
    }
    if (changeCount >= 0 && changeCount == self.lastLocalSourceChangeCount) {
        return;
    }

    NSDictionary *resolvedSourceInfo = sourceInfo ?: @{
        @"bundleId": @"com.apple.springboard",
        @"appName": @"SpringBoard"
    };
    self.pendingChangeCount = -1;
    if (changeCount >= 0) {
        self.lastChangeCount = changeCount;
        self.lastLocalPasteboardChangeCount = changeCount;
        self.lastLocalSourceChangeCount = changeCount;
    }

    if (content.length > 0) {
        [self saveClipboardTextContent:content sourceInfo:resolvedSourceInfo];
        return;
    }

    if (imageData.length > 0 && self.recordImages) {
        UIImage *image = [UIImage imageWithData:imageData];
        if (image) {
            [self saveClipboardImage:image
                           imageData:imageData
                          sourceInfo:resolvedSourceInfo];
        }
    }
}

- (NSArray<PBClipboardItem *> *)searchWithQuery:(NSString *)query {
    if (!query || query.length == 0) {
        return self.currentItems;
    }
    return [[PBStorageManager sharedManager] searchItemsWithQuery:query
                                                            limit:self.maxItemCount
                                                       includeOCR:self.imageTextSearchEnabled];
}

#pragma mark - Actions

- (void)copyItemToPasteboard:(PBClipboardItem *)item {
    [self copyItemToPasteboard:item completion:nil];
}

- (void)copyItemToPasteboard:(PBClipboardItem *)item completion:(void (^)(BOOL success))completion {
    self.suppressNextPasteboardChange = YES;
    self.suppressedChangeCount = -1;
    [self.debounceTimer invalidate];
    self.debounceTimer = nil;

    void (^finishCopy)(BOOL) = ^(BOOL success) {
        if (!success) {
            self.suppressNextPasteboardChange = NO;
            self.suppressedChangeCount = -1;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (success && self.hapticFeedback) {
                UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc]
                    initWithStyle:UIImpactFeedbackStyleMedium];
                [feedback impactOccurred];
            }
            if (completion) {
                completion(success);
            }
        });
    };

    void (^updateChangeCount)(void) = ^{
        NSInteger currentChangeCount = [UIPasteboard generalPasteboard].changeCount;
        self.lastChangeCount = currentChangeCount;
        self.suppressedChangeCount = currentChangeCount;
    };

    if (item.contentType == PBContentTypeImage && item.thumbnailPath.length > 0) {
        dispatch_async(self.pasteboardQueue, ^{
            BOOL copied = NO;
            @try {
                PBSetInternalPasteboardRead(YES);
                NSData *imageData = [self imageDataForItem:item];
                if (imageData.length > 0) {
                    PBSetPasteboardImageData([UIPasteboard generalPasteboard], imageData, NULL);
                    updateChangeCount();
                    copied = YES;
                }
            } @catch (NSException *exception) {
                PBClipboardDebugLog(@"exception copying image item to pasteboard: %@", exception);
            } @finally {
                PBSetInternalPasteboardRead(NO);
            }
            finishCopy(copied);
        });
        return;
    }

    BOOL copied = NO;
    @try {
        PBSetInternalPasteboardRead(YES);
        [UIPasteboard generalPasteboard].string = item.content;
        updateChangeCount();
        copied = YES;
    } @catch (NSException *exception) {
        PBClipboardDebugLog(@"exception copying text item to pasteboard: %@", exception);
    } @finally {
        PBSetInternalPasteboardRead(NO);
    }
    finishCopy(copied);
}

- (NSData *)imageDataForItem:(PBClipboardItem *)item {
    if (item.contentType != PBContentTypeImage) {
        return nil;
    }

    NSString *imagePath = (item.content.length > 0 && ![item.content isEqualToString:@"[Image]"])
        ? item.content
        : item.thumbnailPath;
    NSData *imageData = imagePath.length > 0 ? [NSData dataWithContentsOfFile:imagePath] : nil;
    if (imageData.length == 0 &&
        item.thumbnailPath.length > 0 &&
        ![imagePath isEqualToString:item.thumbnailPath]) {
        imageData = [NSData dataWithContentsOfFile:item.thumbnailPath];
    }

    return imageData.length > 0 ? imageData : nil;
}

- (BOOL)consumeSuppressedPasteboardChangeWithCount:(NSInteger)changeCount {
    if (!self.suppressNextPasteboardChange) {
        return NO;
    }

    if (self.suppressedChangeCount < 0) {
        self.lastChangeCount = changeCount;
        return YES;
    }

    if (changeCount == self.suppressedChangeCount) {
        self.lastChangeCount = changeCount;
        self.suppressNextPasteboardChange = NO;
        self.suppressedChangeCount = -1;
        return YES;
    }

    self.suppressNextPasteboardChange = NO;
    self.suppressedChangeCount = -1;
    return NO;
}

- (BOOL)shouldIgnorePasteboardChange {
    NSInteger currentCount = self.lastChangeCount;
    @try {
        PBSetInternalPasteboardRead(YES);
        currentCount = [UIPasteboard generalPasteboard].changeCount;
    } @catch (NSException *exception) {
        PBClipboardDebugLog(@"exception checking pasteboard change: %@", exception);
        return NO;
    } @finally {
        PBSetInternalPasteboardRead(NO);
    }

    return [self consumeSuppressedPasteboardChangeWithCount:currentCount];
}

- (void)deleteItem:(PBClipboardItem *)item {
    BOOL deleted = [[PBStorageManager sharedManager] deleteItem:item];
    if (!deleted) {
        return;
    }
    @synchronized(self.items) {
        NSIndexSet *indexes = [self.items indexesOfObjectsPassingTest:^BOOL(PBClipboardItem *cachedItem,
                                                                             NSUInteger idx,
                                                                             BOOL *stop) {
            return cachedItem.itemId == item.itemId;
        }];
        [self.items removeObjectsAtIndexes:indexes];
    }
    [[NSNotificationCenter defaultCenter]
        postNotificationName:PBClipboardManagerDidUpdateNotification object:nil];
}

- (void)togglePinItem:(PBClipboardItem *)item {
    if ([[PBStorageManager sharedManager] togglePinForItem:item]) {
        [self refreshItems];
        [[NSNotificationCenter defaultCenter]
            postNotificationName:PBClipboardManagerDidUpdateNotification object:nil];
    }
}

- (void)toggleFavoriteItem:(PBClipboardItem *)item {
    if ([[PBStorageManager sharedManager] toggleFavoriteForItem:item]) {
        [self refreshItems];
        [[NSNotificationCenter defaultCenter]
            postNotificationName:PBClipboardManagerDidUpdateNotification object:nil];
    }
}

- (void)deleteAllItems {
    [[PBStorageManager sharedManager] deleteAllItems];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *directories = @[
        ROOT_PATH_NS(@"/var/mobile/Library/iOSCopy/images"),
        ROOT_PATH_NS(@"/var/mobile/Library/iOSCopy/thumbnails")
    ];
    for (NSString *directory in directories) {
        [fm removeItemAtPath:directory error:nil];
    }

    @synchronized(self.items) {
        [self.items removeAllObjects];
    }
    [[NSNotificationCenter defaultCenter]
        postNotificationName:PBClipboardManagerDidUpdateNotification object:nil];
}

#pragma mark - Helpers

- (NSInteger)currentPasteboardChangeCount {
    NSInteger currentCount = self.lastChangeCount;
    @try {
        PBSetInternalPasteboardRead(YES);
        currentCount = [UIPasteboard generalPasteboard].changeCount;
    } @catch (NSException *exception) {
        PBClipboardDebugLog(@"exception reading pasteboard change count: %@", exception);
    } @finally {
        PBSetInternalPasteboardRead(NO);
    }
    return currentCount;
}

- (BOOL)isURL:(NSString *)string {
    NSURL *url = [NSURL URLWithString:string];
    return (url && url.scheme && url.host);
}

@end
