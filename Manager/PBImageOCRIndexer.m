#import "PBImageOCRIndexer.h"
#import "PBStorageManager.h"
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <Vision/Vision.h>
#import <stdio.h>

static CGFloat const kPBOCRMaximumImageLongSide = 1600.0;
static NSString * const kPBOCRErrorDomain = @"com.ssdsl.ioscopy.ocr";
static CFStringRef const kPBOCRIndexUpdatedNotification = CFSTR("com.ssdsl.ioscopy/ocrindexupdated");

@interface PBImageOCRIndexer ()
@property (nonatomic, strong) dispatch_queue_t ocrQueue;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *queuedItemIds;
@end

@implementation PBImageOCRIndexer

+ (instancetype)sharedIndexer {
    static PBImageOCRIndexer *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[PBImageOCRIndexer alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _ocrQueue = dispatch_queue_create("com.ssdsl.ioscopy.ocr", DISPATCH_QUEUE_SERIAL);
        _queuedItemIds = [NSMutableSet set];
    }
    return self;
}

- (void)enqueueImageItem:(PBClipboardItem *)item {
    if (item.contentType != PBContentTypeImage || item.itemId <= 0 || item.content.length == 0) {
        return;
    }

    NSNumber *itemId = @(item.itemId);
    @synchronized(self.queuedItemIds) {
        if ([self.queuedItemIds containsObject:itemId]) {
            return;
        }
        [self.queuedItemIds addObject:itemId];
    }

    dispatch_async(self.ocrQueue, ^{
        @autoreleasepool {
            [self processImageItem:item];
        }
        @synchronized(self.queuedItemIds) {
            [self.queuedItemIds removeObject:itemId];
        }
    });
}

- (void)enqueuePendingImageIndexingWithLimit:(NSInteger)limit {
    [self enqueuePendingImageIndexingWithLimit:limit retryFailed:NO];
}

- (void)enqueuePendingImageIndexingWithLimit:(NSInteger)limit retryFailed:(BOOL)retryFailed {
    if (limit <= 0) {
        return;
    }

    NSArray<PBClipboardItem *> *items = [[PBStorageManager sharedManager] imageItemsNeedingOCRWithLimit:limit
                                                                                          includeFailed:retryFailed];
    for (PBClipboardItem *item in items) {
        [self enqueueImageItem:item];
    }
}

- (NSInteger)processPendingImageIndexingWithLimit:(NSInteger)limit retryFailed:(BOOL)retryFailed {
    if (limit <= 0) {
        return 0;
    }

    NSArray<PBClipboardItem *> *items = [[PBStorageManager sharedManager] imageItemsNeedingOCRWithLimit:limit
                                                                                          includeFailed:retryFailed];
    NSInteger processedCount = 0;
    for (PBClipboardItem *item in items) {
        @autoreleasepool {
            if ([self processImageItem:item]) {
                processedCount++;
            }
        }
    }
    return processedCount;
}

- (BOOL)processImageItem:(PBClipboardItem *)item {
    NSInteger revision = 0;
    NSError *error = nil;
    NSString *recognizedText = [self recognizedTextForImageAtPath:item.content
                                                    thumbnailPath:item.thumbnailPath
                                                         revision:&revision
                                                            error:&error];
    PBOCRStatus status = recognizedText != nil ? PBOCRStatusIndexed : PBOCRStatusFailed;
    BOOL updated = [[PBStorageManager sharedManager] updateOCRText:recognizedText ?: @""
                                                            status:status
                                                          revision:revision
                                                             error:[self summaryForError:error]
                                                         forItemId:item.itemId];
    if (status == PBOCRStatusFailed) {
        fprintf(stderr,
                "iOSCopyOCRWorker OCR failed itemId=%ld error=%s\n",
                (long)item.itemId,
                [[self summaryForError:error] UTF8String]);
    }
    if (!updated) {
        fprintf(stderr,
                "iOSCopyOCRWorker failed to update OCR result itemId=%ld\n",
                (long)item.itemId);
    }
    if (updated) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             kPBOCRIndexUpdatedNotification,
                                             NULL,
                                             NULL,
                                             YES);
    }
    return updated;
}

