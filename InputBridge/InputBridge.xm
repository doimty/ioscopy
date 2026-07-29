#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "../Manager/PBInputBridge.h"
#import "../Shared/PBPathUtilities.h"
#import "../Shared/PBPreferenceKeys.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <rootless.h>

extern BOOL PBInputBridgeAllowsInternalPasteboardRead;

#if DEBUG_LOG
#define PBInputBridgeHookDebugLog(...) \
    PBDiagnosticLog(PBDiagnosticStreamPasteAuth, @"InputBridgeHook", __VA_ARGS__)
#else
#define PBInputBridgeHookDebugLog(...) do { } while (0)
#endif

static NSString * const kPBIOSCopyOpenViewIdentifier = @"me.tomt000.copylog.showView";
static NSString * const kPBIOSCopyDismissViewIdentifier = @"com.ssdsl.ioscopy/dismissView";
static NSString * const kPBOverlayPresentedIdentifier = @"com.ssdsl.ioscopy/overlayPresented";
static NSString * const kPBOverlayDismissedIdentifier = @"com.ssdsl.ioscopy/overlayDismissed";
static NSString * const kPBPreferencesChangedIdentifier = @"com.ssdsl.ioscopy/prefschanged";
static NSString * const kPBInputBridgeLibSandyProfileName = @"iOSCopyInputBridge";
static NSTimeInterval const kPBOpenTriggerThrottleInterval = 0.65;
static NSTimeInterval const kPBOutsideTouchDismissGraceInterval = 0.35;
static NSInteger const kPBKeyboardLogoImageViewTag = 0x50424C47;

@interface PBKeyboardTriggerController : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, assign) BOOL keyboardVisible;
@property (nonatomic, assign) CGRect lastKeyboardFrame;
+ (instancetype)sharedController;
- (void)start;
- (void)refreshKeyboardTriggersSoon;
- (void)installSwipeGestureInView:(UIView *)view;
@end

static NSDictionary *PBTriggerPreferencesCache = nil;
static NSTimeInterval PBLastOpenTriggerTime = 0.0;
static BOOL PBClipboardOverlayPresented = NO;
static NSTimeInterval PBClipboardOverlayStateChangedAt = 0.0;
static char kPBKeyboardSwipeGestureKey;
static BOOL PBKeyboardDockTriggersInitialized = NO;
static BOOL PBKeyboardLayoutStarTriggersInitialized = NO;
static BOOL PBKeyboardDockViewTriggersInitialized = NO;
static BOOL PBKeyboardDockItemButtonTriggersInitialized = NO;
static BOOL PBUIDictationControllerTriggerInitialized = NO;

static void PBInitializeKeyboardPrivateHooks(void);

static NSString *PBTriggerPreferencesPath(void) {
    return PBIOSCopyMainPreferencesPath();
}

static BOOL PBPathLooksLikeUserApplicationBundle(NSString *path) {
    NSString *standardizedPath = [path.stringByStandardizingPath lowercaseString] ?: @"";
    return [standardizedPath hasPrefix:@"/private/var/containers/bundle/application/"] ||
           [standardizedPath hasPrefix:@"/var/containers/bundle/application/"];
}

static BOOL PBPathLooksLikeSystemOrJailbreakPath(NSString *path) {
    NSString *standardizedPath = [path.stringByStandardizingPath lowercaseString] ?: @"";
    return [standardizedPath hasPrefix:@"/system/"] ||
           [standardizedPath hasPrefix:@"/usr/"] ||
           [standardizedPath hasPrefix:@"/bin/"] ||
           [standardizedPath hasPrefix:@"/sbin/"] ||
           [standardizedPath hasPrefix:@"/applications/"] ||
           [standardizedPath hasPrefix:@"/private/var/jb/"] ||
           [standardizedPath hasPrefix:@"/var/jb/"];
}

static BOOL PBInputBridgeCurrentProcessShouldUseLibSandy(void) {
    NSBundle *mainBundle = [NSBundle mainBundle];
    NSString *bundleId = mainBundle.bundleIdentifier ?: @"";
    NSString *lowerBundleId = bundleId.lowercaseString ?: @"";
    NSString *bundlePath = mainBundle.bundlePath ?: @"";
    NSString *executablePath = mainBundle.executablePath ?: @"";

    if (bundleId.length == 0) {
        return NO;
    }

    if ([lowerBundleId hasPrefix:@"com.apple."] ||
        [lowerBundleId hasPrefix:@"com.appleinternal."]) {
        return NO;
    }

    if (PBPathLooksLikeUserApplicationBundle(bundlePath) ||
        PBPathLooksLikeUserApplicationBundle(executablePath)) {
        return YES;
    }

    // 非 App 容器里的系统或越狱组件直接读写，避免在重启链路中触发 libSandy 通讯。
    if (PBPathLooksLikeSystemOrJailbreakPath(bundlePath) ||
        PBPathLooksLikeSystemOrJailbreakPath(executablePath)) {
        return NO;
    }

    return YES;
}

typedef int (*PBLibSandyApplyProfileFunction)(const char *profileName);
typedef bool (*PBLibSandyWorksFunction)(void);

static void *PBInputBridgeOpenLibSandy(void) {
    void *handle = dlopen("@rpath/libsandy.dylib", RTLD_LAZY | RTLD_LOCAL);
    if (!handle) {
        handle = dlopen(ROOT_PATH("/usr/lib/libsandy.dylib"),
                        RTLD_LAZY | RTLD_LOCAL);
    }
    return handle;
}

extern "C" void PBInputBridgeEnsureSandboxAccess(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!PBInputBridgeCurrentProcessShouldUseLibSandy()) {
#if DEBUG_LOG
            NSString *processName = [[NSProcessInfo processInfo] processName] ?: @"";
            NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
            PBInputBridgeHookDebugLog(@"skip libSandy process=%@ bundle=%@ path=%@",
                                      processName,
                                      bundleId,
                                      [[NSBundle mainBundle] bundlePath] ?: @"");
#endif
            return;
        }

        int result = -1;
        BOOL works = NO;
        void *handle = PBInputBridgeOpenLibSandy();
        if (handle) {
            PBLibSandyApplyProfileFunction applyProfile =
                (PBLibSandyApplyProfileFunction)dlsym(handle,
                                                      "libSandy_applyProfile");
            PBLibSandyWorksFunction sandyWorks =
                (PBLibSandyWorksFunction)dlsym(handle, "libSandy_works");
            if (applyProfile) {
                result = applyProfile(kPBInputBridgeLibSandyProfileName.UTF8String);
            }
            if (sandyWorks) {
                works = sandyWorks();
            }
        }
#if DEBUG_LOG
        NSString *processName = [[NSProcessInfo processInfo] processName] ?: @"";
        NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        NSLog(@"[iOSCopy] libSandy profile=%@ result=%d works=%d process=%@ bundle=%@",
              kPBInputBridgeLibSandyProfileName, result, works, processName, bundleId);
        PBInputBridgeHookDebugLog(@"libSandy profile=%@ result=%d works=%d process=%@ bundle=%@",
                                  kPBInputBridgeLibSandyProfileName, result, works,
                                  processName, bundleId);
