#import "PBMainViewController.h"
#import "PBSnippetCollectionCell.h"
#import "../Manager/PBClipboardManager.h"
#import "../Manager/PBStorageManager.h"
#import "../Manager/PBInputBridge.h"
#import "../Shared/PBLocalization.h"
#import "../Shared/PBDiagnosticLogger.h"
#import "../Shared/PBPathUtilities.h"
#import "../Shared/PBPreferenceKeys.h"
#import <QuartzCore/QuartzCore.h>
#import <rootless.h>
#import <math.h>

static NSString * const kCellIdentifier = @"PBSnippetCollectionCell";
static CFStringRef const kPBPreferencesChangedNotification = CFSTR("com.ssdsl.ioscopy/prefschanged");
static CFStringRef const kPBOverlayPresentedNotification = CFSTR("com.ssdsl.ioscopy/overlayPresented");
static CFStringRef const kPBOverlayDismissedNotification = CFSTR("com.ssdsl.ioscopy/overlayDismissed");
static NSString * const kPBiOSCopySearchAccessibilityIdentifier = @"com.ssdsl.ioscopy.searchBar";
static CGFloat const kPBKeyboardContainerOverlap = 2.0;
static CGFloat const kPBKeyboardTopPadding = 8.0;
static CGFloat const kPBEstimatedKeyboardHeightRatio = 0.43;
static CGFloat const kPBEstimatedKeyboardMinHeight = 300.0;
static CGFloat const kPBEstimatedKeyboardMaxHeight = 402.0;
static NSTimeInterval const kPBSearchPasteDelayAfterDismiss = 0.18;
static NSTimeInterval const kPBSearchDebounceInterval = 0.20;
static CGFloat const kPBSnippetVerticalHorizontalInset = 12.0;
static CGFloat const kPBSnippetVerticalLineSpacing = 4.0;
static CGFloat const kPBSnippetVerticalItemHeight = 64.0;

static NSString *PBPreferencesPath(void) {
    return PBIOSCopyMainPreferencesPath();
}

static BOOL PBPreferenceBool(NSString *key, BOOL defaultValue) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:PBPreferencesPath()];
    id value = [prefs isKindOfClass:[NSDictionary class]] ? prefs[key] : nil;
    return value ? [value boolValue] : defaultValue;
}

static BOOL PBMainFeatureEnabled(void) {
    return PBPreferenceBool(kPBPreferenceEnabled, YES);
}

static BOOL PBTextPasteCompatibilityModeEnabled(void) {
    return PBPreferenceBool(kPBPreferenceTextPasteCompatibilityMode, NO);
}

static BOOL PBVerticalLayoutEnabled(void) {
    return PBPreferenceBool(kPBPreferenceVerticalLayoutEnabled, NO);
}

static BOOL PBAutoCloseEnabled(void) {
    return PBPreferenceBool(kPBPreferenceAutoClose, YES);
}

static BOOL PBHapticFeedbackEnabled(void) {
    return PBPreferenceBool(kPBPreferenceHapticFeedback, YES);
}

static void PBPerformImpactFeedback(UIImpactFeedbackStyle style) {
    if (!PBHapticFeedbackEnabled()) {
        return;
    }

    UIImpactFeedbackGenerator *feedback =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:style];
    [feedback impactOccurred];
}

static void PBPerformSelectionFeedback(void) {
    if (!PBHapticFeedbackEnabled()) {
        return;
    }

    UISelectionFeedbackGenerator *feedback =
        [[UISelectionFeedbackGenerator alloc] init];
    [feedback selectionChanged];
}

static void PBPostOverlayStateNotification(BOOL presented) {
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        presented ? kPBOverlayPresentedNotification : kPBOverlayDismissedNotification,
        NULL,
        NULL,
        YES
    );
}

@interface PBMainViewController () <UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout,
                                     PBSnippetCollectionCellDelegate,
                                     UISearchBarDelegate, UIGestureRecognizerDelegate>

@property (nonatomic, weak) UIViewController *embeddedHostViewController;
@property (nonatomic, weak) UIView *embeddedHostView;
@property (nonatomic, assign) BOOL isEmbeddedInHostView;
@property (nonatomic, strong) UIWindow *overlayWindow;
@property (nonatomic, weak) UIWindow *previousKeyWindow;
@property (nonatomic, assign) CGSize lastLayoutBoundsSize;
@property (nonatomic, assign) UIInterfaceOrientation appliedOverlayOrientation;
@property (nonatomic, strong) UIView *backgroundView;
@property (nonatomic, strong) UIView *containerView;
@property (nonatomic, strong) UIView *containerBackgroundView;
@property (nonatomic, strong) UIView *headerView;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UIButton *cancelButton;
@property (nonatomic, strong) UILabel *snippetCountLabel;
@property (nonatomic, strong) UISegmentedControl *filterSegment;
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) UIView *handleBar;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UIPanGestureRecognizer *dismissPanGestureRecognizer;
@property (nonatomic, strong) UILongPressGestureRecognizer *imagePreviewLongPressGestureRecognizer;
@property (nonatomic, strong) UIView *imagePreviewOverlayView;
@property (nonatomic, strong) NSTimer *foregroundTargetMonitorTimer;
@property (nonatomic, strong) NSTimer *searchUpdateTimer;
@property (nonatomic, strong) dispatch_queue_t displayQueryQueue;
@property (nonatomic, strong) dispatch_queue_t imagePreviewQueue;

@property (nonatomic, strong) NSArray<PBClipboardItem *> *displayItems;
@property (nonatomic, assign) BOOL isPresented;
@property (nonatomic, assign) BOOL isDismissing;
@property (nonatomic, assign) BOOL isSearchEditing;
@property (nonatomic, assign) BOOL didUseSearchInCurrentPresentation;
@property (nonatomic, assign) BOOL isKeyboardVisible;
@property (nonatomic, assign) BOOL isKeyboardAttachedStyleActive;
@property (nonatomic, assign) CGRect keyboardFrameInView;
@property (nonatomic, assign) NSInteger currentFilter; // 0=All, 1=Pinned, 2=Favorites
@property (nonatomic, assign) BOOL usesVerticalSnippetLayout;
@property (nonatomic, strong) NSDictionary *activeTargetInfo;
@property (nonatomic, assign) NSUInteger displayQueryGeneration;
@property (nonatomic, assign) NSUInteger imagePreviewGeneration;

- (void)preferencesDidChange;

#if DEBUG_LOG
@property (nonatomic, strong) CADisplayLink *frameRateDisplayLink;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *recentMainThreadOperations;
@property (nonatomic, assign) CFTimeInterval frameRateLastTimestamp;
@property (nonatomic, assign) CFTimeInterval frameRateWindowStartTimestamp;
@property (nonatomic, assign) NSUInteger frameRateWindowIndex;
@property (nonatomic, assign) NSUInteger frameRateSampleCount;
@property (nonatomic, assign) NSTimeInterval frameRateTotalInterval;
@property (nonatomic, assign) NSTimeInterval frameRateMinInterval;
@property (nonatomic, assign) NSTimeInterval frameRateMaxInterval;
@property (nonatomic, assign) NSUInteger frameRateBelow100Count;
@property (nonatomic, assign) NSUInteger frameRateBelow80Count;
@property (nonatomic, assign) NSUInteger frameRateBelow65Count;
@property (nonatomic, assign) NSUInteger frameRateBelow50Count;
@property (nonatomic, assign) BOOL isCollectionViewTrackingFrameRate;
@property (nonatomic, assign) CFTimeInterval scrollCallbackWindowStartTimestamp;
@property (nonatomic, assign) CFTimeInterval scrollCallbackLastTimestamp;
@property (nonatomic, assign) NSUInteger scrollCallbackWindowIndex;
@property (nonatomic, assign) NSUInteger scrollCallbackCount;
@property (nonatomic, assign) NSUInteger scrollCallbackIntervalCount;
@property (nonatomic, assign) NSTimeInterval scrollCallbackTotalInterval;
@property (nonatomic, assign) NSTimeInterval scrollCallbackMinInterval;
@property (nonatomic, assign) NSTimeInterval scrollCallbackMaxInterval;
@property (nonatomic, assign) CGPoint scrollCallbackWindowStartOffset;
@property (nonatomic, assign) CGPoint scrollCallbackLastContentOffset;
@property (nonatomic, assign) CGFloat scrollCallbackTravelDistance;
@property (nonatomic, assign) BOOL scrollCallbackDidRecordFirstCallback;
@property (nonatomic, assign) NSTimeInterval scrollCallbackFirstLatency;
@property (nonatomic, assign) CGFloat scrollCallbackFirstDelta;
#endif

@end

static void PBMainPreferencesChanged(CFNotificationCenterRef center,
                                     void *observer,
                                     CFNotificationName name,
                                     const void *object,
                                     CFDictionaryRef userInfo) {
    PBMainViewController *controller = (__bridge PBMainViewController *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        [controller preferencesDidChange];
    });
}

@implementation PBMainViewController

+ (instancetype)sharedInstance {
    static PBMainViewController *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[PBMainViewController alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _displayItems = @[];
        _displayQueryQueue = dispatch_queue_create("com.ssdsl.ioscopy.display-query", DISPATCH_QUEUE_SERIAL);
        _imagePreviewQueue = dispatch_queue_create("com.ssdsl.ioscopy.image-preview", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.currentFilter = 0;
    self.usesVerticalSnippetLayout = PBVerticalLayoutEnabled();
    [self setupOverlayUI];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(clipboardDidUpdate)
                                                 name:PBClipboardManagerDidUpdateNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillChangeFrame:)
                                                 name:UIKeyboardWillChangeFrameNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillChangeFrame:)
                                                 name:UIKeyboardDidChangeFrameNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillChangeFrame:)
                                                 name:UIKeyboardDidShowNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillHide:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillHide:)
                                                 name:UIKeyboardDidHideNotification
                                               object:nil];
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(presentationOrientationDidChange:)
                                                 name:UIDeviceOrientationDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(presentationOrientationDidChange:)
                                                 name:UIApplicationDidChangeStatusBarOrientationNotification
                                               object:nil];
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    (__bridge const void *)(self),
                                    PBMainPreferencesChanged,
                                    kPBPreferencesChangedNotification,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGSize boundsSize = self.view.bounds.size;
    if (CGSizeEqualToSize(boundsSize, self.lastLayoutBoundsSize)) {
        return;
    }
    self.lastLayoutBoundsSize = boundsSize;

    if (!self.isPresented || self.isDismissing || CGRectIsEmpty(self.view.bounds)) {
        return;
    }

    [UIView performWithoutAnimation:^{
        CGRect targetFrame = [self targetContainerFrame];
        self.containerView.frame = targetFrame;
        [self updateContainerLayoutForFrame:targetFrame];
    }];
}

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    switch (self.appliedOverlayOrientation) {
        case UIInterfaceOrientationPortrait:
            return UIInterfaceOrientationMaskPortrait;
        case UIInterfaceOrientationPortraitUpsideDown:
            return UIInterfaceOrientationMaskPortraitUpsideDown;
        case UIInterfaceOrientationLandscapeLeft:
            return UIInterfaceOrientationMaskLandscapeLeft;
        case UIInterfaceOrientationLandscapeRight:
            return UIInterfaceOrientationMaskLandscapeRight;
        case UIInterfaceOrientationUnknown:
        default:
            return UIInterfaceOrientationMaskAll;
    }
}

- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
    if ([self isValidInterfaceOrientation:self.appliedOverlayOrientation]) {
        return self.appliedOverlayOrientation;
    }
    return UIInterfaceOrientationPortrait;
}