- (NSString *)recognizedTextForImageAtPath:(NSString *)imagePath
                             thumbnailPath:(NSString *)thumbnailPath
                                  revision:(NSInteger *)outRevision
                                     error:(NSError **)outError {
    if (@available(iOS 15.0, *)) {
        CGImageRef cgImage = [self newPreparedCGImageForImageAtPath:imagePath
                                                      thumbnailPath:thumbnailPath
                                                               error:outError];
        if (!cgImage) {
            return nil;
        }

        NSError *lastError = nil;
        NSString *recognizedText = nil;
        NSUInteger recognizedRevision = 0;
        if (@available(iOS 16.0, *)) {
            NSString *text = [self recognizedTextForCGImage:cgImage
                                                    revision:VNRecognizeTextRequestRevision3
                                            recognitionLevel:VNRequestTextRecognitionLevelAccurate
                               automaticallyDetectsLanguage:YES
                                          configureLanguages:NO
                                                       error:&lastError];
            if (text != nil) {
                recognizedText = text;
                recognizedRevision = VNRecognizeTextRequestRevision3;
            }

            if (recognizedText == nil) {
                text = [self recognizedTextForCGImage:cgImage
                                             revision:VNRecognizeTextRequestRevision3
                                     recognitionLevel:VNRequestTextRecognitionLevelAccurate
                        automaticallyDetectsLanguage:NO
                                   configureLanguages:YES
                                                error:&lastError];
                if (text != nil) {
                    recognizedText = text;
                    recognizedRevision = VNRecognizeTextRequestRevision3;
                }
            }
        }

        if (recognizedText == nil) {
            NSString *text = [self recognizedTextForCGImage:cgImage
                                                    revision:VNRecognizeTextRequestRevision2
                                            recognitionLevel:VNRequestTextRecognitionLevelAccurate
                               automaticallyDetectsLanguage:NO
                                          configureLanguages:YES
                                                       error:&lastError];
            if (text != nil) {
                recognizedText = text;
                recognizedRevision = VNRecognizeTextRequestRevision2;
            }
        }

        if (recognizedText == nil) {
            if (@available(iOS 16.0, *)) {
                NSString *text = [self recognizedTextForCGImage:cgImage
                                                        revision:VNRecognizeTextRequestRevision3
                                               recognitionLevel:VNRequestTextRecognitionLevelFast
                                  automaticallyDetectsLanguage:YES
                                             configureLanguages:NO
                                                          error:&lastError];
                if (text != nil) {
                    recognizedText = text;
                    recognizedRevision = VNRecognizeTextRequestRevision3;
                }

                if (recognizedText == nil) {
                    text = [self recognizedTextForCGImage:cgImage
                                                 revision:VNRecognizeTextRequestRevision3
                                        recognitionLevel:VNRequestTextRecognitionLevelFast
                           automaticallyDetectsLanguage:NO
                                      configureLanguages:YES
                                                   error:&lastError];
                    if (text != nil) {
                        recognizedText = text;
                        recognizedRevision = VNRecognizeTextRequestRevision3;
                    }
                }
            }
        }

        if (recognizedText == nil) {
            NSString *text = [self recognizedTextForCGImage:cgImage
                                                    revision:VNRecognizeTextRequestRevision2
                                           recognitionLevel:VNRequestTextRecognitionLevelFast
                              automaticallyDetectsLanguage:NO
                                         configureLanguages:YES
                                                      error:&lastError];
            if (text != nil) {
                recognizedText = text;
                recognizedRevision = VNRecognizeTextRequestRevision2;
            }
        }

        CGImageRelease(cgImage);
        if (recognizedText != nil) {
            if (outRevision) {
                *outRevision = (NSInteger)recognizedRevision;
            }
            return recognizedText;
        }

        if (outError) {
            *outError = lastError ?: [self errorWithCode:3 description:@"Vision text recognition failed without an error."];
        }
        return nil;
    }

    if (outError) {
        *outError = [self errorWithCode:4 description:@"Vision OCR requires iOS 15 or later."];
    }
    return nil;
}

- (NSString *)recognizedTextForCGImage:(CGImageRef)cgImage
                              revision:(NSUInteger)revision
                      recognitionLevel:(VNRequestTextRecognitionLevel)recognitionLevel
         automaticallyDetectsLanguage:(BOOL)automaticallyDetectsLanguage
                    configureLanguages:(BOOL)configureLanguages
                                 error:(NSError **)outError API_AVAILABLE(ios(15.0)) {
    VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] init];
    request.recognitionLevel = recognitionLevel;
    request.usesLanguageCorrection = recognitionLevel == VNRequestTextRecognitionLevelAccurate;
    request.minimumTextHeight = 0.01;
    request.revision = revision;

    if (@available(iOS 16.0, *)) {
        request.automaticallyDetectsLanguage = automaticallyDetectsLanguage;
    }

    if (configureLanguages) {
        [self configurePreferredLanguagesForRequest:request];
    }

    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:cgImage
                                                                            options:@{}];
    NSError *performError = nil;
    BOOL success = [handler performRequests:@[request] error:&performError];
    if (!success) {
        if (outError) {
            *outError = performError;
        }
        return nil;
    }

    return [self joinedTextFromObservations:request.results];
}