#else
        (void)result;
        (void)works;
#endif
    });
}

static void PBReloadTriggerPreferences(void) {
    PBInputBridgeEnsureSandboxAccess();
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:PBTriggerPreferencesPath()];
    PBTriggerPreferencesCache = [prefs isKindOfClass:[NSDictionary class]] ? [prefs copy] : @{};
}

static BOOL PBBoolFromTriggerPreferences(NSString *key, BOOL defaultValue) {
    if (!PBTriggerPreferencesCache) {
        PBReloadTriggerPreferences();
    }

    id value = PBTriggerPreferencesCache[key];
    return value ? [value boolValue] : defaultValue;
}

static BOOL PBTriggerPreferenceEnabled(NSString *key, BOOL defaultValue) {
    if (!PBBoolFromTriggerPreferences(kPBPreferenceEnabled, YES)) {
        return NO;
    }
    return PBBoolFromTriggerPreferences(key, defaultValue);
}

static BOOL PBIOSCopyInputBridgeEnabled(void) {
    return PBBoolFromTriggerPreferences(kPBPreferenceEnabled, YES);
}

static void PBPostOpenViewNotification(void) {
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)kPBIOSCopyOpenViewIdentifier,
        NULL,
        NULL,
        YES
    );
}

static void PBPostDismissViewNotification(void) {
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)kPBIOSCopyDismissViewIdentifier,
        NULL,
        NULL,
        YES
    );
}

static BOOL PBFireOpenTriggerIfNeeded(NSString *preferenceKey, BOOL defaultValue) {
    if (!PBTriggerPreferenceEnabled(preferenceKey, defaultValue)) {
        return NO;
    }

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - PBLastOpenTriggerTime < kPBOpenTriggerThrottleInterval) {
        return YES;
    }

    PBLastOpenTriggerTime = now;
    [PBInputBridge recordOpenTriggerTargetFromRecentInputTarget];
    PBPostOpenViewNotification();
    return YES;
}

static void PBTriggerPreferencesChanged(CFNotificationCenterRef center,
                                        void *observer,
                                        CFNotificationName name,
                                        const void *object,
                                        CFDictionaryRef userInfo) {
    PBReloadTriggerPreferences();
    dispatch_async(dispatch_get_main_queue(), ^{
        [[PBKeyboardTriggerController sharedController] refreshKeyboardTriggersSoon];
    });
}

static void PBOverlayPresentationStateChanged(CFNotificationCenterRef center,
                                              void *observer,
                                              CFNotificationName name,
                                              const void *object,
                                              CFDictionaryRef userInfo) {
    BOOL presented = CFStringCompare(name,
                                     (__bridge CFStringRef)kPBOverlayPresentedIdentifier,
                                     0) == kCFCompareEqualTo;
    PBClipboardOverlayPresented = presented;
    PBClipboardOverlayStateChangedAt = [NSDate timeIntervalSinceReferenceDate];
}

static BOOL PBEventHasBeganTouch(UIEvent *event) {
    if (event.type != UIEventTypeTouches ||
        ![event respondsToSelector:NSSelectorFromString(@"allTouches")]) {
        return NO;
    }

    NSSet<UITouch *> *touches = nil;
    @try {
        touches = [event allTouches];
    } @catch (__unused NSException *exception) {
        return NO;
    }

    for (UITouch *touch in touches) {
        if (touch.phase == UITouchPhaseBegan) {
            return YES;
        }
    }
    return NO;
}

static BOOL PBHandleOverlayOutsideTouchDismiss(UIEvent *event) {
    if (!PBClipboardOverlayPresented || !PBEventHasBeganTouch(event)) {
        return NO;
    }

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - PBClipboardOverlayStateChangedAt < kPBOutsideTouchDismissGraceInterval) {
        return NO;
    }

    PBClipboardOverlayPresented = NO;
    PBClipboardOverlayStateChangedAt = now;
    PBPostDismissViewNotification();
    return YES;
}

static NSString *PBLowercaseStringFromObject(id object) {
    if (![object isKindOfClass:[NSString class]]) {
        return @"";
    }
    return [(NSString *)object lowercaseString] ?: @"";
}

