#import <UIKit/UIKit.h>
#import "../Model/PBClipboardItem.h"

@interface PBAppIconProvider : NSObject

+ (instancetype)sharedProvider;

- (UIImage *)iconForItem:(PBClipboardItem *)item preferredSize:(CGFloat)preferredSize;
- (void)loadIconForItem:(PBClipboardItem *)item
          preferredSize:(CGFloat)preferredSize
             completion:(void (^)(UIImage *icon))completion;

- (UIImage *)iconForBundleId:(NSString *)bundleId
                     appName:(NSString *)appName
                 contentType:(PBContentType)contentType
                preferredSize:(CGFloat)preferredSize;

@end