- (void)dealloc {
#if DEBUG_LOG
    [self.frameRateDisplayLink invalidate];
    self.frameRateDisplayLink = nil;
#endif
    [self.searchUpdateTimer invalidate];
    self.searchUpdateTimer = nil;
    self.displayQueryGeneration += 1;
    self.imagePreviewGeneration += 1;
    [self stopForegroundTargetMonitor];
    [[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                       (__bridge const void *)(self),
                                       kPBPreferencesChangedNotification,
                                       NULL);
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - UI Setup

- (BOOL)isValidInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return orientation >= UIInterfaceOrientationPortrait &&
           orientation <= UIInterfaceOrientationLandscapeRight;
}

- (UIInterfaceOrientation)activePresentationOrientation {
    UIApplication *application = [UIApplication sharedApplication];
    NSArray<NSString *> *selectorNames = @[
        @"_frontMostAppOrientation",
        @"activeInterfaceOrientationWithoutConsideringAlerts",
        @"activeInterfaceOrientation",
        @"statusBarOrientation"
    ];

    for (NSString *selectorName in selectorNames) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![application respondsToSelector:selector]) {
            continue;
        }

        @try {
            NSInteger (*orientationGetter)(id, SEL) =
                (NSInteger (*)(id, SEL))[application methodForSelector:selector];
            UIInterfaceOrientation orientation =
                (UIInterfaceOrientation)orientationGetter(application, selector);
            if ([self isValidInterfaceOrientation:orientation]) {
                return orientation;
            }
        } @catch (__unused NSException *exception) {
        }
    }

    UIDeviceOrientation deviceOrientation = [UIDevice currentDevice].orientation;
    switch (deviceOrientation) {
        case UIDeviceOrientationPortrait:
            return UIInterfaceOrientationPortrait;
        case UIDeviceOrientationPortraitUpsideDown:
            return UIInterfaceOrientationPortraitUpsideDown;
        case UIDeviceOrientationLandscapeLeft:
            return UIInterfaceOrientationLandscapeRight;
        case UIDeviceOrientationLandscapeRight:
            return UIInterfaceOrientationLandscapeLeft;
        default:
            break;
    }

    UIWindowScene *windowScene = self.overlayWindow.windowScene;
    if (@available(iOS 13.0, *)) {
        UIInterfaceOrientation sceneOrientation = windowScene.interfaceOrientation;
        if ([self isValidInterfaceOrientation:sceneOrientation]) {
            return sceneOrientation;
        }
    }

    return UIInterfaceOrientationPortrait;
}

- (void)applyOverlayOrientation:(UIInterfaceOrientation)orientation animated:(BOOL)animated {
    UIWindow *overlayWindow = self.overlayWindow;
    if (!overlayWindow || ![self isValidInterfaceOrientation:orientation]) {
        return;
    }

    self.appliedOverlayOrientation = orientation;
    if (@available(iOS 16.0, *)) {
        [self setNeedsUpdateOfSupportedInterfaceOrientations];
    } else {
        [UIViewController attemptRotationToDeviceOrientation];
    }

    SEL updateSelector = NSSelectorFromString(@"_updateToInterfaceOrientation:duration:force:");
    if ([overlayWindow respondsToSelector:updateSelector]) {
        @try {
            void (*updateOrientation)(id, SEL, UIInterfaceOrientation, NSTimeInterval, BOOL) =
                (void (*)(id, SEL, UIInterfaceOrientation, NSTimeInterval, BOOL))
                    [overlayWindow methodForSelector:updateSelector];
            updateOrientation(overlayWindow,
                              updateSelector,
                              orientation,
                              animated ? 0.25 : 0.0,
                              YES);
        } @catch (__unused NSException *exception) {
        }
    }

    self.view.frame = overlayWindow.bounds;

    self.lastLayoutBoundsSize = CGSizeZero;
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
}

- (void)presentationOrientationDidChange:(NSNotification *)notification {
    (void)notification;
    if (!self.isPresented || self.isDismissing || !self.overlayWindow) {
        return;
    }

    UIInterfaceOrientation orientation = [self activePresentationOrientation];
    if (orientation == self.appliedOverlayOrientation) {
        return;
    }
    [self applyOverlayOrientation:orientation animated:YES];
}

- (BOOL)windowLooksLikeKeyboardWindow:(UIWindow *)window {
    if (!window || window == self.overlayWindow || window.hidden || window.alpha < 0.01) {
        return NO;
    }

    NSString *className = NSStringFromClass([window class]) ?: @"";
    return [className rangeOfString:@"Keyboard" options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [className rangeOfString:@"TextEffects" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

- (UIWindow *)foregroundHostWindowForEmbedding {
    UIApplication *application = [UIApplication sharedApplication];
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in application.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }

            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (windowScene.activationState != UISceneActivationStateForegroundActive) {
                continue;
            }

            [windows addObjectsFromArray:windowScene.windows];
        }
    }

    [windows addObjectsFromArray:application.windows];

    CGRect screenBounds = [UIScreen mainScreen].bounds;
    CGFloat screenArea = CGRectGetWidth(screenBounds) * CGRectGetHeight(screenBounds);
    CGFloat minimumArea = screenArea * 0.12;
    UIWindow *bestWindow = nil;
    CGFloat bestArea = 0.0;

    for (UIWindow *window in windows) {
        if (!window ||
            window.hidden ||
            window.alpha < 0.01 ||
            !window.userInteractionEnabled ||
            !window.rootViewController ||
            [self windowLooksLikeKeyboardWindow:window]) {
            continue;
        }

        CGRect windowBounds = window.bounds;
        CGFloat area = CGRectGetWidth(windowBounds) * CGRectGetHeight(windowBounds);
        if (area < minimumArea) {
            continue;
        }

        if (!bestWindow) {
            bestWindow = window;
            bestArea = area;
            continue;
        }

        BOOL windowIsHigherLevel = window.windowLevel > bestWindow.windowLevel;
        BOOL windowIsSameLevel = fabs(window.windowLevel - bestWindow.windowLevel) < 0.01;
        BOOL windowIsBetterKeyWindow = windowIsSameLevel && window.isKeyWindow && !bestWindow.isKeyWindow;
        BOOL windowIsLargerAtSamePriority = windowIsSameLevel &&
                                            window.isKeyWindow == bestWindow.isKeyWindow &&
                                            area > bestArea;
        if (windowIsHigherLevel || windowIsBetterKeyWindow || windowIsLargerAtSamePriority) {
            bestWindow = window;
            bestArea = area;
        }
    }

    return bestWindow;
}

- (BOOL)attachToExistingSpringBoardHierarchy {
    UIWindow *hostWindow = [self foregroundHostWindowForEmbedding];
    if (!hostWindow) {
        return NO;
    }
    UIInterfaceOrientation presentationOrientation = [self activePresentationOrientation];

    UIWindowScene *windowScene = nil;
    if (@available(iOS 13.0, *)) {
        windowScene = hostWindow.windowScene;
    }

    UIWindow *overlayWindow = nil;
    if (windowScene) {
        overlayWindow = [[UIWindow alloc] initWithWindowScene:windowScene];
        overlayWindow.frame = windowScene.coordinateSpace.bounds;
    } else {
        overlayWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    }

    self.previousKeyWindow = hostWindow.isKeyWindow ? hostWindow : nil;
    if (!self.previousKeyWindow) {
        for (UIWindow *window in [UIApplication sharedApplication].windows) {
            if (window.isKeyWindow && window != overlayWindow) {
                self.previousKeyWindow = window;
                break;
            }
        }
    }

    overlayWindow.windowLevel = MAX(UIWindowLevelAlert + 1.0, hostWindow.windowLevel + 1.0);
    overlayWindow.backgroundColor = [UIColor clearColor];
    self.appliedOverlayOrientation = presentationOrientation;
    overlayWindow.rootViewController = self;
    self.overlayWindow = overlayWindow;
    self.embeddedHostViewController = hostWindow.rootViewController;
    self.embeddedHostView = overlayWindow;
    self.isEmbeddedInHostView = YES;

    [overlayWindow makeKeyAndVisible];
    self.view.frame = overlayWindow.bounds;
    self.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.view.hidden = NO;
    [self applyOverlayOrientation:presentationOrientation animated:NO];

    for (NSNumber *delayNumber in @[@0.05, @0.20]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delayNumber.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!self.isPresented || self.isDismissing || self.overlayWindow != overlayWindow) {
                return;
            }
            [self applyOverlayOrientation:[self activePresentationOrientation] animated:NO];
        });
    }

#if DEBUG_LOG
    UIViewController *hostViewController = hostWindow.rootViewController;
    [self recordFrameRateDiagnosticPhase:@"embedded-host-attached"
                                 details:@{
        @"hostWindowClass": NSStringFromClass([hostWindow class]) ?: @"",
        @"hostWindowLevel": @(hostWindow.windowLevel),
        @"hostWindowKey": @(hostWindow.isKeyWindow),
        @"hostRootClass": NSStringFromClass([hostViewController class]) ?: @"",
        @"overlayWindowLevel": @(overlayWindow.windowLevel),
        @"overlayBounds": NSStringFromCGRect(overlayWindow.bounds)
    }];
#endif

    return YES;
}

- (void)detachFromExistingSpringBoardHierarchy {
    if (!self.isEmbeddedInHostView) {
        return;
    }

    UIWindow *overlayWindow = self.overlayWindow;
    UIWindow *previousKeyWindow = self.previousKeyWindow;
    if (overlayWindow) {
        overlayWindow.hidden = YES;
        overlayWindow.rootViewController = nil;
        self.overlayWindow = nil;
    } else {
        if (self.parentViewController) {
            [self willMoveToParentViewController:nil];
        }
        [self.view removeFromSuperview];
        if (self.parentViewController) {
            [self removeFromParentViewController];
        }
    }

    if (previousKeyWindow && !previousKeyWindow.hidden) {
        [previousKeyWindow makeKeyWindow];
    }
    self.previousKeyWindow = nil;
    self.embeddedHostViewController = nil;
    self.embeddedHostView = nil;
    self.isEmbeddedInHostView = NO;
    self.lastLayoutBoundsSize = CGSizeZero;
    self.appliedOverlayOrientation = UIInterfaceOrientationUnknown;
}

- (CGRect)presentationBounds {
    CGRect bounds = self.view.bounds;
    if (!CGRectIsEmpty(bounds)) {
        return bounds;
    }

    bounds = self.embeddedHostView.bounds;
    if (!CGRectIsEmpty(bounds)) {
        return bounds;
    }

    return [UIScreen mainScreen].bounds;
}

- (CGSize)preferredContainerSize {
    CGRect bounds = [self presentationBounds];
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat availableHeight = CGRectGetHeight(bounds);
    CGFloat height = MIN(MAX(availableHeight * 0.44, 318), 410);
    height = MIN(height, availableHeight);
    return CGSizeMake(width, height);
}

- (CGRect)visibleContainerFrame {
    CGRect bounds = [self presentationBounds];
    CGSize containerSize = [self preferredContainerSize];
    CGFloat y = CGRectGetMaxY(bounds) - containerSize.height;
    return CGRectMake(CGRectGetMinX(bounds), y, containerSize.width, containerSize.height);
}

- (CGRect)hiddenContainerFrame {
    CGRect frame = [self visibleContainerFrame];
    frame.origin.y = CGRectGetMaxY([self presentationBounds]);
    return frame;
}

- (CGFloat)keyboardAdjustedTopLimit {
    CGFloat topInset = 0.0;
    if (@available(iOS 11.0, *)) {
        topInset = self.view.safeAreaInsets.top;
    }
    return topInset + kPBKeyboardTopPadding;
}

- (UIColor *)keyboardChromeColor {
    if (@available(iOS 13.0, *)) {
        return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traitCollection) {
            if (traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
                return [UIColor colorWithWhite:0.17 alpha:1.0];
            }
            return [UIColor colorWithWhite:0.82 alpha:1.0];
        }];
    }

    return [UIColor colorWithWhite:0.82 alpha:1.0];
}

- (void)applyKeyboardAttachedStyle:(BOOL)attached {
    if (self.isKeyboardAttachedStyleActive == attached && self.containerBackgroundView) {
        return;
    }

    self.isKeyboardAttachedStyleActive = attached;
    UIColor *backgroundColor = nil;
    if (attached) {
        backgroundColor = [self keyboardChromeColor];
        self.containerView.layer.borderColor = [[UIColor separatorColor] colorWithAlphaComponent:0.18].CGColor;
        self.handleBar.backgroundColor = [[UIColor labelColor] colorWithAlphaComponent:0.18];
    } else {
        if (@available(iOS 13.0, *)) {
            backgroundColor = [UIColor systemGroupedBackgroundColor];
        } else {
            backgroundColor = [UIColor groupTableViewBackgroundColor];
        }
        self.containerView.layer.borderColor = [[UIColor separatorColor] colorWithAlphaComponent:0.3].CGColor;
        self.handleBar.backgroundColor = [[UIColor labelColor] colorWithAlphaComponent:0.2];
    }
    self.containerBackgroundView.backgroundColor = backgroundColor;
    self.containerView.backgroundColor = backgroundColor;
}