static id PBObjectFromNoArgumentSelector(id object, SEL selector) {
    if (!object || ![object respondsToSelector:selector]) {
        return nil;
    }

    typedef id (*PBObjectMessageSend)(id, SEL);
    PBObjectMessageSend sendMessage = (PBObjectMessageSend)objc_msgSend;
    @try {
        return sendMessage(object, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL PBBoolFromNoArgumentSelector(id object, SEL selector) {
    if (!object || ![object respondsToSelector:selector]) {
        return NO;
    }

    typedef BOOL (*PBBoolMessageSend)(id, SEL);
    PBBoolMessageSend sendMessage = (PBBoolMessageSend)objc_msgSend;
    @try {
        return sendMessage(object, selector);
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static Ivar PBIvarForObject(id object, const char *name) {
    Class currentClass = [object class];
    while (currentClass) {
        Ivar ivar = class_getInstanceVariable(currentClass, name);
        if (ivar) {
            return ivar;
        }
        currentClass = class_getSuperclass(currentClass);
    }
    return NULL;
}

static BOOL PBBoolIvarValue(id object, const char *name) {
    if (!object) {
        return NO;
    }

    Ivar ivar = PBIvarForObject(object, name);
    if (!ivar) {
        return NO;
    }

    const char *encoding = ivar_getTypeEncoding(ivar);
    if (!encoding || (encoding[0] != 'B' && encoding[0] != 'c' && encoding[0] != 'C')) {
        return NO;
    }

    uint8_t *bytes = (uint8_t *)(__bridge void *)object;
    return *(bytes + ivar_getOffset(ivar)) != 0;
}

static BOOL PBStringLooksLikeDictationKey(NSString *value) {
    NSString *lower = PBLowercaseStringFromObject(value);
    if (lower.length == 0) {
        return NO;
    }

    return [lower containsString:@"dictation"] ||
           [lower containsString:@"dictate"] ||
           [lower containsString:@"microphone"] ||
           [lower containsString:@"dictation-key"] ||
           [lower containsString:@"听写"] ||
           [lower containsString:@"聽寫"] ||
           [lower containsString:@"ディクテーション"] ||
           [lower containsString:@"받아쓰기"];
}

static BOOL PBViewLooksLikeDictationKey(UIView *view) {
    if (![view isKindOfClass:[UIView class]]) {
        return NO;
    }

    if (PBBoolIvarValue(view, "m_isForDictation") ||
        PBBoolFromNoArgumentSelector(view, NSSelectorFromString(@"isForDictation")) ||
        PBBoolFromNoArgumentSelector(view, NSSelectorFromString(@"isDictationButton"))) {
        return YES;
    }

    if (PBStringLooksLikeDictationKey(NSStringFromClass([view class])) ||
        PBStringLooksLikeDictationKey(view.accessibilityIdentifier) ||
        PBStringLooksLikeDictationKey(view.accessibilityLabel)) {
        return YES;
    }

    id representedObject = PBObjectFromNoArgumentSelector(view, NSSelectorFromString(@"representedObject"));
    if (representedObject &&
        (PBBoolIvarValue(representedObject, "m_isForDictation") ||
         PBBoolFromNoArgumentSelector(representedObject, NSSelectorFromString(@"isForDictation")) ||
         PBStringLooksLikeDictationKey(NSStringFromClass([representedObject class])))) {
        return YES;
    }

    return NO;
}

static UIImage *PBKeyboardLogoImage(void) {
    static UIImage *image = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *path = ROOT_PATH_NS(@"/Library/Application Support/iOSCopy/Ressources.bundle/keyboardlogo.png");
        image = [UIImage imageWithContentsOfFile:path];
        if (!image) {
            UIImageSymbolConfiguration *configuration =
                [UIImageSymbolConfiguration configurationWithPointSize:22.0
                                                                weight:UIImageSymbolWeightSemibold];
            image = [UIImage systemImageNamed:@"doc.on.clipboard" withConfiguration:configuration];
        }
    });
    return image;
}

static void PBApplyKeyboardLogoToDictationKey(UIView *view) {
    if (!PBTriggerPreferenceEnabled(kPBPreferenceTriggerDictationKey, YES)) {
        UIImageView *existingView = [view viewWithTag:kPBKeyboardLogoImageViewTag];
        [existingView removeFromSuperview];
        return;
    }

    UIImage *logo = PBKeyboardLogoImage();
    if (!logo) {
        return;
    }

    UIImageView *imageView = (UIImageView *)[view viewWithTag:kPBKeyboardLogoImageViewTag];
    if (![imageView isKindOfClass:[UIImageView class]]) {
        imageView = [[UIImageView alloc] initWithImage:logo];
        imageView.tag = kPBKeyboardLogoImageViewTag;
        imageView.userInteractionEnabled = NO;
        imageView.contentMode = UIViewContentModeScaleAspectFit;
        imageView.autoresizingMask =
            UIViewAutoresizingFlexibleLeftMargin |
            UIViewAutoresizingFlexibleRightMargin |
            UIViewAutoresizingFlexibleTopMargin |
            UIViewAutoresizingFlexibleBottomMargin;
        [view addSubview:imageView];
    }

    imageView.image = logo;
    CGRect bounds = view.bounds;
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    if (width <= 0.0 || height <= 0.0) {
        return;
    }

    CGFloat side = MIN(38.0, MAX(24.0, MIN(width, height) * 0.72));
    imageView.frame = CGRectMake((width - side) * 0.5,
                                 (height - side) * 0.5,
                                 side,
                                 side);
    [view bringSubviewToFront:imageView];
}

static void PBApplyDictationLogoInViewTree(UIView *view) {
    if (![view isKindOfClass:[UIView class]]) {
        return;
    }

    if (PBViewLooksLikeDictationKey(view)) {
        PBApplyKeyboardLogoToDictationKey(view);
    }

    for (UIView *subview in view.subviews) {
        PBApplyDictationLogoInViewTree(subview);
    }
}

static BOOL PBWindowLooksLikeKeyboardWindow(UIWindow *window) {
    NSString *className = [NSStringFromClass([window class]) lowercaseString] ?: @"";
    return [className containsString:@"keyboard"] ||
           [className containsString:@"texteffects"] ||
           [className containsString:@"inputset"];
}

static NSArray<UIWindow *> *PBAllApplicationWindows(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    UIApplication *application = [UIApplication sharedApplication];
    for (UIWindow *window in application.windows) {
        if ([window isKindOfClass:[UIWindow class]]) {
            [windows addObject:window];
        }
    }

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in application.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *window in windowScene.windows) {
                if ([window isKindOfClass:[UIWindow class]] && ![windows containsObject:window]) {
                    [windows addObject:window];
                }
            }
        }
    }

    return windows;
}

static NSArray<UIWindow *> *PBKeyboardWindows(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIWindow *window in PBAllApplicationWindows()) {
        if (PBWindowLooksLikeKeyboardWindow(window)) {
            [windows addObject:window];
        }
    }
    return windows;
}

static BOOL PBViewLooksLikeKeyboardKeyCandidate(UIView *view) {
    if (![view isKindOfClass:[UIView class]] ||
        view.hidden ||
        view.alpha < 0.05 ||
        view.tag == kPBKeyboardLogoImageViewTag) {
        return NO;
    }

    CGRect bounds = view.bounds;
    if (CGRectGetWidth(bounds) < 14.0 || CGRectGetHeight(bounds) < 14.0) {
        return NO;
    }

    NSString *className = [NSStringFromClass([view class]) lowercaseString] ?: @"";
    if ([className containsString:@"keyplane"] ||
        [className containsString:@"keyboardlayout"] ||
        [className containsString:@"keyboardwindow"] ||
        [className containsString:@"inputsethost"]) {
        return NO;
    }

    return [view isKindOfClass:[UIControl class]] ||
           [className containsString:@"button"] ||
           [className containsString:@"keyview"] ||
           [className containsString:@"keycap"] ||
           [className containsString:@"keyshape"];
}

static void PBCollectKeyboardKeyFrames(UIView *view,
                                       UIView *rootView,
                                       NSMutableArray<NSValue *> *frames) {
    if (![view isKindOfClass:[UIView class]] || view.hidden || view.alpha < 0.05) {
        return;
    }

    if (PBViewLooksLikeKeyboardKeyCandidate(view)) {
        CGRect frame = [view convertRect:view.bounds toView:rootView];
        CGRect rootBounds = rootView.bounds;
        CGRect intersection = CGRectIntersection(frame, rootBounds);
        if (!CGRectIsNull(intersection) &&
            CGRectGetWidth(intersection) >= 14.0 &&
            CGRectGetHeight(intersection) >= 14.0 &&
            CGRectGetWidth(intersection) <= CGRectGetWidth(rootBounds) * 0.96 &&
            CGRectGetHeight(intersection) <= CGRectGetHeight(rootBounds) * 0.42) {
            [frames addObject:[NSValue valueWithCGRect:intersection]];
        }
    }

    for (UIView *subview in view.subviews) {
        PBCollectKeyboardKeyFrames(subview, rootView, frames);
    }
}

static CGFloat PBKeyboardBottomRowTopY(UIView *rootView) {
    if (![rootView isKindOfClass:[UIView class]]) {
        return CGFLOAT_MAX;
    }

    NSMutableArray<NSValue *> *frames = [NSMutableArray array];
    PBCollectKeyboardKeyFrames(rootView, rootView, frames);
    if (frames.count < 3) {
        return CGFLOAT_MAX;
    }

    CGFloat maxMidY = -CGFLOAT_MAX;
    CGFloat totalHeight = 0.0;
    for (NSValue *value in frames) {
        CGRect frame = value.CGRectValue;
        maxMidY = MAX(maxMidY, CGRectGetMidY(frame));
        totalHeight += CGRectGetHeight(frame);
    }

    CGFloat averageHeight = totalHeight / MAX((CGFloat)frames.count, 1.0);
    CGFloat rowTolerance = MAX(16.0, averageHeight * 0.55);
    CGFloat bottomRowTopY = CGFLOAT_MAX;
    for (NSValue *value in frames) {
        CGRect frame = value.CGRectValue;
        if (fabs(CGRectGetMidY(frame) - maxMidY) <= rowTolerance) {
            bottomRowTopY = MIN(bottomRowTopY, CGRectGetMinY(frame));
        }
    }

    return bottomRowTopY;
}

