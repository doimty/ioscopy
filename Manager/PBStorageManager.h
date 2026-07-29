#import <Foundation/Foundation.h>
#import "../Model/PBClipboardItem.h"

@interface PBStorageManager : NSObject

+ (instancetype)sharedManager;

// CRUD
- (BOOL)saveItem:(PBClipboardItem *)item;
- (NSArray<PBClipboardItem *> *)allItemsWithLimit:(NSInteger)limit;
- (NSArray<PBClipboardItem *> *)searchItemsWithQuery:(NSString *)query limit:(NSInteger)limit;
- (NSArray<PBClipboardItem *> *)searchItemsWithQuery:(NSString *)query
                                               limit:(NSInteger)limit
                                          includeOCR:(BOOL)includeOCR;
- (NSArray<PBClipboardItem *> *)imageItemsNeedingOCRWithLimit:(NSInteger)limit;
- (NSArray<PBClipboardItem *> *)imageItemsNeedingOCRWithLimit:(NSInteger)limit
                                                  includeFailed:(BOOL)includeFailed;
- (BOOL)updateOCRText:(NSString *)text
               status:(PBOCRStatus)status
             revision:(NSInteger)revision
                error:(NSString *)error
            forItemId:(NSInteger)itemId;
- (NSArray<PBClipboardItem *> *)pinnedItems;
- (NSArray<PBClipboardItem *> *)favoriteItems;
- (BOOL)deleteItem:(PBClipboardItem *)item;
- (BOOL)deleteAllItems;
- (BOOL)togglePinForItem:(PBClipboardItem *)item;
- (BOOL)toggleFavoriteForItem:(PBClipboardItem *)item;

// Maintenance
- (void)cleanupOldItemsWithMaxCount:(NSInteger)maxCount;
- (void)cleanupItemsOlderThanDays:(NSInteger)days;
- (NSInteger)totalItemCount;
- (BOOL)isDuplicateContent:(NSString *)content;
- (BOOL)getLatestItemType:(PBContentType *)outType size:(NSInteger *)outSize content:(NSString **)outContent;

@end