- (BOOL)viewTreeContainsFirstResponder:(UIView *)view {
    if (view.isFirstResponder) {
        return YES;
    }

    for (UIView *subview in view.subviews) {
        if ([self viewTreeContainsFirstResponder:subview]) {
            return YES;
        }
    }

    return NO;
}

- (BOOL)searchInputIsFirstResponder {
    return self.searchBar && [self viewTreeContainsFirstResponder:self.searchBar];
}

#if DEBUG_LOG
- (void)recordSearchDiagnosticPhase:(NSString *)phase details:(NSDictionary *)details {
    if (phase.length == 0) {
        return;
    }

    NSMutableDictionary *event = [NSMutableDictionary dictionary];
    event[@"phase"] = phase;
    event[@"timestamp"] = @([[NSDate date] timeIntervalSince1970]);
    event[@"isPresented"] = @(self.isPresented);
    event[@"isDismissing"] = @(self.isDismissing);
    event[@"isSearchEditing"] = @(self.isSearchEditing);
    event[@"searchInputFirstResponder"] = @([self searchInputIsFirstResponder]);
    event[@"isKeyboardVisible"] = @(self.isKeyboardVisible);
    event[@"keyboardFrame"] = NSStringFromCGRect(self.keyboardFrameInView);
    event[@"containerFrame"] = NSStringFromCGRect(self.containerView.frame);
    event[@"searchTextLength"] = @(self.searchBar.text.length);
    event[@"presentationMode"] = self.isEmbeddedInHostView ? @"embedded" : @"detached";

    if (self.embeddedHostView.window) {
        event[@"hostWindowClass"] = NSStringFromClass([self.embeddedHostView.window class]) ?: @"";
        event[@"hostWindowLevel"] = @(self.embeddedHostView.window.windowLevel);
        event[@"hostWindowKey"] = @(self.embeddedHostView.window.isKeyWindow);
    }

    if (details.count > 0) {
        event[@"details"] = details;
    }

    NSDictionary *eventSnapshot = [event copy];
    PBDiagnosticAppendEvent(PBDiagnosticStreamSearch, eventSnapshot);

    if ([phase isEqualToString:@"search-begin"] ||
        [phase isEqualToString:@"search-end"] ||
        [phase isEqualToString:@"keyboard-change"] ||
        [phase isEqualToString:@"keyboard-hide"]) {
        [self appendFrameRateDiagnosticEvent:eventSnapshot];
    }
}

- (void)appendFrameRateDiagnosticEvent:(NSDictionary *)event {
    if (event.count == 0) {
        return;
    }

    PBDiagnosticAppendEvent(PBDiagnosticStreamFrameRate, event);
}

- (NSMutableDictionary *)baseFrameRateDiagnosticEventWithPhase:(NSString *)phase {
    NSMutableDictionary *event = [NSMutableDictionary dictionary];
    event[@"phase"] = phase ?: @"";
    event[@"timestamp"] = @([[NSDate date] timeIntervalSince1970]);
    event[@"isPresented"] = @(self.isPresented);
    event[@"isDismissing"] = @(self.isDismissing);
    event[@"isSearchEditing"] = @(self.isSearchEditing);
    event[@"isKeyboardVisible"] = @(self.isKeyboardVisible);
    event[@"isScrolling"] = @(self.isCollectionViewTrackingFrameRate);
    event[@"presentationMode"] = self.isEmbeddedInHostView ? @"embedded" : @"detached";
    event[@"runLoopMode"] = [NSRunLoop currentRunLoop].currentMode ?: @"";
    event[@"screenMaximumFPS"] = @([UIScreen mainScreen].maximumFramesPerSecond);
    event[@"displayItemCount"] = @(self.displayItems.count);
    event[@"collectionBounds"] = NSStringFromCGRect(self.collectionView.bounds);
    event[@"collectionContentOffset"] = NSStringFromCGPoint(self.collectionView.contentOffset);
    event[@"collectionContentSize"] = NSStringFromCGSize(self.collectionView.contentSize);

    if (self.activeTargetInfo.count > 0) {
        event[@"targetBundleId"] = self.activeTargetInfo[@"targetBundleId"] ?: @"";
        event[@"targetAppName"] = self.activeTargetInfo[@"targetAppName"] ?: @"";
    }

    if (self.embeddedHostView.window) {
        event[@"hostWindowClass"] = NSStringFromClass([self.embeddedHostView.window class]) ?: @"";
        event[@"hostWindowLevel"] = @(self.embeddedHostView.window.windowLevel);
        event[@"hostWindowKey"] = @(self.embeddedHostView.window.isKeyWindow);
    }

    return event;
}

- (void)resetFrameRateDiagnosticWindowAtTimestamp:(CFTimeInterval)timestamp {
    self.frameRateWindowStartTimestamp = timestamp;
    self.frameRateSampleCount = 0;
    self.frameRateTotalInterval = 0.0;
    self.frameRateMinInterval = DBL_MAX;
    self.frameRateMaxInterval = 0.0;
    self.frameRateBelow100Count = 0;
    self.frameRateBelow80Count = 0;
    self.frameRateBelow65Count = 0;
    self.frameRateBelow50Count = 0;
}

- (void)recordFrameRateDiagnosticSummaryWithReason:(NSString *)reason
                                       displayLink:(CADisplayLink *)displayLink {
    NSMutableDictionary *event = [self baseFrameRateDiagnosticEventWithPhase:@"frame-rate-summary"];
    event[@"reason"] = reason ?: @"";
    event[@"windowIndex"] = @(self.frameRateWindowIndex);
    event[@"sampleCount"] = @(self.frameRateSampleCount);

    if (self.frameRateSampleCount > 0) {
        NSTimeInterval averageInterval =
            self.frameRateTotalInterval / (NSTimeInterval)self.frameRateSampleCount;
        event[@"averageFPS"] = @(averageInterval > 0.0 ? 1.0 / averageInterval : 0.0);
        event[@"averageFrameIntervalMs"] = @(averageInterval * 1000.0);
        event[@"maximumFrameIntervalMs"] = @(self.frameRateMaxInterval * 1000.0);
        event[@"minimumFrameIntervalMs"] = @(self.frameRateMinInterval * 1000.0);
        event[@"estimatedLowestFPS"] = @(self.frameRateMaxInterval > 0.0 ? 1.0 / self.frameRateMaxInterval : 0.0);
        event[@"estimatedHighestFPS"] = @(self.frameRateMinInterval > 0.0 ? 1.0 / self.frameRateMinInterval : 0.0);
    }

    event[@"slowerThan100FPSFrames"] = @(self.frameRateBelow100Count);
    event[@"slowerThan80FPSFrames"] = @(self.frameRateBelow80Count);
    event[@"slowerThan65FPSFrames"] = @(self.frameRateBelow65Count);
    event[@"slowerThan50FPSFrames"] = @(self.frameRateBelow50Count);

    if (displayLink) {
        event[@"displayLinkDurationMs"] = @(displayLink.duration * 1000.0);
        if (@available(iOS 15.0, *)) {
            CAFrameRateRange range = displayLink.preferredFrameRateRange;
            event[@"preferredFrameRateRange"] =
                [NSString stringWithFormat:@"min=%.0f max=%.0f preferred=%.0f",
                                           range.minimum,
                                           range.maximum,
                                           range.preferred];
        } else {
            event[@"preferredFramesPerSecond"] = @(displayLink.preferredFramesPerSecond);
        }
    }

    [self appendFrameRateDiagnosticEvent:event];
}

- (void)recordFrameRateDiagnosticPhase:(NSString *)phase details:(NSDictionary *)details {
    NSMutableDictionary *event = [self baseFrameRateDiagnosticEventWithPhase:phase];
    if (details.count > 0) {
        event[@"details"] = details;
    }
    [self appendFrameRateDiagnosticEvent:event];
}

- (NSArray<NSDictionary *> *)recentMainThreadOperationSnapshots {
    if (!self.recentMainThreadOperations) {
        return @[];
    }
    return [self.recentMainThreadOperations copy];
}

- (void)recordMainThreadOperationNamed:(NSString *)name
                             startTime:(CFTimeInterval)startTime
                               details:(NSDictionary *)details {
    if (name.length == 0 || startTime <= 0.0) {
        return;
    }

    NSTimeInterval duration = CACurrentMediaTime() - startTime;
    NSMutableDictionary *operation = [NSMutableDictionary dictionary];
    operation[@"name"] = name;
    operation[@"timestamp"] = @([[NSDate date] timeIntervalSince1970]);
    operation[@"durationMs"] = @(duration * 1000.0);
    operation[@"duringScroll"] = @(self.isCollectionViewTrackingFrameRate);
    operation[@"runLoopMode"] = [NSRunLoop currentRunLoop].currentMode ?: @"";
    operation[@"contentOffset"] = NSStringFromCGPoint(self.collectionView.contentOffset);
    if (details.count > 0) {
        operation[@"details"] = details;
    }

    if (!self.recentMainThreadOperations) {
        self.recentMainThreadOperations = [NSMutableArray array];
    }
    [self.recentMainThreadOperations addObject:[operation copy]];
    while (self.recentMainThreadOperations.count > 24) {
        [self.recentMainThreadOperations removeObjectAtIndex:0];
    }

    if (duration >= 0.008) {
        NSMutableDictionary *event = [self baseFrameRateDiagnosticEventWithPhase:@"main-thread-operation"];
        event[@"operation"] = [operation copy];
        [self appendFrameRateDiagnosticEvent:event];
    }
}

- (void)recordScrollCallbackGapWithInterval:(NSTimeInterval)interval
                             previousOffset:(CGPoint)previousOffset
                              currentOffset:(CGPoint)currentOffset
                                 scrollView:(UIScrollView *)scrollView {
    NSMutableDictionary *event = [self baseFrameRateDiagnosticEventWithPhase:@"scroll-callback-gap"];
    event[@"gapIntervalMs"] = @(interval * 1000.0);
    event[@"previousContentOffset"] = NSStringFromCGPoint(previousOffset);
    event[@"currentContentOffset"] = NSStringFromCGPoint(currentOffset);
    event[@"deltaX"] = @(currentOffset.x - previousOffset.x);
    event[@"deltaY"] = @(currentOffset.y - previousOffset.y);
    event[@"isDragging"] = @(scrollView.isDragging);
    event[@"isDecelerating"] = @(scrollView.isDecelerating);
    event[@"isTracking"] = @(scrollView.isTracking);

    NSMutableArray<NSString *> *visibleIndexPaths = [NSMutableArray array];
    for (NSIndexPath *indexPath in self.collectionView.indexPathsForVisibleItems) {
        [visibleIndexPaths addObject:[NSString stringWithFormat:@"%ld:%ld",
                                      (long)indexPath.section,
                                      (long)indexPath.item]];
    }
    event[@"visibleIndexPaths"] = visibleIndexPaths;
    event[@"recentMainThreadOperations"] = [self recentMainThreadOperationSnapshots];
    [self appendFrameRateDiagnosticEvent:event];
}

- (void)resetScrollCallbackDiagnosticsAtTimestamp:(CFTimeInterval)timestamp
                                    contentOffset:(CGPoint)contentOffset {
    self.scrollCallbackWindowStartTimestamp = timestamp;
    self.scrollCallbackLastTimestamp = timestamp;
    self.scrollCallbackCount = 0;
    self.scrollCallbackIntervalCount = 0;
    self.scrollCallbackTotalInterval = 0.0;
    self.scrollCallbackMinInterval = DBL_MAX;
    self.scrollCallbackMaxInterval = 0.0;
    self.scrollCallbackWindowStartOffset = contentOffset;
    self.scrollCallbackLastContentOffset = contentOffset;
    self.scrollCallbackTravelDistance = 0.0;
    self.scrollCallbackDidRecordFirstCallback = NO;
    self.scrollCallbackFirstLatency = 0.0;
    self.scrollCallbackFirstDelta = 0.0;
}

