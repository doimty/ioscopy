#import <Foundation/Foundation.h>
#import "../Model/PBClipboardItem.h"

@interface PBImageOCRIndexer : NSObject

+ (instancetype)sharedIndexer;

- (void)enqueueImageItem:(PBClipboardItem *)item;
- (void)enqueuePendingImageIndexingWithLimit:(NSInteger)limit;
- (void)enqueuePendingImageIndexingWithLimit:(NSInteger)limit retryFailed:(BOOL)retryFailed;
- (NSInteger)processPendingImageIndexingWithLimit:(NSInteger)limit retryFailed:(BOOL)retryFailed;

@end
