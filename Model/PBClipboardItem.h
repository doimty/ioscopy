#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, PBContentType) {
    PBContentTypeText = 0,
    PBContentTypeImage = 1,
    PBContentTypeURL = 2,
    PBContentTypeOther = 3
};

typedef NS_ENUM(NSInteger, PBOCRStatus) {
    PBOCRStatusPending = 0,
    PBOCRStatusIndexed = 1,
    PBOCRStatusFailed = 2
};

@interface PBClipboardItem : NSObject

@property (nonatomic, assign) NSInteger itemId;
@property (nonatomic, copy) NSString *content;
@property (nonatomic, assign) PBContentType contentType;
@property (nonatomic, copy) NSString *sourceBundleId;
@property (nonatomic, copy) NSString *sourceAppName;
@property (nonatomic, assign) NSTimeInterval timestamp;
@property (nonatomic, assign) BOOL isPinned;
@property (nonatomic, assign) BOOL isFavorite;
@property (nonatomic, copy) NSString *thumbnailPath;
@property (nonatomic, assign) NSInteger dataSize;
@property (nonatomic, copy) NSString *ocrText;
@property (nonatomic, copy) NSString *ocrError;
@property (nonatomic, assign) PBOCRStatus ocrStatus;
@property (nonatomic, assign) NSInteger ocrRevision;
@property (nonatomic, assign) NSTimeInterval ocrUpdatedAt;

+ (instancetype)itemWithContent:(NSString *)content
                    contentType:(PBContentType)contentType
                 sourceBundleId:(NSString *)bundleId
                  sourceAppName:(NSString *)appName;

- (NSString *)relativeTimeString;
- (NSString *)contentPreview;
- (NSString *)contentTypeIcon;

@end