- (void)clearScrollCallbackDiagnostics {
    self.scrollCallbackWindowStartTimestamp = 0.0;
    self.scrollCallbackLastTimestamp = 0.0;
    self.scrollCallbackCount = 0;
    self.scrollCallbackIntervalCount = 0;
    self.scrollCallbackTotalInterval = 0.0;
    self.scrollCallbackMinInterval = DBL_MAX;
    self.scrollCallbackMaxInterval = 0.0;
    self.scrollCallbackWindowStartOffset = CGPointZero;
    self.scrollCallbackLastContentOffset = CGPointZero;
    self.scrollCallbackTravelDistance = 0.0;
    self.scrollCallbackDidRecordFirstCallback = NO;
    self.scrollCallbackFirstLatency = 0.0;
    self.scrollCallbackFirstDelta = 0.0;
}

- (void)recordScrollCallbackDiagnosticSummaryWithReason:(NSString *)reason
                                             scrollView:(UIScrollView *)scrollView
                                              timestamp:(CFTimeInterval)timestamp {
    if (self.scrollCallbackWindowStartTimestamp <= 0.0 || self.scrollCallbackCount == 0) {
        return;
    }

    NSTimeInterval duration = timestamp - self.scrollCallbackWindowStartTimestamp;
    if (duration <= 0.0) {
        return;
    }

    NSMutableDictionary *event = [self baseFrameRateDiagnosticEventWithPhase:@"scroll-callback-summary"];
    event[@"reason"] = reason ?: @"";
    event[@"windowIndex"] = @(self.scrollCallbackWindowIndex);
    event[@"callbackCount"] = @(self.scrollCallbackCount);
    event[@"windowDurationMs"] = @(duration * 1000.0);
    event[@"callbackRatePerSecond"] = @((NSTimeInterval)self.scrollCallbackCount / duration);
    event[@"startContentOffset"] = NSStringFromCGPoint(self.scrollCallbackWindowStartOffset);
    event[@"endContentOffset"] = NSStringFromCGPoint(scrollView.contentOffset);
    event[@"travelDistance"] = @(self.scrollCallbackTravelDistance);
    event[@"firstCallbackLatencyMs"] = @(self.scrollCallbackFirstLatency * 1000.0);
    event[@"firstCallbackDelta"] = @(self.scrollCallbackFirstDelta);
    event[@"isDragging"] = @(scrollView.isDragging);
    event[@"isDecelerating"] = @(scrollView.isDecelerating);
    event[@"isTracking"] = @(scrollView.isTracking);

    if (self.scrollCallbackIntervalCount > 0) {
        NSTimeInterval averageInterval =
            self.scrollCallbackTotalInterval / (NSTimeInterval)self.scrollCallbackIntervalCount;
        event[@"intervalCount"] = @(self.scrollCallbackIntervalCount);
        event[@"averageCallbackIntervalMs"] = @(averageInterval * 1000.0);
        event[@"maximumCallbackIntervalMs"] = @(self.scrollCallbackMaxInterval * 1000.0);
        event[@"minimumCallbackIntervalMs"] = @(self.scrollCallbackMinInterval * 1000.0);
        event[@"estimatedLowestCallbackFPS"] =
            @(self.scrollCallbackMaxInterval > 0.0 ? 1.0 / self.scrollCallbackMaxInterval : 0.0);
        event[@"estimatedHighestCallbackFPS"] =
            @(self.scrollCallbackMinInterval > 0.0 ? 1.0 / self.scrollCallbackMinInterval : 0.0);
    }

    [self appendFrameRateDiagnosticEvent:event];
}

- (void)recordScrollCallbackAtTimestamp:(CFTimeInterval)timestamp
                             scrollView:(UIScrollView *)scrollView {
    CGPoint contentOffset = scrollView.contentOffset;
    if (self.scrollCallbackWindowStartTimestamp <= 0.0) {
        [self resetScrollCallbackDiagnosticsAtTimestamp:timestamp contentOffset:contentOffset];
    }

    if (self.scrollCallbackLastTimestamp > 0.0) {
        NSTimeInterval interval = timestamp - self.scrollCallbackLastTimestamp;
        if (interval > 0.0 && interval < 1.0) {
            self.scrollCallbackIntervalCount += 1;
            self.scrollCallbackTotalInterval += interval;
            self.scrollCallbackMinInterval = MIN(self.scrollCallbackMinInterval, interval);
            self.scrollCallbackMaxInterval = MAX(self.scrollCallbackMaxInterval, interval);
            if (interval > 0.025) {
                [self recordScrollCallbackGapWithInterval:interval
                                           previousOffset:self.scrollCallbackLastContentOffset
                                            currentOffset:contentOffset
                                               scrollView:scrollView];
            }
        }
    }

    CGFloat deltaX = contentOffset.x - self.scrollCallbackLastContentOffset.x;
    CGFloat deltaY = contentOffset.y - self.scrollCallbackLastContentOffset.y;
    if (!self.scrollCallbackDidRecordFirstCallback) {
        CGFloat firstDeltaX = contentOffset.x - self.scrollCallbackWindowStartOffset.x;
        CGFloat firstDeltaY = contentOffset.y - self.scrollCallbackWindowStartOffset.y;
        self.scrollCallbackFirstLatency = timestamp - self.scrollCallbackWindowStartTimestamp;
        self.scrollCallbackFirstDelta = hypot(firstDeltaX, firstDeltaY);
        self.scrollCallbackDidRecordFirstCallback = YES;
    }
    self.scrollCallbackTravelDistance += hypot(deltaX, deltaY);
    self.scrollCallbackLastContentOffset = contentOffset;
    self.scrollCallbackLastTimestamp = timestamp;
    self.scrollCallbackCount += 1;

    if (timestamp - self.scrollCallbackWindowStartTimestamp >= 1.0) {
        [self recordScrollCallbackDiagnosticSummaryWithReason:@"window"
                                                   scrollView:scrollView
                                                    timestamp:timestamp];
        self.scrollCallbackWindowIndex += 1;
        [self resetScrollCallbackDiagnosticsAtTimestamp:timestamp contentOffset:contentOffset];
    }
}

- (void)handleFrameRateDisplayLink:(CADisplayLink *)displayLink {
    CFTimeInterval timestamp = displayLink.timestamp;
    if (self.frameRateLastTimestamp <= 0.0) {
        self.frameRateLastTimestamp = timestamp;
        [self resetFrameRateDiagnosticWindowAtTimestamp:timestamp];
        return;
    }

    NSTimeInterval interval = timestamp - self.frameRateLastTimestamp;
    self.frameRateLastTimestamp = timestamp;
    if (interval <= 0.0 || interval > 1.0) {
        return;
    }

    self.frameRateSampleCount += 1;
    self.frameRateTotalInterval += interval;
    self.frameRateMinInterval = MIN(self.frameRateMinInterval, interval);
    self.frameRateMaxInterval = MAX(self.frameRateMaxInterval, interval);

    if (interval > 1.0 / 100.0) {
        self.frameRateBelow100Count += 1;
    }
    if (interval > 1.0 / 80.0) {
        self.frameRateBelow80Count += 1;
    }
    if (interval > 1.0 / 65.0) {
        self.frameRateBelow65Count += 1;
    }
    if (interval > 1.0 / 50.0) {
        self.frameRateBelow50Count += 1;
    }

    if (timestamp - self.frameRateWindowStartTimestamp >= 1.0) {
        [self recordFrameRateDiagnosticSummaryWithReason:@"window"
                                             displayLink:displayLink];
        self.frameRateWindowIndex += 1;
        [self resetFrameRateDiagnosticWindowAtTimestamp:timestamp];
    }
}

- (void)startFrameRateDiagnostics {
    if (self.frameRateDisplayLink) {
        return;
    }

    self.frameRateWindowIndex = 0;
    self.frameRateLastTimestamp = 0.0;
    self.scrollCallbackWindowIndex = 0;
    [self resetFrameRateDiagnosticWindowAtTimestamp:0.0];
    [self clearScrollCallbackDiagnostics];

    CADisplayLink *displayLink =
        [CADisplayLink displayLinkWithTarget:self selector:@selector(handleFrameRateDisplayLink:)];
    NSInteger maximumFPS = MAX([UIScreen mainScreen].maximumFramesPerSecond, 60);
    if (@available(iOS 15.0, *)) {
        displayLink.preferredFrameRateRange =
            CAFrameRateRangeMake((CGFloat)maximumFPS, (CGFloat)maximumFPS, (CGFloat)maximumFPS);
    } else {
        displayLink.preferredFramesPerSecond = maximumFPS;
    }

    [displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    self.frameRateDisplayLink = displayLink;
    [self recordFrameRateDiagnosticPhase:@"frame-rate-start" details:nil];
}

- (void)stopFrameRateDiagnosticsWithReason:(NSString *)reason {
    CADisplayLink *displayLink = self.frameRateDisplayLink;
    if (!displayLink) {
        return;
    }

    [self recordFrameRateDiagnosticSummaryWithReason:reason ?: @"stop"
                                         displayLink:displayLink];
    if (self.scrollCallbackCount > 0) {
        [self recordScrollCallbackDiagnosticSummaryWithReason:reason ?: @"stop"
                                                   scrollView:self.collectionView
                                                    timestamp:CACurrentMediaTime()];
        self.scrollCallbackWindowIndex += 1;
    }
    [self clearScrollCallbackDiagnostics];
    [displayLink invalidate];
    self.frameRateDisplayLink = nil;
    self.frameRateLastTimestamp = 0.0;
    self.isCollectionViewTrackingFrameRate = NO;
    [self recordFrameRateDiagnosticPhase:@"frame-rate-stop"
                                 details:@{ @"reason": reason ?: @"stop" }];
}
#endif

- (CGRect)convertScreenRectToOverlayView:(CGRect)screenRect {
    UIWindow *hostWindow = self.view.window;
    if (!hostWindow) {
        return [self.view convertRect:screenRect fromView:nil];
    }

    CGRect windowRect = [hostWindow convertRect:screenRect fromWindow:nil];
    return [self.view convertRect:windowRect fromView:hostWindow];
}

- (CGRect)convertWindowBoundsToOverlayView:(UIWindow *)window {
    if (!window) {
        return CGRectZero;
    }

    UIWindow *hostWindow = self.view.window;
    if (!hostWindow) {
        CGRect screenRect = [window convertRect:window.bounds toWindow:nil];
        return [self.view convertRect:screenRect fromView:nil];
    }

    CGRect hostWindowRect = [hostWindow convertRect:window.bounds fromWindow:window];
    return [self.view convertRect:hostWindowRect fromView:hostWindow];
}

- (CGRect)liveKeyboardFrameInView {
    UIApplication *application = [UIApplication sharedApplication];
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in application.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }

            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (windowScene.activationState != UISceneActivationStateForegroundActive) {
                continue;
            }

            [windows addObjectsFromArray:windowScene.windows];
        }
    }

    [windows addObjectsFromArray:application.windows];

    CGRect bounds = self.view.bounds;
    if (CGRectIsEmpty(bounds)) {
        bounds = [UIScreen mainScreen].bounds;
    }

    CGRect keyboardFrame = CGRectZero;
    CGFloat keyboardArea = 0.0;
    CGFloat boundsHeight = CGRectGetHeight(bounds);
    CGFloat boundsWidth = CGRectGetWidth(bounds);

    for (UIWindow *window in windows) {
        if (![self windowLooksLikeKeyboardWindow:window]) {
            continue;
        }

        CGRect frame = [self convertWindowBoundsToOverlayView:window];
        CGRect intersection = CGRectIntersection(bounds, frame);
        if (CGRectIsNull(intersection) || CGRectIsEmpty(intersection)) {
            continue;
        }

        CGFloat height = CGRectGetHeight(intersection);
        CGFloat width = CGRectGetWidth(intersection);
        BOOL plausibleHeight = height >= 120.0 && height <= boundsHeight * 0.85;
        BOOL plausibleWidth = width >= MIN(160.0, boundsWidth * 0.5);
        BOOL startsBelowTop = CGRectGetMinY(intersection) > [self keyboardAdjustedTopLimit];
        if (!plausibleHeight || !plausibleWidth || !startsBelowTop) {
            continue;
        }

        CGFloat area = width * height;
        if (area > keyboardArea) {
            keyboardArea = area;
            keyboardFrame = intersection;
        }
    }

    return keyboardFrame;
}