- (void)configurePreferredLanguagesForRequest:(VNRecognizeTextRequest *)request API_AVAILABLE(ios(15.0)) {
    NSArray<NSString *> *preferredLanguages = @[@"zh-Hans", @"zh-Hant", @"en-US", @"en"];
    NSError *languageError = nil;
    NSArray<NSString *> *supportedLanguages = [request supportedRecognitionLanguagesAndReturnError:&languageError];
    if (supportedLanguages.count == 0) {
        return;
    }

    NSMutableArray<NSString *> *languages = [NSMutableArray array];
    for (NSString *language in preferredLanguages) {
        if ([supportedLanguages containsObject:language]) {
            [languages addObject:language];
        }
    }
    if (languages.count > 0) {
        request.recognitionLanguages = languages;
    }
}

- (CGImageRef)newPreparedCGImageForImageAtPath:(NSString *)imagePath
                                 thumbnailPath:(NSString *)thumbnailPath
                                         error:(NSError **)outError {
    CGImageRef image = [self newPreparedCGImageFromPath:imagePath];
    if (!image && thumbnailPath.length > 0) {
        image = [self newPreparedCGImageFromPath:thumbnailPath];
    }

    if (!image && outError) {
        *outError = [self errorWithCode:1 description:@"Failed to load image from stored path or thumbnail path."];
    }
    return image;
}

- (CGImageRef)newPreparedCGImageFromPath:(NSString *)path {
    if (path.length == 0) {
        return NULL;
    }

    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!source) {
        return NULL;
    }

    NSDictionary *thumbnailOptions = @{
        (__bridge NSString *)kCGImageSourceShouldCache: @YES,
        (__bridge NSString *)kCGImageSourceShouldAllowFloat: @NO,
        (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @((NSInteger)kPBOCRMaximumImageLongSide)
    };
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source,
                                                          0,
                                                          (__bridge CFDictionaryRef)thumbnailOptions);
    if (!image) {
        NSDictionary *imageOptions = @{
            (__bridge NSString *)kCGImageSourceShouldCache: @YES,
            (__bridge NSString *)kCGImageSourceShouldAllowFloat: @NO
        };
        image = CGImageSourceCreateImageAtIndex(source,
                                                0,
                                                (__bridge CFDictionaryRef)imageOptions);
    }
    CFRelease(source);

    if (!image) {
        return NULL;
    }

    CGImageRef normalizedImage = [self newSRGBCGImageFromImage:image];
    CGImageRelease(image);
    return normalizedImage;
}

- (CGImageRef)newSRGBCGImageFromImage:(CGImageRef)image {
    size_t width = CGImageGetWidth(image);
    size_t height = CGImageGetHeight(image);
    if (width == 0 || height == 0) {
        return NULL;
    }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (!colorSpace) {
        return NULL;
    }

    CGContextRef context = CGBitmapContextCreate(NULL,
                                                 width,
                                                 height,
                                                 8,
                                                 0,
                                                 colorSpace,
                                                 kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(colorSpace);
    if (!context) {
        return NULL;
    }

    CGRect bounds = CGRectMake(0, 0, (CGFloat)width, (CGFloat)height);
    CGContextSetRGBFillColor(context, 1.0, 1.0, 1.0, 1.0);
    CGContextFillRect(context, bounds);
    CGContextDrawImage(context, bounds, image);

    CGImageRef normalizedImage = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return normalizedImage;
}

- (NSString *)joinedTextFromObservations:(NSArray<VNRecognizedTextObservation *> *)observations API_AVAILABLE(ios(13.0)) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (VNRecognizedTextObservation *observation in observations) {
        VNRecognizedText *candidate = [[observation topCandidates:1] firstObject];
        NSString *line = [candidate.string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (line.length > 0) {
            [lines addObject:line];
        }
    }

    return [[lines componentsJoinedByString:@"\n"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (NSError *)errorWithCode:(NSInteger)code description:(NSString *)description {
    return [NSError errorWithDomain:kPBOCRErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description ?: @"OCR failed."}];
}

- (NSString *)summaryForError:(NSError *)error {
    if (!error) {
        return @"";
    }

    return [NSString stringWithFormat:@"%@:%ld %@",
                                      error.domain ?: @"",
                                      (long)error.code,
                                      error.localizedDescription ?: @""];
}

@end