static BOOL PBKeyboardSwipeTouchIsAboveBottomRow(UIGestureRecognizer *gestureRecognizer,
                                                 UITouch *touch) {
    UIView *view = gestureRecognizer.view;
    if (![view isKindOfClass:[UIView class]]) {
        return YES;
    }

    NSString *className = [NSStringFromClass([view class]) lowercaseString] ?: @"";
    if ([className containsString:@"keyboarddock"]) {
        return NO;
    }

    CGPoint location = [touch locationInView:view];
    CGRect bounds = view.bounds;
    if (!CGRectContainsPoint(bounds, location)) {
        return NO;
    }

    CGFloat bottomRowTopY = PBKeyboardBottomRowTopY(view);
    if (bottomRowTopY != CGFLOAT_MAX &&
        bottomRowTopY > CGRectGetMinY(bounds) &&
        bottomRowTopY < CGRectGetMaxY(bounds)) {
        return location.y < bottomRowTopY;
    }

    // 如果私有键盘层级变化导致无法识别按键，使用视图比例作为保守兜底。
    return location.y < CGRectGetHeight(bounds) * 0.78;
}

static BOOL PBHandleExternalKeyboardShortcut(UIEvent *event) {
    if (!PBTriggerPreferenceEnabled(kPBPreferenceTriggerExternalKeyboardShortcut, YES) ||
        event.type != UIEventTypePresses ||
        ![event respondsToSelector:NSSelectorFromString(@"allPresses")]) {
        return NO;
    }

    typedef NSSet *(*PBPressesMessageSend)(id, SEL);
    PBPressesMessageSend sendPressesMessage = (PBPressesMessageSend)objc_msgSend;
    NSSet *presses = sendPressesMessage(event, NSSelectorFromString(@"allPresses"));
    for (UIPress *press in presses) {
        if (press.phase != UIPressPhaseBegan || !press.key) {
            continue;
        }

        UIKeyModifierFlags flags = press.key.modifierFlags;
        NSString *characters = press.key.charactersIgnoringModifiers ?: press.key.characters;
        if ((flags & UIKeyModifierCommand) &&
            (flags & UIKeyModifierShift) &&
            [[characters lowercaseString] isEqualToString:@"v"]) {
            return PBFireOpenTriggerIfNeeded(kPBPreferenceTriggerExternalKeyboardShortcut, YES);
        }
    }

    return NO;
}

@implementation PBKeyboardTriggerController

+ (instancetype)sharedController {
    static PBKeyboardTriggerController *controller = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controller = [[PBKeyboardTriggerController alloc] init];
    });
    return controller;
}

- (void)start {
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        PBTriggerPreferencesChanged,
        (__bridge CFStringRef)kPBPreferencesChangedIdentifier,
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self
               selector:@selector(keyboardDidChangeFrame:)
                   name:UIKeyboardDidShowNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(keyboardDidChangeFrame:)
                   name:UIKeyboardDidChangeFrameNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(keyboardWillHide:)
                   name:UIKeyboardWillHideNotification
                 object:nil];
}

- (void)keyboardDidChangeFrame:(NSNotification *)notification {
    CGRect frame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    self.lastKeyboardFrame = frame;
    self.keyboardVisible = CGRectGetWidth(frame) > 1.0 && CGRectGetHeight(frame) > 1.0;
    [self refreshKeyboardTriggersSoon];
}

- (void)keyboardWillHide:(NSNotification *)notification {
    self.keyboardVisible = NO;
    self.lastKeyboardFrame = CGRectZero;
}

- (void)refreshKeyboardTriggersSoon {
    PBInitializeKeyboardPrivateHooks();
    dispatch_async(dispatch_get_main_queue(), ^{
        [self refreshKeyboardTriggers];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self refreshKeyboardTriggers];
    });
}

- (void)refreshKeyboardTriggers {
    PBInitializeKeyboardPrivateHooks();
    for (UIWindow *window in PBKeyboardWindows()) {
        [self installSwipeGestureInView:window];
        PBApplyDictationLogoInViewTree(window);
    }
}