- (CGRect)estimatedKeyboardFrameInView {
    CGRect bounds = self.view.bounds;
    if (CGRectIsEmpty(bounds)) {
        bounds = [UIScreen mainScreen].bounds;
    }

    CGFloat boundsHeight = CGRectGetHeight(bounds);
    CGFloat minimumHeight = MIN(kPBEstimatedKeyboardMinHeight, boundsHeight * 0.45);
    CGFloat maximumHeight = MIN(kPBEstimatedKeyboardMaxHeight, boundsHeight * 0.75);
    CGFloat height = boundsHeight * kPBEstimatedKeyboardHeightRatio;
    height = MIN(MAX(height, minimumHeight), maximumHeight);

    return CGRectMake(CGRectGetMinX(bounds),
                      CGRectGetMaxY(bounds) - height,
                      CGRectGetWidth(bounds),
                      height);
}

- (CGRect)keyboardFrameForCurrentSearchLayout {
    if (self.isKeyboardVisible && !CGRectIsEmpty(self.keyboardFrameInView)) {
        return self.keyboardFrameInView;
    }

    CGRect liveKeyboardFrame = [self liveKeyboardFrameInView];
    if (!CGRectIsEmpty(liveKeyboardFrame)) {
        return liveKeyboardFrame;
    }

    return [self estimatedKeyboardFrameInView];
}

- (CGRect)keyboardAdjustedContainerFrame {
    CGRect visibleFrame = [self visibleContainerFrame];
    if (!self.isSearchEditing) {
        return visibleFrame;
    }

    CGRect bounds = self.view.bounds;
    if (CGRectIsEmpty(bounds)) {
        bounds = [UIScreen mainScreen].bounds;
    }

    CGRect keyboardFrame = [self keyboardFrameForCurrentSearchLayout];
    CGFloat keyboardTop = CGRectGetMinY(keyboardFrame);
    if (!isfinite(keyboardTop) || keyboardTop <= 0.0 || keyboardTop >= CGRectGetHeight(bounds)) {
        return visibleFrame;
    }

    CGFloat topLimit = [self keyboardAdjustedTopLimit];
    CGFloat bottomLimit = MAX(topLimit, keyboardTop + kPBKeyboardContainerOverlap);
    CGFloat availableHeight = bottomLimit - topLimit;
    if (availableHeight <= 0.0) {
        return visibleFrame;
    }

    CGFloat height = MIN(CGRectGetHeight(visibleFrame), availableHeight);
    CGFloat y = MAX(topLimit, bottomLimit - height);
    return CGRectMake(CGRectGetMinX(visibleFrame),
                      y,
                      CGRectGetWidth(visibleFrame),
                      height);
}

- (CGRect)targetContainerFrame {
    return [self keyboardAdjustedContainerFrame];
}

- (void)animateContainerToFrame:(CGRect)frame
                       duration:(NSTimeInterval)duration
                        options:(UIViewAnimationOptions)options {
    void (^changes)(void) = ^{
        self.containerView.frame = frame;
        [self updateContainerLayoutForFrame:frame];
        [self.view layoutIfNeeded];
    };

    if (duration > 0.0) {
        [UIView animateWithDuration:duration
                              delay:0
                            options:options | UIViewAnimationOptionBeginFromCurrentState
                         animations:changes
                         completion:nil];
    } else {
        changes();
    }
}

- (NSTimeInterval)keyboardAnimationDurationFromUserInfo:(NSDictionary *)userInfo {
    NSNumber *durationNumber = userInfo[UIKeyboardAnimationDurationUserInfoKey];
    return durationNumber ? durationNumber.doubleValue : 0.25;
}

- (UIViewAnimationOptions)keyboardAnimationOptionsFromUserInfo:(NSDictionary *)userInfo {
    NSNumber *curveNumber = userInfo[UIKeyboardAnimationCurveUserInfoKey];
    if (!curveNumber) {
        return UIViewAnimationOptionCurveEaseInOut;
    }
    return (UIViewAnimationOptions)(curveNumber.integerValue << 16);
}

- (void)animateContainerWithKeyboardUserInfo:(NSDictionary *)userInfo {
    if (!self.isPresented || self.isDismissing) {
        return;
    }

    [self animateContainerToFrame:[self targetContainerFrame]
                         duration:[self keyboardAnimationDurationFromUserInfo:userInfo]
                          options:[self keyboardAnimationOptionsFromUserInfo:userInfo]];
}

- (void)configureSnippetFlowLayout:(UICollectionViewFlowLayout *)layout {
    if (!layout) {
        return;
    }

    if (self.usesVerticalSnippetLayout) {
        layout.scrollDirection = UICollectionViewScrollDirectionVertical;
        layout.minimumLineSpacing = kPBSnippetVerticalLineSpacing;
        layout.minimumInteritemSpacing = kPBSnippetVerticalLineSpacing;
        layout.sectionInset = UIEdgeInsetsMake(0,
                                               kPBSnippetVerticalHorizontalInset,
                                               10,
                                               kPBSnippetVerticalHorizontalInset);
        return;
    }

    layout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
    layout.minimumLineSpacing = 8;
    layout.minimumInteritemSpacing = 8;
    layout.sectionInset = UIEdgeInsetsMake(0, 12, 10, 12);
}

- (void)configureCollectionScrollingForCurrentLayout {
    self.collectionView.alwaysBounceHorizontal = !self.usesVerticalSnippetLayout;
    self.collectionView.alwaysBounceVertical = self.usesVerticalSnippetLayout;
}

- (void)applySnippetLayoutResetOffset:(BOOL)resetOffset reloadData:(BOOL)reloadData {
    if ([self.collectionView.collectionViewLayout isKindOfClass:[UICollectionViewFlowLayout class]]) {
        [self configureSnippetFlowLayout:(UICollectionViewFlowLayout *)self.collectionView.collectionViewLayout];
    }

    [self configureCollectionScrollingForCurrentLayout];
    [self.collectionView.collectionViewLayout invalidateLayout];
    if (resetOffset) {
        [self.collectionView setContentOffset:CGPointZero animated:NO];
    }
    if (reloadData) {
        [self.collectionView reloadData];
    }
}

- (void)preferencesDidChange {
    if (!PBMainFeatureEnabled()) {
        if (self.isPresented) {
            [self dismissAnimated:YES];
        }
        return;
    }

    BOOL shouldUseVerticalLayout = PBVerticalLayoutEnabled();
    BOOL layoutChanged = self.usesVerticalSnippetLayout != shouldUseVerticalLayout;
    if (layoutChanged) {
        self.usesVerticalSnippetLayout = shouldUseVerticalLayout;
        [self applySnippetLayoutResetOffset:YES reloadData:NO];
    }

    if (self.isPresented) {
        [[PBClipboardManager sharedManager] refreshItems];
        [self updateDisplayItems];
    }
}

- (void)setupOverlayUI {
    self.view.backgroundColor = [UIColor clearColor];

    // Background layer
    _backgroundView = [[UIView alloc] initWithFrame:self.view.bounds];
    _backgroundView.backgroundColor = [UIColor clearColor];
    _backgroundView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_backgroundView];

    // ── Main Container ──
    CGRect hiddenFrame = [self hiddenContainerFrame];
    CGFloat containerHeight = hiddenFrame.size.height;
    CGFloat containerWidth = hiddenFrame.size.width;

    _containerView = [[UIView alloc] init];
    _containerView.frame = hiddenFrame;
    _containerView.layer.cornerRadius = 16;
    if (@available(iOS 11.0, *)) {
        _containerView.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    }
    _containerView.layer.masksToBounds = YES;
    _containerView.layer.borderWidth = 1.0 / [UIScreen mainScreen].scale;
    _containerView.layer.borderColor = [[UIColor separatorColor] colorWithAlphaComponent:0.3].CGColor;
    [self.view addSubview:_containerView];

    _containerBackgroundView = [[UIView alloc] initWithFrame:_containerView.bounds];
    _containerBackgroundView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    if (@available(iOS 13.0, *)) {
        _containerBackgroundView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    } else {
        _containerBackgroundView.backgroundColor = [UIColor groupTableViewBackgroundColor];
    }
    _containerView.backgroundColor = _containerBackgroundView.backgroundColor;
    [_containerView addSubview:_containerBackgroundView];

    // ── Handle Bar ──
    _handleBar = [[UIView alloc] initWithFrame:CGRectMake((containerWidth - 30) / 2, 7, 30, 4)];
    _handleBar.backgroundColor = [[UIColor labelColor] colorWithAlphaComponent:0.2];
    _handleBar.layer.cornerRadius = 2;
    [_containerView addSubview:_handleBar];

    // ── Header View ──
    CGFloat headerY = 16;
    _headerView = [[UIView alloc] initWithFrame:CGRectMake(0, headerY, containerWidth, 92)];
    [_containerView addSubview:_headerView];

    // Search Bar
    _searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(10, 0, containerWidth - 74, 36)];
    _searchBar.placeholder = PBLocalizedString(@"Search");
    _searchBar.searchBarStyle = UISearchBarStyleMinimal;
    _searchBar.delegate = self;
    _searchBar.tintColor = [UIColor systemBlueColor];
    _searchBar.accessibilityIdentifier = kPBiOSCopySearchAccessibilityIdentifier;
    [_headerView addSubview:_searchBar];

    // Cancel Button
    _cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _cancelButton.frame = CGRectMake(containerWidth - 62, 0, 54, 36);
    [_cancelButton setTitle:PBLocalizedString(@"Cancel") forState:UIControlStateNormal];
    _cancelButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [_cancelButton addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];
    [_headerView addSubview:_cancelButton];

    // Snippet count + filter
    _snippetCountLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 38, 150, 22)];
    _snippetCountLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _snippetCountLabel.textColor = [UIColor labelColor];
    [_headerView addSubview:_snippetCountLabel];

    // Filter Segment
    _filterSegment = [[UISegmentedControl alloc] initWithItems:@[
        PBLocalizedString(@"All"),
        PBLocalizedString(@"Pinned"),
        PBLocalizedString(@"Fav")
    ]];
    _filterSegment.frame = CGRectMake(16, 64, containerWidth - 32, 26);
    _filterSegment.selectedSegmentIndex = 0;
    [_filterSegment addTarget:self action:@selector(filterChanged:) forControlEvents:UIControlEventValueChanged];

    // Customize segment appearance
    UIFont *segFont = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    [_filterSegment setTitleTextAttributes:@{NSFontAttributeName: segFont} forState:UIControlStateNormal];
    [_headerView addSubview:_filterSegment];

    // Adjust header height
    _headerView.frame = CGRectMake(0, headerY, containerWidth, 94);

    // 剪贴板列表，方向由设置控制
    CGFloat collectionY = headerY + 98;
    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    [self configureSnippetFlowLayout:layout];

    _collectionView = [[UICollectionView alloc] initWithFrame:CGRectMake(0, collectionY,
                                                                         containerWidth,
                                                                         containerHeight - collectionY)
                                         collectionViewLayout:layout];
    _collectionView.dataSource = self;
    _collectionView.delegate = self;
    _collectionView.backgroundColor = [UIColor clearColor];
    _collectionView.showsHorizontalScrollIndicator = NO;
    _collectionView.showsVerticalScrollIndicator = NO;
    _collectionView.directionalLockEnabled = YES;
    _collectionView.delaysContentTouches = NO;
    _collectionView.canCancelContentTouches = YES;
    _collectionView.decelerationRate = UIScrollViewDecelerationRateNormal;
    [self configureCollectionScrollingForCurrentLayout];
    [_collectionView registerClass:[PBSnippetCollectionCell class] forCellWithReuseIdentifier:kCellIdentifier];
    [_containerView addSubview:_collectionView];

    UILongPressGestureRecognizer *imageLongPress = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleImagePreviewLongPress:)];
    imageLongPress.minimumPressDuration = 0.45;
    imageLongPress.cancelsTouchesInView = YES;
    imageLongPress.delegate = self;
    self.imagePreviewLongPressGestureRecognizer = imageLongPress;
    [_collectionView addGestureRecognizer:imageLongPress];

    // ── Empty State Label ──
    _emptyLabel = [[UILabel alloc] init];
    _emptyLabel.text = PBLocalizedString(@"No Snippets Yet");
    _emptyLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    _emptyLabel.textColor = [UIColor tertiaryLabelColor];
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.numberOfLines = 0;
    _emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _emptyLabel.hidden = YES;
    [_containerView addSubview:_emptyLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_emptyLabel.centerXAnchor constraintEqualToAnchor:_containerView.centerXAnchor],
        [_emptyLabel.centerYAnchor constraintEqualToAnchor:_containerView.centerYAnchor constant:22],
        [_emptyLabel.widthAnchor constraintEqualToConstant:250],
    ]];

    // Pan gesture on container for pull-down dismiss
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(handlePanGesture:)];
    pan.delegate = self;
    pan.cancelsTouchesInView = NO;
    pan.delaysTouchesBegan = NO;
    pan.delaysTouchesEnded = NO;
    self.dismissPanGestureRecognizer = pan;
    [_containerView addGestureRecognizer:pan];
}

