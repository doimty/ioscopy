#import <UIKit/UIKit.h>

@interface PBMainViewController : UIViewController

+ (instancetype)sharedInstance;
- (void)showAnimated:(BOOL)animated;
- (void)dismissAnimated:(BOOL)animated;
@property (nonatomic, assign, readonly) BOOL isPresented;

@end