- (void)installSwipeGestureInView:(UIView *)view {
    if (![view isKindOfClass:[UIView class]]) {
        return;
    }

    UISwipeGestureRecognizer *gesture =
        objc_getAssociatedObject(view, &kPBKeyboardSwipeGestureKey);
    if (!gesture) {
        gesture = [[UISwipeGestureRecognizer alloc] initWithTarget:self
                                                            action:@selector(handleKeyboardSwipe:)];
        gesture.direction = UISwipeGestureRecognizerDirectionUp;
        gesture.cancelsTouchesInView = NO;
        gesture.delaysTouchesBegan = NO;
        gesture.delaysTouchesEnded = NO;
        gesture.delegate = self;
        [view addGestureRecognizer:gesture];
        objc_setAssociatedObject(view,
                                 &kPBKeyboardSwipeGestureKey,
                                 gesture,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

- (void)handleKeyboardSwipe:(UISwipeGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateRecognized) {
        PBFireOpenTriggerIfNeeded(kPBPreferenceTriggerKeyboardSwipeUp, YES);
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    return PBTriggerPreferenceEnabled(kPBPreferenceTriggerKeyboardSwipeUp, YES) &&
           PBKeyboardSwipeTouchIsAboveBottomRow(gestureRecognizer, touch);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

@end

static void PBRefreshKeyboardViewTriggers(UIView *view) {
    if (![view isKindOfClass:[UIView class]]) {
        return;
    }

    [[PBKeyboardTriggerController sharedController] installSwipeGestureInView:view];
    PBApplyDictationLogoInViewTree(view);
}

static BOOL PBIsSpringBoardProcess(NSString *processName, NSString *bundleId) {
    return [bundleId isEqualToString:@"com.apple.springboard"] ||
           [processName isEqualToString:@"SpringBoard"];
}

static BOOL PBIsDockXCopyLogDylibPath(NSString *path) {
    if (![path isKindOfClass:[NSString class]]) {
        return NO;
    }

    return [path isEqualToString:@"/Library/MobileSubstrate/DynamicLibraries/CopyLog.dylib"] ||
           [path isEqualToString:@"/var/jb/Library/MobileSubstrate/DynamicLibraries/CopyLog.dylib"];
}

static void PBRecordEditableResponderIfPossible(id responder) {
    if ([responder isKindOfClass:[UIResponder class]]) {
        [PBInputBridge recordRecentEditableResponder:(UIResponder *)responder];
    }
}

#if DEBUG_LOG
static BOOL PBProcessLooksLikeImagePasteTarget(NSString *bundleId, NSString *processName) {
    NSString *lowerBundleId = [bundleId.lowercaseString copy] ?: @"";
    NSString *lowerProcessName = [processName.lowercaseString copy] ?: @"";
    return [lowerBundleId containsString:@"tencent"] ||
           [lowerBundleId containsString:@"mqq"] ||
           [lowerBundleId containsString:@"micromessenger"] ||
           [lowerBundleId containsString:@"wechat"] ||
           [lowerBundleId containsString:@"telegram"] ||
           [lowerBundleId containsString:@"telegraph"] ||
           [lowerBundleId containsString:@"ph.telegra"] ||
           [lowerBundleId containsString:@"org.telegram"] ||
           [lowerBundleId containsString:@"whatsapp"] ||
           [lowerProcessName containsString:@"qq"] ||
           [lowerProcessName containsString:@"mqq"] ||
           [lowerProcessName containsString:@"wechat"] ||
           [lowerProcessName containsString:@"telegram"] ||
           [lowerProcessName containsString:@"whatsapp"];
}
#endif

#if DEBUG_LOG
static void PBLogPasteboardSetter(NSString *selectorName, id pasteboard) {
    PBInputBridgeHookDebugLog(@"setter=%@ pasteboard=%p class=%@ bundle=%@ process=%@",
                              selectorName,
                              pasteboard,
                              NSStringFromClass([pasteboard class]),
                              [[NSBundle mainBundle] bundleIdentifier] ?: @"",
                              [[NSProcessInfo processInfo] processName] ?: @"");
    PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(@"inputbridge-setter"
                                                details:@{
                                                    @"selector": selectorName ?: @"",
                                                    @"pasteboardPointer": [NSString stringWithFormat:@"%p", pasteboard],
                                                    @"pasteboardClass": pasteboard ? NSStringFromClass([pasteboard class]) : @"",
                                                    @"bundleId": [[NSBundle mainBundle] bundleIdentifier] ?: @"",
                                                    @"processName": [[NSProcessInfo processInfo] processName] ?: @""
                                                });
}
#else
#define PBLogPasteboardSetter(...) do { } while (0)
#endif

static NSData *PBImageMarkerFromImage(UIImage *image) {
    if (![image isKindOfClass:[UIImage class]]) {
        return nil;
    }
    return [NSData data];
}

static NSString *PBTextFromObject(id object) {
    if ([object isKindOfClass:[NSString class]]) {
        return [(NSString *)object length] > 0 ? object : nil;
    }
    if ([object isKindOfClass:[NSURL class]]) {
        NSString *text = [(NSURL *)object absoluteString];
        return text.length > 0 ? text : nil;
    }
    if ([object isKindOfClass:[NSAttributedString class]]) {
        NSString *text = [(NSAttributedString *)object string];
        return text.length > 0 ? text : nil;
    }
    return nil;
}

static BOOL PBPasteboardTypeLooksText(NSString *type) {
    NSString *lower = [type lowercaseString];
    return ![lower containsString:@"html"] &&
           ([lower containsString:@"text"] ||
            [lower containsString:@"string"] ||
            [lower containsString:@"utf8"] ||
            [lower containsString:@"url"]);
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

static NSInteger PBTypePriorityForCapture(NSString *type) {
    if (PBPasteboardTypeLooksImage(type)) {
        return 0;
    }
    if (PBPasteboardTypeLooksPlainText(type)) {
        return 1;
    }
    if (PBPasteboardTypeLooksText(type)) {
        return 2;
    }
    if (PBPasteboardTypeLooksHTML(type)) {
        return 3;
    }
    return 4;
}

static NSArray *PBSortedTypeDictionaryKeys(NSDictionary *types) {
    return [[types allKeys] sortedArrayUsingComparator:^NSComparisonResult(id firstKey, id secondKey) {
        NSString *firstType = [firstKey isKindOfClass:[NSString class]] ? firstKey : [firstKey description];
        NSString *secondType = [secondKey isKindOfClass:[NSString class]] ? secondKey : [secondKey description];
        NSInteger firstPriority = PBTypePriorityForCapture(firstType ?: @"");
        NSInteger secondPriority = PBTypePriorityForCapture(secondType ?: @"");
        if (firstPriority < secondPriority) {
            return NSOrderedAscending;
        }
        if (firstPriority > secondPriority) {
            return NSOrderedDescending;
        }
        return [firstType compare:secondType ?: @""];
    }];
}

static NSDictionary *PBCaptureFromTypedValue(id value, NSString *type) {
    NSString *text = PBTextFromObject(value);
    if (text.length > 0) {
        if (PBPasteboardTypeLooksHTML(type)) {
            NSString *plainText = PBPlainTextFromHTMLString(text);
            return plainText.length > 0 ? @{@"content": plainText} : nil;
        }
        return @{@"content": text};
    }

    if ([value isKindOfClass:[UIImage class]]) {
        NSData *imageData = PBImageMarkerFromImage(value);
        if (imageData) {
            return @{@"imageData": imageData};
        }
    }

    if ([value isKindOfClass:[NSData class]]) {
        NSData *data = (NSData *)value;
        if (PBPasteboardTypeLooksHTML(type)) {
            NSString *htmlText = PBTextFromData(data);
            NSString *plainText = PBPlainTextFromHTMLString(htmlText);
            return plainText.length > 0 ? @{@"content": plainText} : nil;
        }
        if (PBPasteboardTypeLooksText(type)) {
            NSString *dataText = PBTextFromData(data);
            if (dataText.length > 0) {
                return @{@"content": dataText};
            }
        }
        if (PBPasteboardTypeLooksImage(type)) {
            return @{@"imageData": data};
        }
    }

    return nil;
}

static NSDictionary *PBCaptureFromItems(NSArray *items) {
    if (![items isKindOfClass:[NSArray class]]) {
        return nil;
    }

    NSDictionary *imageCapture = nil;
    for (id item in items) {
        NSDictionary *capture = PBCaptureFromTypedValue(item, @"");
        if (capture[@"content"]) {
            return capture;
        }
        if (capture[@"imageData"] && !imageCapture) {
            imageCapture = capture;
        }

        if ([item isKindOfClass:[NSDictionary class]]) {
            NSDictionary *dict = (NSDictionary *)item;
            for (id key in PBSortedTypeDictionaryKeys(dict)) {
                NSString *type = [key isKindOfClass:[NSString class]] ? key : [key description];
                NSDictionary *typedCapture = PBCaptureFromTypedValue(dict[key], type ?: @"");
                if (typedCapture[@"content"]) {
                    return typedCapture;
                }
                if (typedCapture[@"imageData"] && !imageCapture) {
                    imageCapture = typedCapture;
                }
            }
        }
    }

    return imageCapture;
}

static NSDictionary *PBCaptureFromObjects(NSArray *objects) {
    if (![objects isKindOfClass:[NSArray class]]) {
        return nil;
    }

    NSDictionary *imageCapture = nil;
    for (id object in objects) {
        NSDictionary *capture = PBCaptureFromTypedValue(object, @"");
        if (capture[@"content"]) {
            return capture;
        }
        if (capture[@"imageData"] && !imageCapture) {
            imageCapture = capture;
        }
    }

    return imageCapture;
}

static void PBRecordPasteboardCapture(NSString *selectorName,
                                      id pasteboard,
                                      NSString *content,
                                      NSData *imageData) {
    if (PBInputBridgeAllowsInternalPasteboardRead) {
        PBInputBridgeHookDebugLog(@"skip source capture for internal paste setter=%@ bundle=%@ process=%@",
                                  selectorName,
                                  [[NSBundle mainBundle] bundleIdentifier] ?: @"",
                                  [[NSProcessInfo processInfo] processName] ?: @"");
        return;
    }
    if (!PBIOSCopyInputBridgeEnabled()) {
        return;
    }

    PBLogPasteboardSetter(selectorName, pasteboard);
    [PBInputBridge recordPasteboardSourceWithPasteboard:pasteboard
                                               content:content
                                             imageData:imageData];

    NSInteger changeCount = -1;
    @try {
        if ([pasteboard respondsToSelector:@selector(changeCount)]) {
            changeCount = ((NSInteger (*)(id, SEL))objc_msgSend)(pasteboard, @selector(changeCount));
        } else {
            changeCount = [UIPasteboard generalPasteboard].changeCount;
        }
    } @catch (__unused NSException *exception) {
        changeCount = -1;
    }

    if (changeCount >= 0) {
        NSDictionary *sourceInfo = [PBInputBridge recentPasteboardSourceInfoForChangeCount:changeCount];
        [PBInputBridge requestSpringBoardPasteboardCaptureWithReason:@"app"
                                                         changeCount:changeCount
                                                          sourceInfo:sourceInfo];
    }
}

static void PBRecordPasteboardCaptureFromDictionary(NSString *selectorName,
                                                    id pasteboard,
                                                    NSDictionary *capture) {
    PBRecordPasteboardCapture(selectorName,
                              pasteboard,
                              capture[@"content"],
                              capture[@"imageData"]);
}

static void PBRecordPasteboardCaptureFromItemProviders(NSString *selectorName,
                                                       id pasteboard,
                                                       NSArray *itemProviders) {
    if (PBInputBridgeAllowsInternalPasteboardRead) {
        PBInputBridgeHookDebugLog(@"skip item provider capture for internal paste setter=%@ bundle=%@ process=%@",
                                  selectorName,
                                  [[NSBundle mainBundle] bundleIdentifier] ?: @"",
                                  [[NSProcessInfo processInfo] processName] ?: @"");
        return;
    }
    if (!PBIOSCopyInputBridgeEnabled()) {
        return;
    }

    PBLogPasteboardSetter(selectorName, pasteboard);
    if (![itemProviders isKindOfClass:[NSArray class]] || itemProviders.count == 0) {
        PBRecordPasteboardCapture(selectorName, pasteboard, nil, nil);
        return;
    }

    BOOL hasImageProvider = NO;
    for (id provider in itemProviders) {
        NSArray *typeIdentifiers = nil;
        if ([provider respondsToSelector:@selector(registeredTypeIdentifiers)]) {
            typeIdentifiers = [provider registeredTypeIdentifiers];
        }
        PBInputBridgeHookDebugLog(@"item provider setter=%@ provider=%@ types=%@",
                                  selectorName,
                                  NSStringFromClass([provider class]),
                                  typeIdentifiers);

        for (NSString *typeIdentifier in typeIdentifiers) {
            if (![typeIdentifier isKindOfClass:[NSString class]] ||
                !PBPasteboardTypeLooksImage(typeIdentifier)) {
                continue;
            }
            hasImageProvider = YES;
            break;
        }
        if (hasImageProvider) {
            break;
        }
    }

    PBRecordPasteboardCapture(selectorName, pasteboard, nil, nil);
}

static BOOL PBRunPastePolicyAuthorization(NSString *policyName,
                                          id pasteboardName,
                                          long long dataPurpose,
                                          void (^completionHandler)(BOOL, NSError *)) {
    NSString *authorizationReason = completionHandler
        ? [PBInputBridge consumePasteboardReadAuthorizationForPasteboardName:pasteboardName
                                                                  policyName:policyName
                                                                 dataPurpose:dataPurpose]
        : nil;
    if (!completionHandler || authorizationReason.length == 0) {
#if DEBUG_LOG
        NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        NSString *processName = [[NSProcessInfo processInfo] processName] ?: @"";
        if (PBProcessLooksLikeImagePasteTarget(bundleId, processName)) {
            PB_RECORD_IMAGE_PASTE_DIAGNOSTIC(@"policy-miss"
                                                requestId:nil
                                                  details:@{
                @"policyName": policyName ?: @"",
                @"pasteboardName": [pasteboardName description] ?: @"",
                @"dataPurpose": @(dataPurpose),
                @"hasAuthorization": @([PBInputBridge hasOneShotPasteboardReadAuthorization]),
                @"hasRecentRequest": @([PBInputBridge hasRecentPasteRequestForCurrentProcess])
            });
        }
#endif
        return NO;
    }

    PBInputBridgeHookDebugLog(@"allow paste policy=%@ reason=%@ name=%@ purpose=%lld bundle=%@ process=%@",
                              policyName ?: @"",
                              authorizationReason ?: @"",
                              pasteboardName,
                              dataPurpose,
                              [[NSBundle mainBundle] bundleIdentifier] ?: @"",
                              [[NSProcessInfo processInfo] processName] ?: @"");
    PB_RECORD_IMAGE_PASTE_DIAGNOSTIC(@"policy-allow"
                                        requestId:nil
                                          details:@{
        @"policyName": policyName ?: @"",
        @"pasteboardName": [pasteboardName description] ?: @"",
        @"dataPurpose": @(dataPurpose),
        @"authorizationReason": authorizationReason ?: @"",
        @"hasAuthorization": @([PBInputBridge hasOneShotPasteboardReadAuthorization]),
        @"hasRecentRequest": @([PBInputBridge hasRecentPasteRequestForCurrentProcess])
    });
    completionHandler(YES, nil);
    return YES;
}

%group PBDockXCompatibility

%hook DXShortcutsGenerator

- (BOOL)dylibExist:(NSString *)dylibPath manager:(NSFileManager *)fileManager {
    if (PBIsDockXCopyLogDylibPath(dylibPath)) {
        return YES;
    }

    return %orig;
}

- (BOOL)copyLogDylibExist {
    return YES;
}

%end

%end

%group PBKeyboardLayoutStarTriggers

%hook UIKeyboardLayoutStar

- (void)didMoveToWindow {
    %orig;
    PBRefreshKeyboardViewTriggers((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    PBRefreshKeyboardViewTriggers((UIView *)self);
}

%end

%end

%group PBKeyboardDockViewTriggers

%hook UIKeyboardDockView

- (void)didMoveToWindow {
    %orig;
    PBRefreshKeyboardViewTriggers((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    PBRefreshKeyboardViewTriggers((UIView *)self);
}

%end

%end

%group PBKeyboardDockItemButtonTriggers

%hook UIKeyboardDockItemButton

- (void)didMoveToWindow {
    %orig;
    if (PBViewLooksLikeDictationKey((UIView *)self)) {
        PBApplyKeyboardLogoToDictationKey((UIView *)self);
    }
}

- (void)layoutSubviews {
    %orig;
    if (PBViewLooksLikeDictationKey((UIView *)self)) {
        PBApplyKeyboardLogoToDictationKey((UIView *)self);
    }
}

- (void)sendAction:(SEL)action to:(id)target forEvent:(UIEvent *)event {
    if (PBViewLooksLikeDictationKey((UIView *)self) &&
        PBFireOpenTriggerIfNeeded(kPBPreferenceTriggerDictationKey, YES)) {
        return;
    }

    %orig;
}

%end

%end

%group PBKeyboardDockTriggers

%hook UISystemKeyboardDockController

- (BOOL)shouldShowDictationKey {
    if (PBTriggerPreferenceEnabled(kPBPreferenceTriggerDictationKey, YES)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[PBKeyboardTriggerController sharedController] refreshKeyboardTriggersSoon];
        });
        return YES;
    }

    return %orig;
}

- (void)dictationItemButtonWasPressed:(id)arg1 withEvent:(id)arg2 {
    if (PBFireOpenTriggerIfNeeded(kPBPreferenceTriggerDictationKey, YES)) {
        return;
    }

    %orig;
}

- (void)dictationItemButtonWasPressed:(id)arg1 withEvent:(id)arg2 isRunningButton:(BOOL)arg3 {
    if (PBFireOpenTriggerIfNeeded(kPBPreferenceTriggerDictationKey, YES)) {
        return;
    }

    %orig;
}

%end

%end

%hook UIApplication

- (void)sendEvent:(UIEvent *)event {
    PBInitializeKeyboardPrivateHooks();
    if (PBHandleExternalKeyboardShortcut(event)) {
        return;
    }
    if (PBHandleOverlayOutsideTouchDismiss(event)) {
        return;
    }

    %orig;
}

- (BOOL)sendAction:(SEL)action to:(id)target from:(id)sender forEvent:(UIEvent *)event {
    NSString *actionName = NSStringFromSelector(action).lowercaseString ?: @"";
    BOOL dictationAction = [actionName containsString:@"dictation"] ||
                           [actionName containsString:@"dictate"];
    BOOL dictationSender = [sender isKindOfClass:[UIView class]] &&
                           PBViewLooksLikeDictationKey((UIView *)sender);

    if ((dictationAction || dictationSender) &&
        PBFireOpenTriggerIfNeeded(kPBPreferenceTriggerDictationKey, YES)) {
        return YES;
    }

    return %orig;
}

%end

%group PBUIDictationControllerTrigger

%hook UIDictationController

- (void)startDictation {
    if (PBFireOpenTriggerIfNeeded(kPBPreferenceTriggerDictationKey, YES)) {
        return;
    }

    %orig;
}

%end

%end

%hook UIResponder

- (BOOL)becomeFirstResponder {
    BOOL became = %orig;
    if (became || self.isFirstResponder) {
        PBRecordEditableResponderIfPossible(self);
    }
    return became;
}

%end

%hook UITextField

- (BOOL)becomeFirstResponder {
    BOOL became = %orig;
    if (became || self.isFirstResponder) {
        PBRecordEditableResponderIfPossible(self);
    }
    return became;
}

%end

%hook UITextView

- (BOOL)becomeFirstResponder {
    BOOL became = %orig;
    if (became || self.isFirstResponder) {
        PBRecordEditableResponderIfPossible(self);
    }
    return became;
}

%end

static void PBInitializeKeyboardPrivateHooks(void) {
    Class keyboardDockControllerClass = NSClassFromString(@"UISystemKeyboardDockController");
    if (keyboardDockControllerClass && !PBKeyboardDockTriggersInitialized) {
        PBKeyboardDockTriggersInitialized = YES;
        %init(PBKeyboardDockTriggers, UISystemKeyboardDockController=keyboardDockControllerClass);
    }

    Class keyboardLayoutStarClass = NSClassFromString(@"UIKeyboardLayoutStar");
    if (keyboardLayoutStarClass && !PBKeyboardLayoutStarTriggersInitialized) {
        PBKeyboardLayoutStarTriggersInitialized = YES;
        %init(PBKeyboardLayoutStarTriggers, UIKeyboardLayoutStar=keyboardLayoutStarClass);
    }

    Class keyboardDockViewClass = NSClassFromString(@"UIKeyboardDockView");
    if (keyboardDockViewClass && !PBKeyboardDockViewTriggersInitialized) {
        PBKeyboardDockViewTriggersInitialized = YES;
        %init(PBKeyboardDockViewTriggers, UIKeyboardDockView=keyboardDockViewClass);
    }

    Class keyboardDockItemButtonClass = NSClassFromString(@"UIKeyboardDockItemButton");
    if (keyboardDockItemButtonClass && !PBKeyboardDockItemButtonTriggersInitialized) {
        PBKeyboardDockItemButtonTriggersInitialized = YES;
        %init(PBKeyboardDockItemButtonTriggers, UIKeyboardDockItemButton=keyboardDockItemButtonClass);
    }

    Class dictationControllerClass = NSClassFromString(@"UIDictationController");
    if (dictationControllerClass && !PBUIDictationControllerTriggerInitialized) {
        PBUIDictationControllerTriggerInitialized = YES;
        %init(PBUIDictationControllerTrigger, UIDictationController=dictationControllerClass);
    }
}

%hook UIPasteboard

- (void)_checkPolicyForPasteboardName:(id)arg1 dataPurpose:(long long)arg2 options:(id)arg3 completionHandler:(void (^)(BOOL, NSError *))arg4 {
    if (PBRunPastePolicyAuthorization(@"dataPurpose", arg1, arg2, arg4)) {
        return;
    }

    %orig;
}

- (void)_checkPolicyForPasteboardName:(id)arg1 options:(id)arg2 completionHandler:(void (^)(BOOL, NSError *))arg3 {
    if (PBRunPastePolicyAuthorization(@"options", arg1, -1, arg3)) {
        return;
    }

    %orig;
}

- (void)_checkPolicyForPasteboardName:(id)arg1 completionHandler:(void (^)(BOOL, NSError *))arg2 {
    if (PBRunPastePolicyAuthorization(@"completion", arg1, -1, arg2)) {
        return;
    }

    %orig;
}

- (void)_checkPolicyForPasteboardName:(id)arg1 withCompletionHandler:(void (^)(BOOL, NSError *))arg2 {
    if (PBRunPastePolicyAuthorization(@"withCompletion", arg1, -1, arg2)) {
        return;
    }

    %orig;
}

- (void)setString:(NSString *)string {
    %orig;
    PBRecordPasteboardCapture(@"setString:", self, string, nil);
}

- (void)setStrings:(NSArray<NSString *> *)strings {
    %orig;
    PBRecordPasteboardCaptureFromDictionary(@"setStrings:", self, PBCaptureFromObjects(strings));
}

- (void)setURL:(NSURL *)URL {
    %orig;
    PBRecordPasteboardCapture(@"setURL:", self, PBTextFromObject(URL), nil);
}

- (void)setURLs:(NSArray<NSURL *> *)URLs {
    %orig;
    PBRecordPasteboardCaptureFromDictionary(@"setURLs:", self, PBCaptureFromObjects(URLs));
}

- (void)setImage:(UIImage *)image {
    %orig;
    PBRecordPasteboardCapture(@"setImage:", self, nil, PBImageMarkerFromImage(image));
}

- (void)setImages:(NSArray<UIImage *> *)images {
    %orig;
    PBRecordPasteboardCaptureFromDictionary(@"setImages:", self, PBCaptureFromObjects(images));
}

- (void)setItems:(NSArray *)items {
    %orig;
    PBRecordPasteboardCaptureFromDictionary(@"setItems:", self, PBCaptureFromItems(items));
}

- (void)setItems:(NSArray *)items options:(NSDictionary *)options {
    %orig;
    PBRecordPasteboardCaptureFromDictionary(@"setItems:options:", self, PBCaptureFromItems(items));
}

- (void)setObjects:(NSArray *)objects {
    %orig;
    PBRecordPasteboardCaptureFromDictionary(@"setObjects:", self, PBCaptureFromObjects(objects));
}

- (void)setObjects:(NSArray *)objects localOnly:(BOOL)localOnly expirationDate:(NSDate *)expirationDate {
    %orig;
    PBRecordPasteboardCaptureFromDictionary(@"setObjects:localOnly:expirationDate:", self, PBCaptureFromObjects(objects));
}

- (void)setItemProviders:(NSArray *)itemProviders localOnly:(BOOL)localOnly expirationDate:(NSDate *)expirationDate {
    %orig;
    PBRecordPasteboardCaptureFromItemProviders(@"setItemProviders:localOnly:expirationDate:", self, itemProviders);
}

- (void)setValue:(id)value forPasteboardType:(NSString *)pasteboardType {
    %orig;
    PBRecordPasteboardCaptureFromDictionary(@"setValue:forPasteboardType:", self, PBCaptureFromTypedValue(value, pasteboardType ?: @""));
}

- (void)setData:(NSData *)data forPasteboardType:(NSString *)pasteboardType {
    %orig;
    PBRecordPasteboardCaptureFromDictionary(@"setData:forPasteboardType:", self, PBCaptureFromTypedValue(data, pasteboardType ?: @""));
}

%end

%hook _UIConcretePasteboard

- (void)setString:(NSString *)string {
    %orig;
    PBRecordPasteboardCapture(@"_UIConcrete setString:", self, string, nil);
}

- (void)setStrings:(NSArray<NSString *> *)strings {
    %orig;
    PBRecordPasteboardCaptureFromDictionary(@"_UIConcrete setStrings:", self, PBCaptureFromObjects(strings));
}

- (void)setURL:(NSURL *)URL {
    %orig;
    PBRecordPasteboardCapture(@"_UIConcrete setURL:", self, PBTextFromObject(URL), nil);
}

- (void)setURLs:(NSArray<NSURL *> *)URLs {
    %orig;
    PBRecordPasteboardCaptureFromDictionary(@"_UIConcrete setURLs:", self, PBCaptureFromObjects(URLs));
}

- (void)setImage:(UIImage *)image {
    %orig;
    PBRecordPasteboardCapture(@"_UIConcrete setImage:", self, nil, PBImageMarkerFromImage(image));
}

- (void)setImages:(NSArray<UIImage *> *)images {
    %orig;
    PBRecordPasteboardCaptureFromDictionary(@"_UIConcrete setImages:", self, PBCaptureFromObjects(images));
}

- (void)setItems:(NSArray *)items {
    %orig;
    PBRecordPasteboardCaptureFromDictionary(@"_UIConcrete setItems:", self, PBCaptureFromItems(items));
}

- (void)setItems:(NSArray *)items options:(NSDictionary *)options {
    %orig;
    PBRecordPasteboardCaptureFromDictionary(@"_UIConcrete setItems:options:", self, PBCaptureFromItems(items));
}

- (void)setObjects:(NSArray *)objects {
    %orig;
    PBRecordPasteboardCaptureFromDictionary(@"_UIConcrete setObjects:", self, PBCaptureFromObjects(objects));
}

- (void)setObjects:(NSArray *)objects localOnly:(BOOL)localOnly expirationDate:(NSDate *)expirationDate {
    %orig;
    PBRecordPasteboardCaptureFromDictionary(@"_UIConcrete setObjects:localOnly:expirationDate:", self, PBCaptureFromObjects(objects));
}

- (void)setItemProviders:(NSArray *)itemProviders localOnly:(BOOL)localOnly expirationDate:(NSDate *)expirationDate {
    %orig;
    PBRecordPasteboardCaptureFromItemProviders(@"_UIConcrete setItemProviders:localOnly:expirationDate:", self, itemProviders);
}

- (void)setValue:(id)value forPasteboardType:(NSString *)pasteboardType {
    %orig;
    PBRecordPasteboardCaptureFromDictionary(@"_UIConcrete setValue:forPasteboardType:", self, PBCaptureFromTypedValue(value, pasteboardType ?: @""));
}

- (void)setData:(NSData *)data forPasteboardType:(NSString *)pasteboardType {
    %orig;
    PBRecordPasteboardCaptureFromDictionary(@"_UIConcrete setData:forPasteboardType:", self, PBCaptureFromTypedValue(data, pasteboardType ?: @""));
}

%end

%ctor {
    @autoreleasepool {
        NSString *processName = [[NSProcessInfo processInfo] processName];
        NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];

        if (PBIsSpringBoardProcess(processName, bundleId)) return;

        Class dockXShortcutsGeneratorClass = NSClassFromString(@"DXShortcutsGenerator");
        if (dockXShortcutsGeneratorClass) {
            %init(PBDockXCompatibility, DXShortcutsGenerator=dockXShortcutsGeneratorClass);
        }

        PBInitializeKeyboardPrivateHooks();
        %init;
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            PBOverlayPresentationStateChanged,
            (__bridge CFStringRef)kPBOverlayPresentedIdentifier,
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            PBOverlayPresentationStateChanged,
            (__bridge CFStringRef)kPBOverlayDismissedIdentifier,
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );
        [[PBKeyboardTriggerController sharedController] start];
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UITextFieldTextDidBeginEditingNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *notification) {
            PBRecordEditableResponderIfPossible(notification.object);
        }];
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UITextViewTextDidBeginEditingNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *notification) {
            PBRecordEditableResponderIfPossible(notification.object);
        }];
        [PBInputBridge startListeningForInsertRequests];
    }
}