- (NSDictionary *)resolvedTargetInfoForPresentation {
    NSDictionary *triggerTarget = [PBInputBridge consumeRecentOpenTriggerTargetInfo];
    NSString *triggerBundleId = triggerTarget[@"targetBundleId"];
    if ([triggerBundleId isKindOfClass:[NSString class]] &&
        triggerBundleId.length > 0) {
        return triggerTarget;
    }

    return [PBInputBridge recentInputTargetInfo];
}

- (NSDictionary *)refreshedTargetInfoForSelection {
    NSDictionary *targetInfo = self.activeTargetInfo;
    NSString *targetBundleId = targetInfo[@"targetBundleId"];
    NSString *resolutionSource = targetInfo[@"targetResolutionSource"];
    if ([resolutionSource isEqualToString:@"inputBridgeTrigger"] &&
        [targetBundleId isKindOfClass:[NSString class]] &&
        targetBundleId.length > 0) {
        return targetInfo;
    }

    NSDictionary *recentTarget = [PBInputBridge recentInputTargetInfo];
    NSString *recentBundleId = recentTarget[@"targetBundleId"];
    if (![recentBundleId isKindOfClass:[NSString class]] ||
        recentBundleId.length == 0) {
        return nil;
    }

    self.activeTargetInfo = recentTarget;
    return recentTarget;
}

- (NSDictionary *)currentTargetInfoForForegroundMonitoring {
    return [PBInputBridge recentInputTargetInfo];
}

- (void)startForegroundTargetMonitor {
    [self stopForegroundTargetMonitor];

    NSString *targetBundleId = self.activeTargetInfo[@"targetBundleId"];
    if (![targetBundleId isKindOfClass:[NSString class]] || targetBundleId.length == 0) {
        return;
    }

    NSTimer *timer = [NSTimer timerWithTimeInterval:0.35
                                             target:self
                                           selector:@selector(foregroundTargetMonitorDidFire:)
                                           userInfo:nil
                                            repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    self.foregroundTargetMonitorTimer = timer;
}

- (void)stopForegroundTargetMonitor {
    [self.foregroundTargetMonitorTimer invalidate];
    self.foregroundTargetMonitorTimer = nil;
}

- (void)foregroundTargetMonitorDidFire:(NSTimer *)timer {
    if (!self.isPresented || self.isDismissing) {
        return;
    }

    NSString *originalBundleId = self.activeTargetInfo[@"targetBundleId"];
    if (![originalBundleId isKindOfClass:[NSString class]] || originalBundleId.length == 0) {
        return;
    }

    NSDictionary *currentTargetInfo = [self currentTargetInfoForForegroundMonitoring];
    NSString *currentBundleId = currentTargetInfo[@"targetBundleId"];
    if (![currentBundleId isKindOfClass:[NSString class]] ||
        currentBundleId.length == 0 ||
        ![currentBundleId isEqualToString:originalBundleId]) {
        [self dismissAnimated:YES];
    }
}

#pragma mark - Show / Dismiss

- (void)showAnimated:(BOOL)animated {
    if (self.isPresented) return;
    if (!PBMainFeatureEnabled()) return;

    self.activeTargetInfo = [self resolvedTargetInfoForPresentation];
    self.isPresented = YES;
    self.isDismissing = NO;
    self.isSearchEditing = NO;
    self.didUseSearchInCurrentPresentation = NO;
    self.isKeyboardVisible = NO;
    self.keyboardFrameInView = CGRectZero;
    [self applyKeyboardAttachedStyle:NO];
    self.usesVerticalSnippetLayout = PBVerticalLayoutEnabled();
    [self applySnippetLayoutResetOffset:NO reloadData:NO];

    // Refresh data
#if DEBUG_LOG
    CFTimeInterval refreshStart = CACurrentMediaTime();
#endif
    [[PBClipboardManager sharedManager] refreshItems];
#if DEBUG_LOG
    [self recordMainThreadOperationNamed:@"clipboard-refresh-items"
                               startTime:refreshStart
                                 details:@{ @"source": @"show" }];
#endif
    [self updateDisplayItems];
    [self.collectionView setContentOffset:CGPointZero animated:NO];

    BOOL embedded = [self attachToExistingSpringBoardHierarchy];
    if (!embedded) {
#if DEBUG_LOG
        [self recordFrameRateDiagnosticPhase:@"embedded-host-missing"
                                     details:@{ @"reason": @"no-suitable-host-window" }];
#endif
        self.isPresented = NO;
        self.isDismissing = NO;
        self.activeTargetInfo = nil;
        return;
    }
    [self startForegroundTargetMonitor];
    PBPostOverlayStateNotification(YES);

#if DEBUG_LOG
    [self startFrameRateDiagnostics];
#endif

    CGRect targetFrame = [self visibleContainerFrame];
    CGRect hiddenFrame = [self hiddenContainerFrame];
    self.containerView.frame = hiddenFrame;
    [self updateContainerLayoutForFrame:hiddenFrame];

    if (animated) {
        [UIView animateWithDuration:0.5
                              delay:0
             usingSpringWithDamping:0.82
              initialSpringVelocity:0.5
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            self.containerView.frame = targetFrame;
            [self updateContainerLayoutForFrame:targetFrame];
        } completion:nil];
    } else {
        self.containerView.frame = targetFrame;
        [self updateContainerLayoutForFrame:targetFrame];
    }

    PBPerformImpactFeedback(UIImpactFeedbackStyleLight);
}

- (void)dismissAnimated:(BOOL)animated {
    [self dismissAnimated:animated completion:nil];
}

- (void)dismissAnimated:(BOOL)animated completion:(void (^)(void))completion {
    if (!self.isPresented) return;

    self.isDismissing = YES;
    [self stopForegroundTargetMonitor];
    [self dismissImagePreviewAnimated:NO];
    [self.searchBar resignFirstResponder];
    [self applyKeyboardAttachedStyle:NO];

    CGRect hiddenFrame = [self hiddenContainerFrame];

    void (^cleanup)(BOOL) = ^(BOOL finished) {
#if DEBUG_LOG
        [self stopFrameRateDiagnosticsWithReason:@"dismiss-cleanup"];
#endif
        self.isPresented = NO;
        self.isDismissing = NO;
        self.isSearchEditing = NO;
        self.didUseSearchInCurrentPresentation = NO;
        self.isKeyboardVisible = NO;
        self.keyboardFrameInView = CGRectZero;
        [self applyKeyboardAttachedStyle:NO];
        [self detachFromExistingSpringBoardHierarchy];
        self.searchBar.text = @"";
        self.currentFilter = 0;
        self.filterSegment.selectedSegmentIndex = 0;
        self.activeTargetInfo = nil;
        PBPostOverlayStateNotification(NO);
        if (completion) {
            completion();
        }
    };

    if (animated) {
        [UIView animateWithDuration:0.35
                              delay:0
                            options:UIViewAnimationOptionCurveEaseIn
                         animations:^{
            self.containerView.frame = hiddenFrame;
        } completion:cleanup];
    } else {
        cleanup(YES);
    }
}

- (void)updateContainerLayoutForFrame:(CGRect)frame {
#if DEBUG_LOG
    CFTimeInterval operationStart = CACurrentMediaTime();
#endif
    CGFloat containerWidth = frame.size.width;
    CGFloat containerHeight = frame.size.height;
    CGFloat headerY = 16;
    CGFloat collectionY = headerY + 98;

    self.handleBar.frame = CGRectMake((containerWidth - 30) / 2.0, 7, 30, 4);
    self.headerView.frame = CGRectMake(0, headerY, containerWidth, 94);
    self.searchBar.frame = CGRectMake(10, 0, containerWidth - 74, 36);
    self.cancelButton.frame = CGRectMake(containerWidth - 62, 0, 54, 36);
    self.snippetCountLabel.frame = CGRectMake(16, 38, 150, 22);
    self.filterSegment.frame = CGRectMake(16, 64, containerWidth - 32, 26);
    self.collectionView.frame = CGRectMake(0,
                                           collectionY,
                                           containerWidth,
                                           MAX(containerHeight - collectionY, 0));
    [self.collectionView.collectionViewLayout invalidateLayout];
#if DEBUG_LOG
    [self recordMainThreadOperationNamed:@"update-container-layout"
                               startTime:operationStart
                                 details:@{
        @"frame": NSStringFromCGRect(frame)
    }];
#endif
}

#pragma mark - Data

- (void)updateDisplayItems {
#if DEBUG_LOG
    CFTimeInterval operationStart = CACurrentMediaTime();
#endif
    [self.searchUpdateTimer invalidate];
    self.searchUpdateTimer = nil;
    NSString *query = [self.searchBar.text copy] ?: @"";
    NSInteger filter = self.currentFilter;
    NSUInteger generation = ++self.displayQueryGeneration;

    dispatch_async(self.displayQueryQueue, ^{
        NSArray<PBClipboardItem *> *items = nil;
        switch (filter) {
            case 1:
                items = [[PBStorageManager sharedManager] pinnedItems];
                break;
            case 2:
                items = [[PBStorageManager sharedManager] favoriteItems];
                break;
            default:
                if (query.length > 0) {
                    items = [[PBClipboardManager sharedManager] searchWithQuery:query];
                } else {
                    items = [PBClipboardManager sharedManager].currentItems;
                }
                break;
        }

        NSInteger count = [[PBStorageManager sharedManager] totalItemCount];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.displayQueryGeneration) {
                return;
            }
            NSString *currentQuery = self.searchBar.text ?: @"";
            if (filter != self.currentFilter || ![query isEqualToString:currentQuery]) {
                return;
            }

            self.displayItems = items ?: @[];
            self.snippetCountLabel.text = [NSString stringWithFormat:PBLocalizedString(@"%ld Snippets"), (long)count];
            self.emptyLabel.hidden = (self.displayItems.count > 0);

#if DEBUG_LOG
            CFTimeInterval reloadStart = CACurrentMediaTime();
#endif
            [self.collectionView reloadData];
#if DEBUG_LOG
            [self recordMainThreadOperationNamed:@"collection-reload-data"
                                       startTime:reloadStart
                                         details:@{
                @"displayItemCount": @(self.displayItems.count),
                @"queryLength": @(query.length),
                @"filter": @(filter)
            }];
            [self recordMainThreadOperationNamed:@"update-display-items"
                                       startTime:operationStart
                                         details:@{
                @"displayItemCount": @(self.displayItems.count),
                @"queryLength": @(query.length),
                @"filter": @(filter)
            }];
#endif
        });
    });
}

- (void)scheduleSearchDisplayItemsUpdate {
    self.displayQueryGeneration += 1;
    [self.searchUpdateTimer invalidate];
    self.searchUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:kPBSearchDebounceInterval
                                                              target:self
                                                            selector:@selector(searchUpdateTimerFired:)
                                                            userInfo:nil
                                                             repeats:NO];
}

- (void)searchUpdateTimerFired:(NSTimer *)timer {
    if (timer != self.searchUpdateTimer) {
        return;
    }
    self.searchUpdateTimer = nil;
    [self updateDisplayItems];
}

- (void)clipboardDidUpdate {
    if (self.isPresented) {
#if DEBUG_LOG
        CFTimeInterval refreshStart = CACurrentMediaTime();
#endif
        [[PBClipboardManager sharedManager] refreshItems];
#if DEBUG_LOG
        [self recordMainThreadOperationNamed:@"clipboard-refresh-items"
                                   startTime:refreshStart
                                     details:@{ @"source": @"clipboard-update" }];
#endif
        [self updateDisplayItems];
    }
}

#pragma mark - Actions

