#import <UIKit/UIKit.h>
#import "../Model/PBClipboardItem.h"

@class PBSnippetCollectionCell;

@protocol PBSnippetCollectionCellDelegate <NSObject>
- (void)snippetCellDidTapPin:(PBSnippetCollectionCell *)cell;
- (void)snippetCellDidTapFavorite:(PBSnippetCollectionCell *)cell;
- (void)snippetCellDidTapDelete:(PBSnippetCollectionCell *)cell;
@end

@interface PBSnippetCollectionCell : UICollectionViewCell

@property (nonatomic, strong) PBClipboardItem *item;
@property (nonatomic, weak) id<PBSnippetCollectionCellDelegate> delegate;

- (void)setUsesVerticalLayout:(BOOL)usesVerticalLayout;
- (void)configureWithItem:(PBClipboardItem *)item;

@end
