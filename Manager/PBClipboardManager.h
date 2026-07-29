#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "../Model/PBClipboardItem.h"

extern NSString * const PBClipboardManagerDidUpdateNotification;

@interface PBClipboardManager : NSObject

@property (nonatomic, strong, readonly) NSArray<PBClipboardItem *> *currentItems;
@property (nonatomic, assign) BOOL isEnabled;
@property (nonatomic, assign) NSInteger maxItemCount;

+ (instancetype)sharedManager;

- (void)startMonitoring;
- (void)stopMonitoring;
- (void)refreshItems;
- (void)recordCapturedPasteboardContent:(NSString *)content
                              imageData:(NSData *)imageData
                             sourceInfo:(NSDictionary *)sourceInfo
                            changeCount:(NSInteger)changeCount;

// Actions
- (void)copyItemToPasteboard:(PBClipboardItem *)item;
- (void)copyItemToPasteboard:(PBClipboardItem *)item completion:(void (^)(BOOL success))completion;
- (NSData *)imageDataForItem:(PBClipboardItem *)item;
- (void)deleteItem:(PBClipboardItem *)item;
- (void)togglePinItem:(PBClipboardItem *)item;
- (void)toggleFavoriteItem:(PBClipboardItem *)item;
- (void)deleteAllItems;

// Search
- (NSArray<PBClipboardItem *> *)searchWithQuery:(NSString *)query;

// Settings
- (void)loadPreferences;

@end