- (void)cancelTapped {
    [self dismissAnimated:YES];
}

- (void)filterChanged:(UISegmentedControl *)segment {
    self.currentFilter = segment.selectedSegmentIndex;
    [self updateDisplayItems];
#if DEBUG_LOG
    CFTimeInterval offsetStart = CACurrentMediaTime();
#endif
    [self.collectionView setContentOffset:CGPointZero animated:NO];
#if DEBUG_LOG
    [self recordMainThreadOperationNamed:@"collection-set-content-offset"
                               startTime:offsetStart
                                 details:@{
        @"source": @"filter-changed",
        @"target": NSStringFromCGPoint(CGPointZero)
    }];
#endif

    PBPerformSelectionFeedback();
}

#pragma mark - Pan Gesture (Pull to dismiss)

- (void)handlePanGesture:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self.view];

    if (pan.state == UIGestureRecognizerStateChanged) {
        if (translation.y > 0 && fabs(translation.y) > fabs(translation.x)) {
            CGRect visibleFrame = [self targetContainerFrame];

            // Rubber-band effect
            CGFloat damped = translation.y * 0.6;
            self.containerView.frame = CGRectMake(self.containerView.frame.origin.x,
                                                  visibleFrame.origin.y + damped,
                                                  self.containerView.frame.size.width,
                                                  self.containerView.frame.size.height);
        }
    } else if (pan.state == UIGestureRecognizerStateEnded) {
        CGFloat velocity = [pan velocityInView:self.view].y;

        if (translation.y > 100 || velocity > 500) {
            [self dismissAnimated:YES];
        } else {
            // Snap back
            CGRect visibleFrame = [self targetContainerFrame];

            [UIView animateWithDuration:0.3
                                  delay:0
                 usingSpringWithDamping:0.8
                  initialSpringVelocity:0.3
                                options:0
                             animations:^{
                self.containerView.frame = visibleFrame;
            } completion:nil];
        }
    }
}

#pragma mark - UICollectionViewDataSource

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.displayItems.count;
}

- (__kindof UICollectionViewCell *)collectionView:(UICollectionView *)collectionView
                          cellForItemAtIndexPath:(NSIndexPath *)indexPath {
#if DEBUG_LOG
    CFTimeInterval operationStart = CACurrentMediaTime();
#endif
    PBSnippetCollectionCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:kCellIdentifier
                                                                             forIndexPath:indexPath];
    cell.delegate = self;
    [cell setUsesVerticalLayout:self.usesVerticalSnippetLayout];
    if (indexPath.item < self.displayItems.count) {
        PBClipboardItem *item = self.displayItems[indexPath.item];
        [cell configureWithItem:item];
#if DEBUG_LOG
        [self recordMainThreadOperationNamed:@"cell-configure"
                                   startTime:operationStart
                                     details:@{
            @"index": @(indexPath.item),
            @"itemId": @(item.itemId),
            @"contentType": @(item.contentType),
            @"hasThumbnail": @(item.thumbnailPath.length > 0)
        }];
#endif
    }
    return cell;
}

#pragma mark - UICollectionViewDelegate

- (CGSize)collectionView:(UICollectionView *)collectionView
                  layout:(UICollectionViewLayout *)collectionViewLayout
  sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    if (!self.usesVerticalSnippetLayout) {
        CGFloat height = MAX(collectionView.bounds.size.height - 10, 154);
        CGFloat width = MIN(MAX(collectionView.bounds.size.width - 30, 260), 360);
        return CGSizeMake(width, height);
    }

    CGFloat width = MAX(collectionView.bounds.size.width - kPBSnippetVerticalHorizontalInset * 2.0, 0.0);
    return CGSizeMake(width, kPBSnippetVerticalItemHeight);
}

#if DEBUG_LOG
- (CGFloat)diagnosticCollectionItemStep {
    if (!self.collectionView) {
        return 1.0;
    }

    NSIndexPath *indexPath = [NSIndexPath indexPathForItem:0 inSection:0];
    CGSize itemSize = [self collectionView:self.collectionView
                                    layout:self.collectionView.collectionViewLayout
                    sizeForItemAtIndexPath:indexPath];
    CGFloat spacing = 0.0;
    if ([self.collectionView.collectionViewLayout isKindOfClass:[UICollectionViewFlowLayout class]]) {
        UICollectionViewFlowLayout *layout =
            (UICollectionViewFlowLayout *)self.collectionView.collectionViewLayout;
        spacing = layout.minimumLineSpacing;
    }

    CGFloat dimension = self.usesVerticalSnippetLayout ? itemSize.height : itemSize.width;
    return MAX(dimension + spacing, 1.0);
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView != self.collectionView) {
        return;
    }

    [self recordScrollCallbackAtTimestamp:CACurrentMediaTime() scrollView:scrollView];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    if (scrollView != self.collectionView) {
        return;
    }

    self.isCollectionViewTrackingFrameRate = YES;
    [self resetScrollCallbackDiagnosticsAtTimestamp:CACurrentMediaTime()
                                      contentOffset:scrollView.contentOffset];
    [self recordFrameRateDiagnosticPhase:@"scroll-begin-dragging" details:nil];
}

- (void)scrollViewWillEndDragging:(UIScrollView *)scrollView
                      withVelocity:(CGPoint)velocity
               targetContentOffset:(inout CGPoint *)targetContentOffset {
    if (scrollView != self.collectionView) {
        return;
    }

    CGPoint targetOffset = targetContentOffset ? *targetContentOffset : scrollView.contentOffset;
    CGFloat projectedDistance = self.usesVerticalSnippetLayout
        ? targetOffset.y - scrollView.contentOffset.y
        : targetOffset.x - scrollView.contentOffset.x;
    CGFloat itemStep = [self diagnosticCollectionItemStep];
    CGFloat projectedItems = projectedDistance / itemStep;
    UIEdgeInsets contentInset = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) {
        contentInset = scrollView.adjustedContentInset;
    } else {
        contentInset = scrollView.contentInset;
    }

    [self recordFrameRateDiagnosticPhase:@"scroll-will-end-dragging"
                                 details:@{
        @"velocity": NSStringFromCGPoint(velocity),
        @"velocityX": @(velocity.x),
        @"velocityY": @(velocity.y),
        @"contentOffset": NSStringFromCGPoint(scrollView.contentOffset),
        @"targetContentOffset": NSStringFromCGPoint(targetOffset),
        @"projectedDistance": @(projectedDistance),
        @"projectedItems": @(projectedItems),
        @"absoluteProjectedItems": @(fabs(projectedItems)),
        @"itemStep": @(itemStep),
        @"contentSize": NSStringFromCGSize(scrollView.contentSize),
        @"contentInset": NSStringFromUIEdgeInsets(contentInset),
        @"decelerationRate": @(scrollView.decelerationRate)
    }];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView
                  willDecelerate:(BOOL)decelerate {
    if (scrollView != self.collectionView) {
        return;
    }

    self.isCollectionViewTrackingFrameRate = decelerate;
    if (!decelerate) {
        if (self.scrollCallbackCount > 0) {
            [self recordScrollCallbackDiagnosticSummaryWithReason:@"end-dragging"
                                                       scrollView:scrollView
                                                        timestamp:CACurrentMediaTime()];
            self.scrollCallbackWindowIndex += 1;
        }
        [self clearScrollCallbackDiagnostics];
    }
    [self recordFrameRateDiagnosticPhase:@"scroll-end-dragging"
                                 details:@{ @"willDecelerate": @(decelerate) }];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    if (scrollView != self.collectionView) {
        return;
    }

    self.isCollectionViewTrackingFrameRate = NO;
    if (self.scrollCallbackCount > 0) {
        [self recordScrollCallbackDiagnosticSummaryWithReason:@"end-decelerating"
                                                   scrollView:scrollView
                                                    timestamp:CACurrentMediaTime()];
        self.scrollCallbackWindowIndex += 1;
    }
    [self clearScrollCallbackDiagnostics];
    [self recordFrameRateDiagnosticPhase:@"scroll-end-decelerating" details:nil];
}

- (void)scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView {
    if (scrollView != self.collectionView) {
        return;
    }

    self.isCollectionViewTrackingFrameRate = NO;
    if (self.scrollCallbackCount > 0) {
        [self recordScrollCallbackDiagnosticSummaryWithReason:@"end-animation"
                                                   scrollView:scrollView
                                                    timestamp:CACurrentMediaTime()];
        self.scrollCallbackWindowIndex += 1;
    }
    [self clearScrollCallbackDiagnostics];
    [self recordFrameRateDiagnosticPhase:@"scroll-end-animation" details:nil];
}
#endif

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.item >= self.displayItems.count) return;

    UICollectionViewCell *cell = [collectionView cellForItemAtIndexPath:indexPath];
    [self handleSelectedItem:self.displayItems[indexPath.item] sourceView:cell.contentView];
}

- (UIContextMenuConfiguration *)collectionView:(UICollectionView *)collectionView
    contextMenuConfigurationForItemAtIndexPath:(NSIndexPath *)indexPath
                                         point:(CGPoint)point {
    return nil;
}

- (PBClipboardItem *)itemForSnippetCell:(PBSnippetCollectionCell *)cell {
    NSIndexPath *indexPath = [self.collectionView indexPathForCell:cell];
    if (indexPath && indexPath.item < self.displayItems.count) {
        return self.displayItems[indexPath.item];
    }
    return cell.item;
}

- (void)snippetCellDidTapPin:(PBSnippetCollectionCell *)cell {
    PBClipboardItem *item = [self itemForSnippetCell:cell];
    if (!item) return;

    [[PBClipboardManager sharedManager] togglePinItem:item];
    [self updateDisplayItems];

    PBPerformSelectionFeedback();
}

- (void)snippetCellDidTapFavorite:(PBSnippetCollectionCell *)cell {
    PBClipboardItem *item = [self itemForSnippetCell:cell];
    if (!item) return;

    [[PBClipboardManager sharedManager] toggleFavoriteItem:item];
    [self updateDisplayItems];

    PBPerformSelectionFeedback();
}

- (void)snippetCellDidTapDelete:(PBSnippetCollectionCell *)cell {
    PBClipboardItem *item = [self itemForSnippetCell:cell];
    if (!item) return;

    [[PBClipboardManager sharedManager] deleteItem:item];
    [self updateDisplayItems];

    PBPerformImpactFeedback(UIImpactFeedbackStyleLight);
}

- (void)handleImagePreviewLongPress:(UILongPressGestureRecognizer *)longPress {
    if (longPress.state != UIGestureRecognizerStateBegan) {
        return;
    }

    CGPoint point = [longPress locationInView:self.collectionView];
    NSIndexPath *indexPath = [self.collectionView indexPathForItemAtPoint:point];
    if (!indexPath || indexPath.item >= self.displayItems.count) {
        return;
    }

    PBClipboardItem *item = self.displayItems[indexPath.item];
    if (item.contentType != PBContentTypeImage) {
        return;
    }

    [self presentImagePreviewForItem:item];
}

- (void)presentImagePreviewForItem:(PBClipboardItem *)item {
    NSUInteger generation = ++self.imagePreviewGeneration;
    dispatch_async(self.imagePreviewQueue, ^{
        NSData *imageData = [[PBClipboardManager sharedManager] imageDataForItem:item];
        UIImage *image = imageData.length > 0 ? [UIImage imageWithData:imageData] : nil;
        if (!image && item.thumbnailPath.length > 0) {
            image = [UIImage imageWithContentsOfFile:item.thumbnailPath];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.imagePreviewGeneration || !image || !self.isPresented) {
                return;
            }
            [self showImagePreviewWithImage:image];
        });
    });
}

- (void)showImagePreviewWithImage:(UIImage *)image {
    if (!image) {
        return;
    }

    [self dismissImagePreviewAnimated:NO];

    UIView *overlay = [[UIView alloc] initWithFrame:self.view.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [UIColor clearColor];
    overlay.alpha = 0.0;
    overlay.userInteractionEnabled = YES;

    UIBlurEffect *blurEffect = nil;
    if (@available(iOS 13.0, *)) {
        blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
    } else {
        blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleRegular];
    }
    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    blurView.translatesAutoresizingMaskIntoConstraints = NO;
    [overlay addSubview:blurView];

    UIImageView *imageView = [[UIImageView alloc] initWithImage:image];
    imageView.translatesAutoresizingMaskIntoConstraints = NO;
    imageView.contentMode = UIViewContentModeScaleAspectFit;
    imageView.userInteractionEnabled = YES;
    imageView.layer.cornerRadius = 14;
    imageView.layer.masksToBounds = YES;
    [overlay addSubview:imageView];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(imagePreviewTapped:)];
    [overlay addGestureRecognizer:tap];

    [self.view addSubview:overlay];
    self.imagePreviewOverlayView = overlay;

    UILayoutGuide *safeArea = nil;
    if (@available(iOS 11.0, *)) {
        safeArea = overlay.safeAreaLayoutGuide;
    }

    NSLayoutYAxisAnchor *topAnchor = safeArea ? safeArea.topAnchor : overlay.topAnchor;
    NSLayoutYAxisAnchor *bottomAnchor = safeArea ? safeArea.bottomAnchor : overlay.bottomAnchor;
    NSLayoutXAxisAnchor *leadingAnchor = safeArea ? safeArea.leadingAnchor : overlay.leadingAnchor;
    NSLayoutXAxisAnchor *trailingAnchor = safeArea ? safeArea.trailingAnchor : overlay.trailingAnchor;

    [NSLayoutConstraint activateConstraints:@[
        [blurView.topAnchor constraintEqualToAnchor:overlay.topAnchor],
        [blurView.bottomAnchor constraintEqualToAnchor:overlay.bottomAnchor],
        [blurView.leadingAnchor constraintEqualToAnchor:overlay.leadingAnchor],
        [blurView.trailingAnchor constraintEqualToAnchor:overlay.trailingAnchor],

        [imageView.topAnchor constraintEqualToAnchor:topAnchor constant:18],
        [imageView.bottomAnchor constraintEqualToAnchor:bottomAnchor constant:-18],
        [imageView.leadingAnchor constraintEqualToAnchor:leadingAnchor constant:18],
        [imageView.trailingAnchor constraintEqualToAnchor:trailingAnchor constant:-18],
    ]];

    PBPerformImpactFeedback(UIImpactFeedbackStyleLight);

    [UIView animateWithDuration:0.18 animations:^{
        overlay.alpha = 1.0;
    }];
}

- (void)imagePreviewTapped:(UITapGestureRecognizer *)tap {
    [self dismissImagePreviewAnimated:YES];
}

- (void)dismissImagePreviewAnimated:(BOOL)animated {
    UIView *overlay = self.imagePreviewOverlayView;
    if (!overlay) {
        return;
    }

    self.imagePreviewOverlayView = nil;
    void (^removeOverlay)(BOOL) = ^(BOOL finished) {
        [overlay removeFromSuperview];
    };

    if (animated) {
        [UIView animateWithDuration:0.16 animations:^{
            overlay.alpha = 0.0;
        } completion:removeOverlay];
    } else {
        removeOverlay(YES);
    }
}

- (void)performImageSelectionForItem:(PBClipboardItem *)selectedItem
                           targetInfo:(NSDictionary *)targetInfo {
    dispatch_async(self.imagePreviewQueue, ^{
        NSData *imageData = [[PBClipboardManager sharedManager] imageDataForItem:selectedItem];
        dispatch_async(dispatch_get_main_queue(), ^{
            PB_CLEAR_IMAGE_PASTE_DIAGNOSTIC();
            PB_RECORD_IMAGE_PASTE_DIAGNOSTIC(@"select-image"
                                                 requestId:nil
                                                   details:@{
                @"itemId": @(selectedItem.itemId),
                @"sourceBundleId": selectedItem.sourceBundleId ?: @"",
                @"sourceAppName": selectedItem.sourceAppName ?: @"",
                @"contentPath": selectedItem.content ?: @"",
                @"thumbnailPath": selectedItem.thumbnailPath ?: @"",
                @"storedDataSize": @(selectedItem.dataSize),
                @"imageBytes": @(imageData.length),
                @"hasTarget": @(targetInfo != nil),
                @"targetBundleId": targetInfo[@"targetBundleId"] ?: @"",
                @"targetAppName": targetInfo[@"targetAppName"] ?: @"",
                @"targetResolutionSource":
                    targetInfo[@"targetResolutionSource"] ?: @""
            });

            if (imageData.length > 0) {
                [PBInputBridge sendPasteRequestWithImageData:imageData targetInfo:targetInfo];
            }
        });
    });
}

- (void)handleSelectedItem:(PBClipboardItem *)item sourceView:(UIView *)sourceView {
    NSDictionary *targetInfo = [[self refreshedTargetInfoForSelection] copy];
    PBClipboardItem *selectedItem = item;
    void (^performSelection)(void) = ^{
        if (selectedItem.contentType == PBContentTypeText || selectedItem.contentType == PBContentTypeURL) {
            if (PBTextPasteCompatibilityModeEnabled()) {
                [PBInputBridge sendPasteRequestWithText:selectedItem.content targetInfo:targetInfo];
            } else {
                [PBInputBridge sendInsertRequestWithText:selectedItem.content targetInfo:targetInfo];
            }
        } else if (selectedItem.contentType == PBContentTypeImage) {
            [self performImageSelectionForItem:selectedItem targetInfo:targetInfo];
        }
    };

    UIView *flash = [[UIView alloc] initWithFrame:sourceView.bounds];
    flash.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    flash.backgroundColor = [[UIColor systemGreenColor] colorWithAlphaComponent:0.25];
    flash.layer.cornerRadius = 10;
    [sourceView addSubview:flash];

    [UIView animateWithDuration:0.5 animations:^{
        flash.alpha = 0;
    } completion:^(BOOL finished) {
        [flash removeFromSuperview];
    }];

    BOOL pasteAfterDismiss = self.isSearchEditing ||
                             self.searchBar.isFirstResponder ||
                             self.didUseSearchInCurrentPresentation ||
                             self.searchBar.text.length > 0;
    BOOL autoClose = PBAutoCloseEnabled();
    if (pasteAfterDismiss && autoClose) {
        [self dismissAnimated:YES completion:^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(kPBSearchPasteDelayAfterDismiss * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                performSelection();
            });
        }];
        return;
    }

    if (pasteAfterDismiss) {
        [self.searchBar resignFirstResponder];
        self.isSearchEditing = NO;
        [self applyKeyboardAttachedStyle:NO];
        [self animateContainerToFrame:[self targetContainerFrame]
                             duration:0.2
                              options:UIViewAnimationOptionCurveEaseOut];
    }

    performSelection();

    if (autoClose) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self dismissAnimated:YES];
        });
    }
}

#pragma mark - UISearchBarDelegate

- (void)searchBarTextDidBeginEditing:(UISearchBar *)searchBar {
    self.isSearchEditing = YES;
    self.didUseSearchInCurrentPresentation = YES;
#if DEBUG_LOG
    [self recordSearchDiagnosticPhase:@"search-begin" details:nil];
#endif
    [self applyKeyboardAttachedStyle:YES];
    [self animateContainerToFrame:[self targetContainerFrame]
                         duration:self.isKeyboardVisible ? 0.25 : 0.0
                          options:UIViewAnimationOptionCurveEaseOut];
}

- (void)searchBarTextDidEndEditing:(UISearchBar *)searchBar {
    self.isSearchEditing = NO;
#if DEBUG_LOG
    [self recordSearchDiagnosticPhase:@"search-end" details:nil];
#endif
    [self applyKeyboardAttachedStyle:NO];

    if (self.isPresented && !self.isDismissing) {
        [self animateContainerToFrame:[self targetContainerFrame]
                             duration:0.25
                              options:UIViewAnimationOptionCurveEaseOut];
    }
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    self.didUseSearchInCurrentPresentation = YES;
    [self scheduleSearchDisplayItemsUpdate];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    self.didUseSearchInCurrentPresentation = YES;
    [self updateDisplayItems];
    [searchBar resignFirstResponder];
}

#pragma mark - Keyboard

- (void)keyboardWillChangeFrame:(NSNotification *)notification {
    if (!self.isPresented || self.isDismissing) {
        return;
    }

    CGRect keyboardScreenFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect keyboardFrameInView = [self convertScreenRectToOverlayView:keyboardScreenFrame];
    CGRect intersection = CGRectIntersection(self.view.bounds, keyboardFrameInView);
    BOOL keyboardVisible = !CGRectIsNull(intersection) &&
                           !CGRectIsEmpty(intersection) &&
                           intersection.size.height > 0.0 &&
                           CGRectGetMinY(keyboardFrameInView) < CGRectGetMaxY(self.view.bounds);

    self.isKeyboardVisible = keyboardVisible;
    self.keyboardFrameInView = keyboardVisible ? intersection : CGRectZero;

    BOOL keepSearchKeyboardMode =
        self.isSearchEditing && (keyboardVisible || [self searchInputIsFirstResponder]);
#if DEBUG_LOG
    [self recordSearchDiagnosticPhase:@"keyboard-change"
                              details:@{
        @"keyboardVisible": @(keyboardVisible),
        @"keepSearchKeyboardMode": @(keepSearchKeyboardMode),
        @"notificationName": notification.name ?: @""
    }];
#endif
    [self applyKeyboardAttachedStyle:keepSearchKeyboardMode];
    [self animateContainerWithKeyboardUserInfo:notification.userInfo];
}

- (void)keyboardWillHide:(NSNotification *)notification {
    if (!self.isPresented || self.isDismissing) {
        return;
    }

    self.isKeyboardVisible = NO;
    self.keyboardFrameInView = CGRectZero;

    BOOL keepSearchKeyboardMode =
        self.isSearchEditing && [self searchInputIsFirstResponder];
#if DEBUG_LOG
    [self recordSearchDiagnosticPhase:@"keyboard-hide"
                              details:@{
        @"keepSearchKeyboardMode": @(keepSearchKeyboardMode),
        @"notificationName": notification.name ?: @""
    }];
#endif
    if (keepSearchKeyboardMode) {
        [self applyKeyboardAttachedStyle:YES];
        [self animateContainerWithKeyboardUserInfo:notification.userInfo];
        return;
    }

    [self applyKeyboardAttachedStyle:NO];
    [self animateContainerWithKeyboardUserInfo:notification.userInfo];
}

#pragma mark - UIGestureRecognizerDelegate

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer == self.dismissPanGestureRecognizer) {
        CGPoint velocity = [(UIPanGestureRecognizer *)gestureRecognizer velocityInView:self.view];
        return velocity.y > 0.0 && fabs(velocity.y) > fabs(velocity.x);
    }
    if (gestureRecognizer == self.imagePreviewLongPressGestureRecognizer) {
        CGPoint point = [gestureRecognizer locationInView:self.collectionView];
        NSIndexPath *indexPath = [self.collectionView indexPathForItemAtPoint:point];
        if (!indexPath || indexPath.item >= self.displayItems.count) {
            return NO;
        }
        PBClipboardItem *item = self.displayItems[indexPath.item];
        return item.contentType == PBContentTypeImage;
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    CGPoint location = [touch locationInView:self.view];
    if (gestureRecognizer == self.imagePreviewLongPressGestureRecognizer) {
        UIView *touchView = touch.view;
        while (touchView && touchView != self.collectionView) {
            if ([touchView isKindOfClass:[UIControl class]]) {
                return NO;
            }
            touchView = touchView.superview;
        }
        return touchView == self.collectionView;
    }
    if (gestureRecognizer == self.dismissPanGestureRecognizer) {
        UIView *touchView = touch.view;
        if ([touchView isDescendantOfView:self.collectionView] ||
            [touchView isDescendantOfView:self.filterSegment] ||
            [touchView isDescendantOfView:self.cancelButton]) {
            return NO;
        }
        return CGRectContainsPoint(self.containerView.frame, location);
    }
    return !CGRectContainsPoint(self.containerView.frame, location);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    UIGestureRecognizer *otherGesture = nil;
    if (gestureRecognizer == self.dismissPanGestureRecognizer) {
        otherGesture = otherGestureRecognizer;
    } else if (otherGestureRecognizer == self.dismissPanGestureRecognizer) {
        otherGesture = gestureRecognizer;
    }

    return otherGesture && [otherGesture.view isDescendantOfView:self.searchBar];
}

#pragma mark - Status Bar

- (BOOL)prefersStatusBarHidden {
    return NO;
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

@end
