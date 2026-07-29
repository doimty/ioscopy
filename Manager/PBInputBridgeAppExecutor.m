#import "PBInputBridgePrivate.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const kPBPluginPasteThreadRequestIdKey =
    @"com.ssdsl.ioscopy.pluginPasting.requestId";
static NSString *kPBLastHandledRequestId = nil;
#if DEBUG_LOG
static NSString *kPBLastTextInsertSelectorProbeRequestId = nil;
#endif
static __weak UIResponder *kPBRecentEditableResponder = nil;
static NSTimeInterval kPBRecentEditableResponderRecordedAt = 0;
static NSString *kPBActivePasteRequestId = nil;
static NSString *kPBActivePasteTargetBundleId = nil;
static NSMutableDictionary<NSString *, NSNumber *> *kPBInsertRetryCounts = nil;
static NSMutableSet<NSString *> *kPBResponderRestoreSettledRequestIds = nil;
static NSUInteger kPBInternalPasteboardReadWindowGeneration = 0;
static NSTimeInterval kPBActivePasteWindowStartedAt = 0;
static NSInteger kPBActivePastePolicyAllowCount = 0;

#if DEBUG_LOG
static BOOL PBSelectorNameMatchesTextInsertProbe(NSString *selectorName) {
  if (selectorName.length == 0) {
    return NO;
  }

  NSString *lowerName = [selectorName lowercaseString];
  NSArray<NSString *> *keywords = @[
    @"insert", @"text", @"input", @"key", @"commit", @"handle", @"delete",
    @"replace", @"selection", @"candidate", @"keyboard", @"document"
  ];
  for (NSString *keyword in keywords) {
    if ([lowerName containsString:keyword]) {
      return YES;
    }
  }
  return NO;
}

static NSArray<NSDictionary *> *
PBTextInsertMatchingSelectorsForClass(Class cls, BOOL includeSuperclasses,
                                      NSUInteger maxCount) {
  if (!cls || maxCount == 0) {
    return @[];
  }

  NSMutableArray<NSDictionary *> *selectors = [NSMutableArray array];
  Class currentClass = cls;
  NSUInteger depth = 0;
  while (currentClass && depth < 8 && selectors.count < maxCount) {
    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(currentClass, &methodCount);
    for (unsigned int index = 0;
         methods && index < methodCount && selectors.count < maxCount;
         index++) {
      SEL selector = method_getName(methods[index]);
      NSString *selectorName = NSStringFromSelector(selector);
      if (!PBSelectorNameMatchesTextInsertProbe(selectorName)) {
        continue;
      }

      const char *typeEncoding = method_getTypeEncoding(methods[index]);
      [selectors addObject:@{
        @"class" : NSStringFromClass(currentClass) ?: @"",
        @"selector" : selectorName ?: @"",
        @"args" : @(method_getNumberOfArguments(methods[index])),
        @"types" : typeEncoding
            ? [NSString stringWithUTF8String:typeEncoding] ?: @""
            : @""
      }];
    }
    if (methods) {
      free(methods);
    }

    if (!includeSuperclasses) {
      break;
    }
    currentClass = class_getSuperclass(currentClass);
    depth++;
  }

  return selectors;
}

static NSArray<NSString *> *
PBTextInsertSelectorNameSampleForClass(Class cls, BOOL includeSuperclasses,
                                       NSUInteger maxCount) {
  if (!cls || maxCount == 0) {
    return @[];
  }

  NSMutableArray<NSString *> *selectorNames = [NSMutableArray array];
  Class currentClass = cls;
  NSUInteger depth = 0;
  while (currentClass && depth < 6 && selectorNames.count < maxCount) {
    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(currentClass, &methodCount);
    for (unsigned int index = 0;
         methods && index < methodCount && selectorNames.count < maxCount;
         index++) {
      NSString *selectorName =
          NSStringFromSelector(method_getName(methods[index]));
      if (selectorName.length > 0) {
        [selectorNames
            addObject:[NSString stringWithFormat:@"%@ %@",
                                                 NSStringFromClass(currentClass)
                                                     ?: @"",
                                                 selectorName]];
      }
    }
    if (methods) {
      free(methods);
    }

    if (!includeSuperclasses) {
      break;
    }
    currentClass = class_getSuperclass(currentClass);
    depth++;
  }

  return selectorNames;
}

static id PBTextInsertObjectForNoArgSelector(id object, SEL selector,
                                             NSString **exceptionReason) {
  if (exceptionReason) {
    *exceptionReason = nil;
  }
  if (!object || ![object respondsToSelector:selector]) {
    return nil;
  }

  id (*sendObject)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
  @try {
    return sendObject(object, selector);
  } @catch (NSException *exception) {
    if (exceptionReason) {
      *exceptionReason = exception.reason ?: [exception description] ?: @"";
    }
    return nil;
  }
}

static NSDictionary *
PBTextInsertObjectProbeDetails(id object, NSString *label,
                               BOOL includeSelectorSample) {
  NSMutableDictionary *details = [NSMutableDictionary dictionary];
  NSString *prefix = label.length > 0 ? label : @"object";
  NSString *classKey = [NSString stringWithFormat:@"%@Class", prefix];
  NSString *matchingKey =
      [NSString stringWithFormat:@"%@MatchingSelectors", prefix];
  NSString *sampleKey = [NSString stringWithFormat:@"%@SelectorSample", prefix];
  NSString *hasObjectKey = [NSString stringWithFormat:@"%@Present", prefix];

  details[hasObjectKey] = @(object != nil);
  details[classKey] = object ? NSStringFromClass([object class]) ?: @"" : @"";
  if (object) {
    details[matchingKey] =
        PBTextInsertMatchingSelectorsForClass([object class], YES, 160);
    if (includeSelectorSample) {
      details[sampleKey] =
          PBTextInsertSelectorNameSampleForClass([object class], YES, 220);
    }
  }

  return details;
}

static NSDictionary *
PBTextInsertKeyboardSelectorProbeDetails(Class keyboardClass, id keyboard,
                                         UIResponder *responder) {
  NSMutableDictionary *details = [NSMutableDictionary dictionary];
  details[@"keyboardClassName"] =
      keyboardClass ? NSStringFromClass(keyboardClass) ?: @"" : @"";
  details[@"keyboardClassSelectors"] =
      keyboardClass ? PBTextInsertMatchingSelectorsForClass(
                          object_getClass(keyboardClass), NO, 120)
                    : @[];
  details[@"keyboardClassSelectorSample"] =
      keyboardClass ? PBTextInsertSelectorNameSampleForClass(
                          object_getClass(keyboardClass), NO, 180)
                    : @[];

  [details addEntriesFromDictionary:PBTextInsertObjectProbeDetails(
                                        keyboard, @"keyboard", YES)];
  [details addEntriesFromDictionary:PBTextInsertObjectProbeDetails(
                                        responder, @"responder", NO)];

  NSString *delegateException = nil;
  id delegate = PBTextInsertObjectForNoArgSelector(
      keyboard, @selector(delegate), &delegateException);
  [details addEntriesFromDictionary:PBTextInsertObjectProbeDetails(
                                        delegate, @"delegate", NO)];
  details[@"delegateException"] = delegateException ?: @"";

  NSString *inputDelegateException = nil;
  id inputDelegate = PBTextInsertObjectForNoArgSelector(
      keyboard, @selector(inputDelegate), &inputDelegateException);
  [details addEntriesFromDictionary:PBTextInsertObjectProbeDetails(
                                        inputDelegate, @"inputDelegate", NO)];
  details[@"inputDelegateException"] = inputDelegateException ?: @"";

  return details;
}
#endif

static void PBScheduleTemporaryImagePasteboardCleanup(NSInteger temporaryChangeCount,
                                                      NSString *requestId) {
  if (temporaryChangeCount <= 0) {
    PB_RECORD_IMAGE_PASTE_DIAGNOSTIC(@"cleanup-not-scheduled"
                              requestId:requestId
                                details:@{
                                  @"temporaryChangeCount" : @(temporaryChangeCount)
                                });
    return;
  }

  __unused NSString *expectedRequestId = [requestId copy];
  PB_RECORD_IMAGE_PASTE_DIAGNOSTIC(@"cleanup-scheduled"
                            requestId:expectedRequestId
                              details:@{
                                @"temporaryChangeCount" : @(temporaryChangeCount),
                                @"delay" :
                                    @(kPBTemporaryPasteboardCleanupDelay)
                              });
  dispatch_after(
      dispatch_time(
          DISPATCH_TIME_NOW,
          (int64_t)(kPBTemporaryPasteboardCleanupDelay * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
        NSInteger currentChangeCount = -1;
        @try {
          currentChangeCount = pasteboard.changeCount;
        } @catch (__unused NSException *exception) {
          PB_RECORD_IMAGE_PASTE_DIAGNOSTIC(@"cleanup-change-count-failed"
                                    requestId:expectedRequestId
                                      details:@{
                                        @"temporaryChangeCount" :
                                            @(temporaryChangeCount)
                                      });
          return;
        }

        PB_RECORD_IMAGE_PASTE_DIAGNOSTIC(@"cleanup-check"
                                             requestId:expectedRequestId
                                               details:@{
                                                 @"temporaryChangeCount" :
                                                     @(temporaryChangeCount),
                                                 @"currentChangeCount" :
                                                     @(currentChangeCount)
                                               });

        if (currentChangeCount != temporaryChangeCount) {
          PBInputBridgeDebugLog(
              @"skip temporary image cleanup requestId=%@ expected=%ld current=%ld",
              expectedRequestId ?: @"", (long)temporaryChangeCount,
              (long)currentChangeCount);
          PB_RECORD_IMAGE_PASTE_DIAGNOSTIC(@"cleanup-skip-change-count"
                                    requestId:expectedRequestId
                                      details:@{
                                        @"temporaryChangeCount" :
                                            @(temporaryChangeCount),
                                        @"currentChangeCount" :
                                            @(currentChangeCount)
                                      });
          return;
        }

        BOOL previousInternalRead = PBInputBridgeAllowsInternalPasteboardRead;
        PBInputBridgeAllowsInternalPasteboardRead = YES;
        @try {
          pasteboard.items = @[];
          [PBInputBridge recordInternalPasteboardWriteWithPasteboard:pasteboard
                                                     imageDataLength:0];
          __unused NSInteger afterChangeCount = pasteboard.changeCount;
          PBInputBridgeDebugLog(
              @"cleared temporary image pasteboard requestId=%@ changeCount=%ld",
              expectedRequestId ?: @"", (long)temporaryChangeCount);
          PB_RECORD_IMAGE_PASTE_DIAGNOSTIC(@"cleanup-cleared"
                                               requestId:expectedRequestId
                                                 details:@{
                                                   @"temporaryChangeCount" :
                                                       @(temporaryChangeCount),
                                                   @"afterChangeCount" :
                                                       @(afterChangeCount)
                                                 });
        } @catch (NSException *exception) {
          PBInputBridgeDebugLog(
              @"temporary image cleanup failed requestId=%@ exception=%@",
              expectedRequestId ?: @"", exception);
          PB_RECORD_IMAGE_PASTE_DIAGNOSTIC(@"cleanup-failed"
                                                requestId:expectedRequestId
                                                  details:@{
                @"temporaryChangeCount": @(temporaryChangeCount),
                @"exception": exception.reason ?: [exception description] ?: @""
            });
        } @finally {
          PBInputBridgeAllowsInternalPasteboardRead = previousInternalRead;
        }
      });
}

static void
PBScheduleKeyboardTextPasteboardCleanup(NSInteger expectedChangeCount,
                                        NSString *requestId) {
  if (expectedChangeCount <= 0) {
    PBRecordTextInsertDiagnosticPhase(
        @"keyboard-pasteboard-cleanup-not-scheduled", requestId,
        @{@"expectedChangeCount" : @(expectedChangeCount)});
    return;
  }

  __unused NSString *expectedRequestId = [requestId copy];
  PBRecordTextInsertDiagnosticPhase(
      @"keyboard-pasteboard-cleanup-scheduled", expectedRequestId, @{
        @"expectedChangeCount" : @(expectedChangeCount),
        @"delay" : @(kPBKeyboardTextPasteboardCleanupDelay)
      });

  dispatch_after(
      dispatch_time(
          DISPATCH_TIME_NOW,
          (int64_t)(kPBKeyboardTextPasteboardCleanupDelay * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
        BOOL changeCountSuccess = NO;
        NSInteger currentChangeCount =
            PBGeneralPasteboardChangeCount(pasteboard, &changeCountSuccess);
        PBRecordTextInsertDiagnosticPhase(
            @"keyboard-pasteboard-cleanup-check", expectedRequestId, @{
              @"expectedChangeCount" : @(expectedChangeCount),
              @"currentChangeCount" : @(currentChangeCount),
              @"changeCountSuccess" : @(changeCountSuccess)
            });

        if (!changeCountSuccess || currentChangeCount != expectedChangeCount) {
          PBRecordTextInsertDiagnosticPhase(
              @"keyboard-pasteboard-cleanup-skip-change-count",
              expectedRequestId, @{
                @"expectedChangeCount" : @(expectedChangeCount),
                @"currentChangeCount" : @(currentChangeCount)
              });
          return;
        }

        @try {
          pasteboard.items = @[];
          [PBInputBridge recordInternalPasteboardWriteWithPasteboard:pasteboard
                                                     imageDataLength:0];
          __unused BOOL afterChangeCountSuccess = NO;
          __unused NSInteger afterChangeCount = PBGeneralPasteboardChangeCount(
              pasteboard, &afterChangeCountSuccess);
          PBRecordTextInsertDiagnosticPhase(
              @"keyboard-pasteboard-cleanup-cleared", expectedRequestId, @{
                @"expectedChangeCount" : @(expectedChangeCount),
                @"afterChangeCount" : @(afterChangeCount),
                @"afterChangeCountSuccess" : @(afterChangeCountSuccess)
              });
        } @catch (NSException *exception) {
          PBRecordTextInsertDiagnosticPhase(@"keyboard-pasteboard-cleanup-failed",
                                              expectedRequestId,
                                              @{
                @"expectedChangeCount": @(expectedChangeCount),
                @"exception": exception.reason ?: [exception description] ?: @""
            });
        }
      });
}

static void PBScheduleTemporaryTextPasteboardCleanup(NSInteger temporaryChangeCount,
                                                     NSString *requestId) {
  if (temporaryChangeCount <= 0) {
    return;
  }

  __unused NSString *expectedRequestId = [requestId copy];
  dispatch_after(
      dispatch_time(
          DISPATCH_TIME_NOW,
          (int64_t)(kPBTemporaryPasteboardCleanupDelay * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
        NSInteger currentChangeCount = -1;
        @try {
          currentChangeCount = pasteboard.changeCount;
        } @catch (__unused NSException *exception) {
          return;
        }

        if (currentChangeCount != temporaryChangeCount) {
          PBInputBridgeDebugLog(
              @"skip temporary text cleanup requestId=%@ expected=%ld current=%ld",
              expectedRequestId ?: @"", (long)temporaryChangeCount,
              (long)currentChangeCount);
          return;
        }

        BOOL previousInternalRead = PBInputBridgeAllowsInternalPasteboardRead;
        PBInputBridgeAllowsInternalPasteboardRead = YES;
        @try {
          pasteboard.items = @[];
          [PBInputBridge recordInternalPasteboardWriteWithPasteboard:pasteboard
                                                     imageDataLength:0];
          PBInputBridgeDebugLog(
              @"cleared temporary text pasteboard requestId=%@ changeCount=%ld",
              expectedRequestId ?: @"", (long)temporaryChangeCount);
        } @catch (NSException *exception) {
          PBInputBridgeDebugLog(
              @"temporary text cleanup failed requestId=%@ exception=%@",
              expectedRequestId ?: @"", exception);
        } @finally {
          PBInputBridgeAllowsInternalPasteboardRead = previousInternalRead;
        }
      });
}

static BOOL PBRequestTargetsCurrentProcess(NSDictionary *request) {
  NSString *targetBundleId = request[@"targetBundleId"];
  if (![targetBundleId isKindOfClass:[NSString class]] ||
      targetBundleId.length == 0) {
    return NO;
  }

  NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
  return [bundleId isEqualToString:targetBundleId];
}

static BOOL PBiOSCopyAccessibilityIdentifierMarksSearchUI(NSString *identifier) {
  return [identifier isEqualToString:@"com.ssdsl.ioscopy.searchBar"];
}

static BOOL PBViewBelongsToiOSCopySearchUI(UIView *view) {
  UIView *currentView = view;
  while (currentView) {
    if (PBiOSCopyAccessibilityIdentifierMarksSearchUI(
            currentView.accessibilityIdentifier)) {
      return YES;
    }
    currentView = currentView.superview;
  }

  return NO;
}

static BOOL PBResponderIsVisibleView(UIResponder *responder) {
  if (![responder isKindOfClass:[UIView class]]) {
    return YES;
  }

  UIView *view = (UIView *)responder;
  if (view.hidden || view.alpha < 0.01 || !view.userInteractionEnabled ||
      !view.window) {
    return NO;
  }

  UIView *ancestor = view.superview;
  while (ancestor) {
    if (ancestor.hidden || ancestor.alpha < 0.01 ||
        !ancestor.userInteractionEnabled) {
      return NO;
    }
    ancestor = ancestor.superview;
  }

  return YES;
}

static BOOL PBResponderLooksEditable(UIResponder *responder) {
  if (!responder || !PBResponderIsVisibleView(responder)) {
    return NO;
  }

  if ([responder isKindOfClass:[UIView class]] &&
      PBViewBelongsToiOSCopySearchUI((UIView *)responder)) {
    return NO;
  }

  if ([responder isKindOfClass:[UITextField class]]) {
    UITextField *textField = (UITextField *)responder;
    return textField.enabled;
  }

  if ([responder isKindOfClass:[UITextView class]]) {
    UITextView *textView = (UITextView *)responder;
    return textView.editable;
  }

  if ([responder isKindOfClass:[UISearchBar class]]) {
    UISearchBar *searchBar = (UISearchBar *)responder;
    if (@available(iOS 13.0, *)) {
      return searchBar.searchTextField.enabled;
    }
  }

  if (![responder canBecomeFirstResponder]) {
    return NO;
  }

  if ([responder conformsToProtocol:@protocol(UITextInput)] ||
      [responder conformsToProtocol:@protocol(UIKeyInput)]) {
    return YES;
  }

  return [responder respondsToSelector:@selector(insertText:)];
}

static void PBRecordRecentEditableResponder(UIResponder *responder) {
  if (!PBResponderLooksEditable(responder)) {
    return;
  }

  kPBRecentEditableResponder = responder;
  kPBRecentEditableResponderRecordedAt = [[NSDate date] timeIntervalSince1970];
  [PBInputBridge recordCurrentProcessAsRecentInputTarget];
  PBInputBridgeDebugLog(@"record editable responder class=%@",
                        NSStringFromClass([responder class]) ?: @"");
}

static UIResponder *PBFindFirstResponderInView(UIView *view) {
  if (view.isFirstResponder) {
    return view;
  }

  for (UIView *subview in view.subviews) {
    UIResponder *responder = PBFindFirstResponderInView(subview);
    if (responder) {
      return responder;
    }
  }

  return nil;
}

static UIResponder *PBRestoreRecentEditableResponderIfNeeded(UIResponder *current,
                                                             BOOL *didRestore) {
  if (didRestore) {
    *didRestore = NO;
  }

  if (PBResponderLooksEditable(current) && current.isFirstResponder) {
    PBRecordRecentEditableResponder(current);
    return current;
  }

  UIResponder *recentResponder = kPBRecentEditableResponder;
  if (!PBResponderLooksEditable(recentResponder)) {
    return current;
  }

  NSTimeInterval age =
      [[NSDate date] timeIntervalSince1970] - kPBRecentEditableResponderRecordedAt;
  if (age < 0 || age > 30.0) {
    return current;
  }

  if (![recentResponder canBecomeFirstResponder]) {
    return current;
  }

  BOOL becameFirstResponder = NO;
  @try {
    becameFirstResponder = [recentResponder becomeFirstResponder];
  } @catch (__unused NSException *exception) {
    becameFirstResponder = NO;
  }

  if (becameFirstResponder || recentResponder.isFirstResponder) {
    if (didRestore) {
      *didRestore = YES;
    }
    PBInputBridgeDebugLog(@"restored editable responder class=%@",
                          NSStringFromClass([recentResponder class]) ?: @"");
    return recentResponder;
  }

  return current;
}

static UIResponder *PBFindEditableTextResponderInView(UIView *view) {
  if (view.hidden || view.alpha < 0.01 || !view.userInteractionEnabled) {
    return nil;
  }

  if ([view isKindOfClass:[UISearchBar class]]) {
    UISearchBar *searchBar = (UISearchBar *)view;
    if (@available(iOS 13.0, *)) {
      UITextField *searchField = searchBar.searchTextField;
      if (searchField.enabled) {
        return searchField;
      }
    }
  }

  if ([view isKindOfClass:[UITextField class]]) {
    UITextField *textField = (UITextField *)view;
    if (textField.enabled) {
      return textField;
    }
  }

  if ([view isKindOfClass:[UITextView class]]) {
    UITextView *textView = (UITextView *)view;
    if (textView.editable) {
      return textView;
    }
  }

  if (PBResponderLooksEditable(view)) {
    return view;
  }

  for (UIView *subview in view.subviews) {
    UIResponder *responder = PBFindEditableTextResponderInView(subview);
    if (responder) {
      return responder;
    }
  }

  return nil;
}

static UIResponder *PBFindFirstResponder(void) {
  Class applicationClass = NSClassFromString(@"UIApplication");
  if (!applicationClass ||
      ![applicationClass respondsToSelector:@selector(sharedApplication)]) {
    return nil;
  }

  UIApplication *application = [applicationClass sharedApplication];
  NSMutableArray<UIWindow *> *windows = [NSMutableArray array];

  if (@available(iOS 13.0, *)) {
    for (UIScene *scene in application.connectedScenes) {
      if (![scene isKindOfClass:[UIWindowScene class]]) {
        continue;
      }

      UIWindowScene *windowScene = (UIWindowScene *)scene;
      if (windowScene.activationState !=
          UISceneActivationStateForegroundActive) {
        continue;
      }

      [windows addObjectsFromArray:windowScene.windows];
    }
  }

  if (application.keyWindow) {
    [windows addObject:application.keyWindow];
  }

  for (UIWindow *window in windows) {
    UIResponder *responder = PBFindFirstResponderInView(window);
    if (responder) {
      return responder;
    }
  }

  for (UIWindow *window in windows) {
    UIResponder *responder = PBFindEditableTextResponderInView(window);
    if (responder) {
      return responder;
    }
  }

  return nil;
}

#if DEBUG_LOG
static NSDictionary *
PBTextInsertResponderDiagnosticDetails(UIResponder *responder) {
  NSMutableDictionary *details = [NSMutableDictionary dictionary];
  details[@"hasResponder"] = @(responder != nil);
  details[@"responderClass"] =
      responder ? NSStringFromClass([responder class]) ?: @"" : @"";
  details[@"responderIsFirstResponder"] = @([responder isFirstResponder]);
  details[@"responderRespondsInsertText"] =
      @([responder respondsToSelector:@selector(insertText:)]);
  details[@"responderRespondsPaste"] =
      @([responder respondsToSelector:@selector(paste:)]);
  details[@"responderConformsUIKeyInput"] =
      @([responder conformsToProtocol:@protocol(UIKeyInput)]);
  details[@"responderCanBecomeFirstResponder"] =
      @([responder canBecomeFirstResponder]);

  if ([responder isKindOfClass:[UITextField class]]) {
    UITextField *textField = (UITextField *)responder;
    details[@"responderKind"] = @"UITextField";
    details[@"enabled"] = @(textField.enabled);
    details[@"editing"] = @(textField.editing);
    details[@"secureTextEntry"] = @(textField.secureTextEntry);
  } else if ([responder isKindOfClass:[UITextView class]]) {
    UITextView *textView = (UITextView *)responder;
    details[@"responderKind"] = @"UITextView";
    details[@"editable"] = @(textView.editable);
    details[@"selectable"] = @(textView.selectable);
  } else if ([responder isKindOfClass:[UISearchBar class]]) {
    details[@"responderKind"] = @"UISearchBar";
  }

  return details;
}

static NSString *PBTextInsertStringFromValue(id value) {
  if ([value isKindOfClass:[NSString class]]) {
    return value;
  }
  if ([value isKindOfClass:[NSAttributedString class]]) {
    return [(NSAttributedString *)value string];
  }
  return nil;
}

static NSString *PBTextInsertCurrentResponderText(UIResponder *responder) {
  if (!responder) {
    return nil;
  }

  SEL textSelector = @selector(text);
  if (![responder respondsToSelector:textSelector]) {
    return nil;
  }

  id (*sendObject)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
  @try {
    return PBTextInsertStringFromValue(sendObject(responder, textSelector));
  } @catch (__unused NSException *exception) {
    return nil;
  }
}

static NSDictionary *PBTextInsertResponderTextCompareDetails(
    UIResponder *responder, NSString *beforeText, NSString *insertedText) {
  NSString *afterText = PBTextInsertCurrentResponderText(responder);
  BOOL hasBeforeText = [beforeText isKindOfClass:[NSString class]];
  BOOL hasAfterText = [afterText isKindOfClass:[NSString class]];
  BOOL changed =
      hasBeforeText && hasAfterText && ![afterText isEqualToString:beforeText];
  BOOL containsInsertedText = hasAfterText && insertedText.length > 0 &&
                              [afterText containsString:insertedText];
  return @{
    @"hasBeforeText" : @(hasBeforeText),
    @"hasAfterText" : @(hasAfterText),
    @"beforeTextLength" : @(beforeText.length),
    @"afterTextLength" : @(afterText.length),
    @"textChanged" : @(changed),
    @"afterContainsInsertedText" : @(containsInsertedText)
  };
}
#else
static id PBTextInsertObjectForNoArgSelector(id object, SEL selector,
                                             NSString **exceptionReason) {
  if (exceptionReason) {
    *exceptionReason = nil;
  }
  if (!object || ![object respondsToSelector:selector]) {
    return nil;
  }

  id (*sendObject)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
  @try {
    return sendObject(object, selector);
  } @catch (NSException *exception) {
    if (exceptionReason) {
      *exceptionReason = exception.reason ?: [exception description] ?: @"";
    }
    return nil;
  }
}
#define PBTextInsertResponderDiagnosticDetails(...) ((NSDictionary *)nil)
#define PBTextInsertCurrentResponderText(...) ((NSString *)nil)
#define PBTextInsertResponderTextCompareDetails(...) ((NSDictionary *)nil)
#define PBTextInsertKeyboardSelectorProbeDetails(...) ((NSDictionary *)nil)
#endif

static BOOL PBKeyboardBoolForSelector(id object, SEL selector,
                                      BOOL defaultValue,
                                      NSString **exceptionReason) {
  if (exceptionReason) {
    *exceptionReason = nil;
  }
  if (!object || ![object respondsToSelector:selector]) {
    return defaultValue;
  }

  BOOL (*sendBool)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
  @try {
    return sendBool(object, selector);
  } @catch (NSException *exception) {
    if (exceptionReason) {
      *exceptionReason = exception.reason ?: [exception description] ?: @"";
    }
    return defaultValue;
  }
}

static BOOL PBKeyboardSendNoArgumentSelector(id object, SEL selector,
                                             NSString **exceptionReason) {
  if (exceptionReason) {
    *exceptionReason = nil;
  }
  if (!object || ![object respondsToSelector:selector]) {
    return NO;
  }

  void (*sendVoid)(id, SEL) = (void (*)(id, SEL))objc_msgSend;
  @try {
    sendVoid(object, selector);
    return YES;
  } @catch (NSException *exception) {
    if (exceptionReason) {
      *exceptionReason = exception.reason ?: [exception description] ?: @"";
    }
    return NO;
  }
}

static id PBResolvedPasteActionTarget(UIResponder *responder) {
  if (!responder) {
    return nil;
  }

  @try {
    id target = [responder targetForAction:@selector(paste:) withSender:nil];
    if (target && [target respondsToSelector:@selector(paste:)]) {
      return target;
    }
  } @catch (__unused NSException *exception) {
  }

  return nil;
}

static BOOL PBPerformApplicationPasteAction(UIResponder *responder,
                                            NSString *requestId) {
  BOOL handled = NO;
  id pasteTarget = PBResolvedPasteActionTarget(responder);
  Class applicationClass = NSClassFromString(@"UIApplication");
  if (pasteTarget && applicationClass &&
      [applicationClass respondsToSelector:@selector(sharedApplication)]) {
    UIApplication *application = [applicationClass sharedApplication];
    handled = [application sendAction:@selector(paste:)
                                   to:pasteTarget
                                 from:nil
                             forEvent:nil];
  }

  PB_RECORD_IMAGE_PASTE_DIAGNOSTIC(@"paste-action"
                            requestId:requestId
                              details:@{
                                @"method" : @"UIApplication.sendAction.explicitTarget",
                                @"responderClass" :
                                    NSStringFromClass([responder class]) ?: @"",
                                @"targetClass" :
                                    NSStringFromClass([pasteTarget class]) ?: @"",
                                @"handled" : @(handled)
                              });
  return handled;
}

static BOOL PBPerformPaste(UIResponder *responder, NSString *requestId) {
  return PBPerformApplicationPasteAction(responder, requestId);
}

static void PBKeyboardAddUniqueCommitTarget(NSMutableArray *targets,
                                            id object) {
  if (!object) {
    return;
  }
  for (id target in targets) {
    if (target == object) {
      return;
    }
  }
  [targets addObject:object];
}

static NSArray *
PBKeyboardMarkedTextCommitTargets(id keyboard, UIResponder *responder,
                                  NSMutableDictionary *details) {
  NSMutableArray *targets = [NSMutableArray array];
  PBKeyboardAddUniqueCommitTarget(targets, responder);

  SEL delegateSelector = @selector(delegate);
  SEL inputDelegateSelector = @selector(inputDelegate);
  SEL responderForKeyboardInputSelector =
      NSSelectorFromString(@"responderForKeyboardInput");

  NSString *delegateException = nil;
  id delegate = PBTextInsertObjectForNoArgSelector(keyboard, delegateSelector,
                                                   &delegateException);
  NSString *inputDelegateException = nil;
  id inputDelegate = PBTextInsertObjectForNoArgSelector(
      keyboard, inputDelegateSelector, &inputDelegateException);
  if (details) {
    details[@"delegateClass"] =
        delegate ? NSStringFromClass([delegate class]) ?: @"" : @"";
    details[@"inputDelegateClass"] =
        inputDelegate ? NSStringFromClass([inputDelegate class]) ?: @"" : @"";
    details[@"delegateException"] = delegateException ?: @"";
    details[@"inputDelegateException"] = inputDelegateException ?: @"";
  }

  NSArray *baseTargets =
      @[ delegate ?: [NSNull null], inputDelegate ?: [NSNull null] ];
  for (id object in baseTargets) {
    if (object == [NSNull null]) {
      continue;
    }
    PBKeyboardAddUniqueCommitTarget(targets, object);

    NSString *responderException = nil;
    id keyboardResponder = PBTextInsertObjectForNoArgSelector(
        object, responderForKeyboardInputSelector, &responderException);
    PBKeyboardAddUniqueCommitTarget(targets, keyboardResponder);
  }

  if (details) {
    NSMutableArray *targetDetails = [NSMutableArray array];
    SEL unmarkTextSelector = NSSelectorFromString(@"unmarkText");
    for (id target in targets) {
      [targetDetails addObject:@{
        @"class" : NSStringFromClass([target class]) ?: @"",
        @"respondsUnmarkText" :
            @([target respondsToSelector:unmarkTextSelector]),
        @"respondsResponderForKeyboardInput" :
            @([target respondsToSelector:responderForKeyboardInputSelector])
      }];
    }
    details[@"commitTargets"] = targetDetails;
  }
  return targets;
}

static BOOL PBKeyboardTryUnmarkTextTargets(NSArray *targets,
                                           NSMutableDictionary *details) {
  SEL unmarkTextSelector = NSSelectorFromString(@"unmarkText");
  NSMutableArray *attempts = details ? [NSMutableArray array] : nil;
  for (id target in targets) {
    BOOL responds = [target respondsToSelector:unmarkTextSelector];
    NSMutableDictionary *attempt = details ? [@{
      @"class" : NSStringFromClass([target class]) ?: @"",
      @"respondsUnmarkText" : @(responds),
      @"called" : @NO
    } mutableCopy] : nil;
    if (responds) {
      NSString *exceptionReason = nil;
      BOOL called = PBKeyboardSendNoArgumentSelector(target, unmarkTextSelector,
                                                     &exceptionReason);
      if (details) {
        attempt[@"called"] = @(called);
        attempt[@"exception"] = exceptionReason ?: @"";
      }
      if (called) {
        if (details) {
          [attempts addObject:attempt];
          details[@"unmarkAttempts"] = attempts;
        }
        return YES;
      }
    }
    if (details) {
      [attempts addObject:attempt];
    }
  }
  if (details) {
    details[@"unmarkAttempts"] = attempts;
  }
  return NO;
}

static void PBKeyboardPerformMarkedTextCommit(NSString *requestId, id keyboard,
                                              UIResponder *responder) {
  SEL hasMarkedSelector = NSSelectorFromString(@"hasEditableMarkedText");
  SEL commitSelector = NSSelectorFromString(@"commitCurrentText");
  NSString *hasMarkedException = nil;
  BOOL hasEditableMarkedTextBefore = PBKeyboardBoolForSelector(
      keyboard, hasMarkedSelector, NO, &hasMarkedException);
  BOOL keyboardRespondsCommitCurrentText =
      [keyboard respondsToSelector:commitSelector];
  NSMutableDictionary *details =
      kPBTextInsertDiagnosticsEnabled ? [NSMutableDictionary dictionary] : nil;
  if (details) {
    details[@"keyboardRespondsHasEditableMarkedText"] =
        @([keyboard respondsToSelector:hasMarkedSelector]);
    details[@"hasEditableMarkedTextBefore"] = @(hasEditableMarkedTextBefore);
    details[@"hasEditableMarkedTextException"] = hasMarkedException ?: @"";
    details[@"keyboardRespondsCommitCurrentText"] =
        @(keyboardRespondsCommitCurrentText);
    details[@"commitCalled"] = @NO;
    details[@"commitMethod"] = @"";
  }

  if (hasEditableMarkedTextBefore && keyboardRespondsCommitCurrentText) {
    NSString *commitException = nil;
    BOOL commitCalled = PBKeyboardSendNoArgumentSelector(
        keyboard, commitSelector, &commitException);
    if (details) {
      details[@"commitCalled"] = @(commitCalled);
      details[@"commitMethod"] = @"keyboard.commitCurrentText";
      details[@"commitException"] = commitException ?: @"";
    }
  }

  NSString *hasMarkedAfterCommitException = nil;
  BOOL hasEditableMarkedTextAfterCommit = PBKeyboardBoolForSelector(
      keyboard, hasMarkedSelector, NO, &hasMarkedAfterCommitException);
  if (details) {
    details[@"hasEditableMarkedTextAfterCommitCurrentText"] =
        @(hasEditableMarkedTextAfterCommit);
    details[@"hasEditableMarkedTextAfterCommitException"] =
        hasMarkedAfterCommitException ?: @"";
  }

  if (hasEditableMarkedTextAfterCommit) {
    NSArray *targets =
        PBKeyboardMarkedTextCommitTargets(keyboard, responder, details);
    BOOL unmarkCalled = PBKeyboardTryUnmarkTextTargets(targets, details);
    if (details && unmarkCalled) {
      details[@"commitCalled"] = @YES;
      details[@"commitMethod"] =
          [details[@"commitMethod"] length] > 0
              ? [NSString
                    stringWithFormat:@"%@+unmarkText", details[@"commitMethod"]]
              : @"unmarkText";
    }
  }

  if (details) {
    NSString *hasMarkedAfterException = nil;
    BOOL hasEditableMarkedTextAfter = PBKeyboardBoolForSelector(
        keyboard, hasMarkedSelector, NO, &hasMarkedAfterException);
    details[@"hasEditableMarkedTextAfter"] = @(hasEditableMarkedTextAfter);
    details[@"hasEditableMarkedTextAfterException"] =
        hasMarkedAfterException ?: @"";
    PBRecordTextInsertDiagnosticPhase(@"keyboard-commit-marked-text", requestId,
                                      details);
  }
}

static void PBKeyboardScheduleMarkedTextCommit(NSString *requestId, id keyboard,
                                               UIResponder *responder) {
  NSString *expectedRequestId = [requestId copy];
  id expectedKeyboard = keyboard;
  __weak UIResponder *weakResponder = responder;
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.04 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        UIResponder *strongResponder = weakResponder;
        PBKeyboardPerformMarkedTextCommit(expectedRequestId, expectedKeyboard,
                                          strongResponder);
      });
}

static BOOL PBKeyboardTryAddInputString(NSString *text, NSString *requestId,
                                        id keyboard,
                                        UIResponder *responder) {
  SEL addInputStringSelector = NSSelectorFromString(@"addInputString:");
  if (text.length == 0 ||
      ![keyboard respondsToSelector:addInputStringSelector]) {
    return NO;
  }

  __unused NSString *beforeText = kPBTextInsertDiagnosticsEnabled
                                      ? PBTextInsertCurrentResponderText(responder)
                                      : nil;
  void (*addInputString)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
  @try {
    addInputString(keyboard, addInputStringSelector, text);
  } @catch (NSException *exception) {
    PBRecordTextInsertDiagnosticPhase(@"keyboard-add-input-string-exception",
                                      requestId, @{
                                        @"exception" :
                                            exception.reason
                                                ?: [exception description] ?: @"",
                                        @"textLength" : @(text.length)
                                      });
    return NO;
  }

  if (kPBTextInsertDiagnosticsEnabled) {
    NSMutableDictionary *details =
        [PBTextInsertResponderTextCompareDetails(responder, beforeText, text)
            mutableCopy];
    details[@"textLength"] = @(text.length);
    details[@"keyboardInstanceClass"] =
        NSStringFromClass([keyboard class]) ?: @"";
    PBRecordTextInsertDiagnosticPhase(@"keyboard-add-input-string-called",
                                      requestId, details);
  }
  PBKeyboardScheduleMarkedTextCommit(requestId, keyboard, responder);
  return YES;
}

static BOOL PBKeyboardInsertText(NSString *text, NSString *requestId,
                                 UIResponder *responder) {
  Class keyboardClass = NSClassFromString(@"UIKeyboardImpl");
  if (kPBTextInsertDiagnosticsEnabled) {
    NSMutableDictionary *checkDetails =
        [PBTextInsertResponderDiagnosticDetails(responder) mutableCopy];
    if (!checkDetails) {
      checkDetails = [NSMutableDictionary dictionary];
    }
    checkDetails[@"textLength"] = @(text.length);
    checkDetails[@"hasKeyboardClass"] = @(keyboardClass != Nil);
    checkDetails[@"keyboardClassRespondsActiveInstance"] =
        @(keyboardClass &&
          [keyboardClass respondsToSelector:@selector(activeInstance)]);
    PBRecordTextInsertDiagnosticPhase(@"keyboard-check", requestId,
                                      checkDetails);
  }

  if (!keyboardClass ||
      ![keyboardClass respondsToSelector:@selector(activeInstance)]) {
    return NO;
  }

  id (*activeInstance)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
  id keyboard = nil;
  @try {
    keyboard = activeInstance(keyboardClass, @selector(activeInstance));
  } @catch (NSException *exception) {
    PBRecordTextInsertDiagnosticPhase(@"keyboard-active-exception",
                                          requestId,
                                          @{
            @"exception": exception.reason ?: [exception description] ?: @""
        });
    return NO;
  }

  if (!keyboard) {
    return NO;
  }

  if (kPBTextInsertDiagnosticsEnabled) {
    NSMutableDictionary *instanceDetails = [NSMutableDictionary dictionary];
    instanceDetails[@"hasKeyboardInstance"] = @YES;
    instanceDetails[@"keyboardInstanceClass"] =
        NSStringFromClass([keyboard class]) ?: @"";
    instanceDetails[@"keyboardRespondsAddInputString"] =
        @([keyboard respondsToSelector:NSSelectorFromString(@"addInputString:")]);
    instanceDetails[@"keyboardRespondsDelegate"] =
        @([keyboard respondsToSelector:@selector(delegate)]);
    instanceDetails[@"keyboardRespondsInputDelegate"] =
        @([keyboard respondsToSelector:@selector(inputDelegate)]);
    instanceDetails[@"keyboardRespondsCommitCurrentText"] = @(
        [keyboard respondsToSelector:NSSelectorFromString(@"commitCurrentText")]);
    instanceDetails[@"keyboardRespondsHasEditableMarkedText"] = @([keyboard
        respondsToSelector:NSSelectorFromString(@"hasEditableMarkedText")]);
    PBRecordTextInsertDiagnosticPhase(@"keyboard-instance", requestId,
                                      instanceDetails);
  }

#if DEBUG_LOG
  if (requestId.length == 0 ||
      ![kPBLastTextInsertSelectorProbeRequestId isEqualToString:requestId]) {
    kPBLastTextInsertSelectorProbeRequestId = [requestId copy];
    PBRecordTextInsertDiagnosticPhase(@"keyboard-selector-probe", requestId,
                                      PBTextInsertKeyboardSelectorProbeDetails(
                                          keyboardClass, keyboard, responder));
  }
#endif

  return PBKeyboardTryAddInputString(text, requestId, keyboard, responder);
}

static void PBEndInternalPasteboardReadWindow(void);
static void PBScheduleInternalPasteboardReadWindowClose(NSString *requestId,
                                                        NSTimeInterval delay);

#if DEBUG_LOG
static BOOL
PBShouldRecordImagePasteDiagnosticForRequest(NSDictionary *request) {
  NSData *imageData = request[@"imageData"];
  if (![imageData isKindOfClass:[NSData class]] || imageData.length == 0) {
    return NO;
  }

  NSString *targetBundleId = request[@"targetBundleId"];
  NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
  NSString *processName = [[NSProcessInfo processInfo] processName] ?: @"";
  NSString *lowerBundleId = [bundleId lowercaseString];
  NSString *lowerProcessName = [processName lowercaseString];
  BOOL looksLikeQQ = [lowerBundleId containsString:@"tencent"] ||
                     [lowerBundleId containsString:@"mqq"] ||
                     [lowerProcessName containsString:@"qq"] ||
                     [lowerProcessName containsString:@"mqq"];
  if ([targetBundleId isKindOfClass:[NSString class]] &&
      targetBundleId.length > 0) {
    return [bundleId isEqualToString:targetBundleId] ||
           [processName isEqualToString:@"SpringBoard"] || looksLikeQQ;
  }

  return looksLikeQQ;
}
#else
#define PBShouldRecordImagePasteDiagnosticForRequest(...) NO
#endif

static NSString *PBCurrentBundleId(void) {
  return [[NSBundle mainBundle] bundleIdentifier] ?: @"";
}

static NSString *PBThreadLocalPasteRequestId(void) {
  id value = [[NSThread currentThread].threadDictionary
      objectForKey:kPBPluginPasteThreadRequestIdKey];
  return [value isKindOfClass:[NSString class]] ? value : nil;
}

static void PBBeginThreadLocalPaste(NSString *requestId) {
  if (requestId.length == 0) {
    return;
  }

  [[NSThread currentThread].threadDictionary
      setObject:requestId
         forKey:kPBPluginPasteThreadRequestIdKey];
}

static void PBEndThreadLocalPaste(NSString *requestId) {
  NSMutableDictionary *threadDictionary =
      [NSThread currentThread].threadDictionary;
  NSString *currentRequestId =
      [threadDictionary objectForKey:kPBPluginPasteThreadRequestIdKey];
  if (requestId.length == 0 || [currentRequestId isEqualToString:requestId]) {
    [threadDictionary removeObjectForKey:kPBPluginPasteThreadRequestIdKey];
  }
}

static BOOL PBPasteboardNameLooksGeneral(id pasteboardName) {
  if (!pasteboardName) {
    return YES;
  }

  NSString *name = [pasteboardName isKindOfClass:[NSString class]]
                       ? pasteboardName
                       : [pasteboardName description];
  if (name.length == 0) {
    return YES;
  }

  NSString *generalName = UIPasteboardNameGeneral;
  return [name isEqualToString:generalName] ||
         [name isEqualToString:@"com.apple.UIKit.pboard.general"] ||
         [name isEqualToString:@"general"];
}

static BOOL PBActivePasteTargetsCurrentProcess(void) {
  if (kPBActivePasteTargetBundleId.length == 0) {
    return YES;
  }

  return [PBCurrentBundleId() isEqualToString:kPBActivePasteTargetBundleId];
}

static void PBBeginInternalPasteboardReadWindow(NSString *requestId,
                                                NSString *targetBundleId) {
  @synchronized([PBInputBridge class]) {
    PBInputBridgeAllowsInternalPasteboardRead = YES;
    kPBActivePasteRequestId = [requestId copy];
    kPBActivePasteTargetBundleId = [targetBundleId copy];
    kPBActivePasteWindowStartedAt = [[NSDate date] timeIntervalSince1970];
    kPBActivePastePolicyAllowCount = 0;
    kPBInternalPasteboardReadWindowGeneration++;
  }

  __unused NSUInteger generation = kPBInternalPasteboardReadWindowGeneration;
  PBInputBridgeDebugLog(@"internal pasteboard read window opened "
                        @"generation=%lu requestId=%@ target=%@",
                        (unsigned long)generation,
                        kPBActivePasteRequestId ?: @"",
                        kPBActivePasteTargetBundleId ?: @"");
  PBScheduleInternalPasteboardReadWindowClose(
      requestId, kPBOneShotPasteboardReadAuthorizationTimeout);
}

static void PBEndInternalPasteboardReadWindow(void) {
  __unused NSString *requestId = nil;
  __unused NSString *targetBundleId = nil;
  @synchronized([PBInputBridge class]) {
    if (!PBInputBridgeAllowsInternalPasteboardRead &&
        kPBActivePasteRequestId.length == 0) {
      return;
    }

    kPBInternalPasteboardReadWindowGeneration++;
    PBInputBridgeAllowsInternalPasteboardRead = NO;
    requestId = kPBActivePasteRequestId;
    targetBundleId = kPBActivePasteTargetBundleId;
    kPBActivePasteRequestId = nil;
    kPBActivePasteTargetBundleId = nil;
    kPBActivePasteWindowStartedAt = 0;
    kPBActivePastePolicyAllowCount = 0;
  }

  PBInputBridgeDebugLog(
      @"internal pasteboard read window closed generation=%lu requestId=%@ "
      @"target=%@",
      (unsigned long)kPBInternalPasteboardReadWindowGeneration,
      requestId ?: @"", targetBundleId ?: @"");
}

static void PBScheduleInternalPasteboardReadWindowClose(NSString *requestId,
                                                        NSTimeInterval delay) {
  NSUInteger generation = kPBInternalPasteboardReadWindowGeneration;
  NSString *expectedRequestId = [requestId copy];
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        BOOL shouldClose = NO;
        @synchronized([PBInputBridge class]) {
          BOOL sameGeneration =
              generation == kPBInternalPasteboardReadWindowGeneration;
          BOOL sameRequest =
              expectedRequestId.length == 0 ||
              [kPBActivePasteRequestId isEqualToString:expectedRequestId];
          shouldClose = sameGeneration && sameRequest &&
                        PBInputBridgeAllowsInternalPasteboardRead;
        }

        if (shouldClose) {
          PBInputBridgeDebugLog(@"internal pasteboard read window scheduled "
                                @"close generation=%lu requestId=%@ delay=%.2f",
                                (unsigned long)generation,
                                expectedRequestId ?: @"", delay);
          PBEndThreadLocalPaste(expectedRequestId);
          PBEndInternalPasteboardReadWindow();
        }
      });
}

static void PBHandleInsertRequest(void) {
  if (!PBInputBridgeMainFeatureEnabled()) {
    return;
  }

  Class applicationClass = NSClassFromString(@"UIApplication");
  if (!applicationClass ||
      ![applicationClass respondsToSelector:@selector(sharedApplication)]) {
    return;
  }

  UIApplication *application = [applicationClass sharedApplication];
  if (application.applicationState == UIApplicationStateBackground) {
    return;
  }

  NSString *requestPath = PBInputBridgeRequestPath();
  NSDictionary *request =
      [NSDictionary dictionaryWithContentsOfFile:requestPath];
  if (![request isKindOfClass:[NSDictionary class]]) {
    return;
  }

  NSString *requestId = request[@"id"];
  NSString *requestType = request[@"type"];
  NSString *text = request[@"text"];
  NSData *imageData = request[@"imageData"];
  NSNumber *timestamp = request[@"timestamp"];
  NSString *targetBundleId = request[@"targetBundleId"];
  BOOL shouldRecordImageDiagnostic =
      kPBImagePasteDiagnosticsEnabled &&
      PBShouldRecordImagePasteDiagnosticForRequest(request);
  PBInputBridgeDebugLog(
      @"received request id=%@ type=%@ textLength=%lu imageBytes=%lu "
      @"appState=%ld bundle=%@ target=%@",
      requestId ?: @"", requestType ?: @"", (unsigned long)text.length,
      (unsigned long)imageData.length, (long)application.applicationState,
      [[NSBundle mainBundle] bundleIdentifier] ?: @"", targetBundleId ?: @"");
  if (shouldRecordImageDiagnostic) {
    PB_RECORD_IMAGE_PASTE_DIAGNOSTIC(@"received"
                              requestId:requestId
                                details:@{
                                  @"requestType" : requestType ?: @"",
                                  @"imageBytes" : @(imageData.length),
                                  @"imageType" :
                                      PBImagePasteboardTypeForData(imageData),
                                  @"targetBundleId" : targetBundleId ?: @"",
                                  @"currentBundleId" : [[NSBundle mainBundle]
                                      bundleIdentifier]
                                      ?: @"",
                                  @"currentProcess" :
                                          [[NSProcessInfo processInfo]
                                              processName]
                                      ?: @""
                                });
  }

  if (requestId.length == 0 || ![timestamp isKindOfClass:[NSNumber class]]) {
    if (shouldRecordImageDiagnostic) {
      PB_RECORD_IMAGE_PASTE_DIAGNOSTIC(@"invalid-request"
                                           requestId:requestId
                                             details:@{});
    }
    return;
  }

  if (requestType.length == 0) {
    requestType = text.length > 0 ? @"insertText" : @"paste";
  }
  BOOL shouldRecordTextInsertDiagnostic =
      kPBTextInsertDiagnosticsEnabled &&
      ![requestType isEqualToString:@"paste"] &&
      [text isKindOfClass:[NSString class]] && text.length > 0;
  if (shouldRecordTextInsertDiagnostic) {
    PBRecordTextInsertDiagnosticPhase(
        @"received", requestId, @{
          @"requestType" : requestType ?: @"",
          @"textLength" : @(text.length),
          @"targetBundleId" : targetBundleId ?: @"",
          @"currentBundleId" : [[NSBundle mainBundle] bundleIdentifier] ?: @"",
          @"currentProcess" : [[NSProcessInfo processInfo] processName] ?: @"",
          @"requestPath" : requestPath ?: @""
        });
  }

  if ([requestId isEqualToString:kPBLastHandledRequestId]) {
    if (shouldRecordImageDiagnostic) {
      PB_RECORD_IMAGE_PASTE_DIAGNOSTIC(@"duplicate-request"
                                           requestId:requestId
                                             details:@{});
    }
    if (shouldRecordTextInsertDiagnostic) {
      PBRecordTextInsertDiagnosticPhase(@"duplicate-request", requestId, @{});
    }
    return;
  }

  if (!PBRequestTargetsCurrentProcess(request)) {
    PBInputBridgeDebugLog(@"ignore request id=%@ target=%@ current=%@",
                          requestId, targetBundleId ?: @"",
                          [[NSBundle mainBundle] bundleIdentifier] ?: @"");
    if (shouldRecordImageDiagnostic) {
      PB_RECORD_IMAGE_PASTE_DIAGNOSTIC(@"ignore-target"
                                requestId:requestId
                                  details:@{
                                    @"targetBundleId" : targetBundleId ?: @"",
                                    @"currentBundleId" : [[NSBundle mainBundle]
                                        bundleIdentifier]
                                        ?: @"",
                                    @"currentProcess" :
                                            [[NSProcessInfo processInfo]
                                                processName]
                                        ?: @""
                                  });
    }
    if (shouldRecordTextInsertDiagnostic) {
      PBRecordTextInsertDiagnosticPhase(@"ignore-target", requestId, @{
        @"targetBundleId" : targetBundleId ?: @"",
        @"currentBundleId" : [[NSBundle mainBundle] bundleIdentifier] ?: @"",
        @"currentProcess" : [[NSProcessInfo processInfo] processName] ?: @""
      });
    }
    return;
  }

  NSTimeInterval age =
      [[NSDate date] timeIntervalSince1970] - timestamp.doubleValue;
  if (age < 0 || age > 5.0) {
    if (shouldRecordImageDiagnostic) {
      PB_RECORD_IMAGE_PASTE_DIAGNOSTIC(@"stale-request"
                                           requestId:requestId
                                             details:@{
                                               @"age" : @(age)
                                             });
    }
    if (shouldRecordTextInsertDiagnostic) {
      PBRecordTextInsertDiagnosticPhase(
          @"stale-request", requestId,
          @{@"age" : @(age)});
    }
    return;
  }

  BOOL didRestoreResponder = NO;
  UIResponder *responder =
      PBRestoreRecentEditableResponderIfNeeded(PBFindFirstResponder(),
                                               &didRestoreResponder);
  if (didRestoreResponder && requestId.length > 0) {
    if (!kPBResponderRestoreSettledRequestIds) {
      kPBResponderRestoreSettledRequestIds = [NSMutableSet set];
    }

    if (![kPBResponderRestoreSettledRequestIds containsObject:requestId]) {
      [kPBResponderRestoreSettledRequestIds addObject:requestId];
      PBInputBridgeDebugLog(@"defer request id=%@ after responder restore",
                            requestId);
      if (shouldRecordTextInsertDiagnostic) {
        PBRecordTextInsertDiagnosticPhase(@"defer-after-responder-restore",
                                          requestId, @{
          @"responderClass" : NSStringFromClass([responder class]) ?: @""
        });
      }
      dispatch_after(
          dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
          dispatch_get_main_queue(), ^{
            PBHandleInsertRequest();
          });
      return;
    }
  }
  BOOL handled = NO;
  BOOL isPasteRequest = [requestType isEqualToString:@"paste"];
  BOOL openedPasteboardReadWindow = NO;
  NSInteger keyboardTextPasteboardChangeCount = -1;
  PBInputBridgeDebugLog(
      @"handling request id=%@ type=%@ responder=%@ isPaste=%d", requestId,
      requestType, NSStringFromClass([responder class]), isPasteRequest);
  if (shouldRecordTextInsertDiagnostic) {
    NSMutableDictionary *details =
        [PBTextInsertResponderDiagnosticDetails(responder) mutableCopy];
    if (!details) {
      details = [NSMutableDictionary dictionary];
    }
    details[@"requestType"] = requestType ?: @"";
    details[@"age"] = @(age);
    PBRecordTextInsertDiagnosticPhase(@"handling", requestId, details);
  }

  if (!isPasteRequest && text.length == 0) {
    return;
  }

  @try {
    if (isPasteRequest) {
      BOOL hasRequestImage =
          [imageData isKindOfClass:[NSData class]] && imageData.length > 0;
      BOOL hasRequestText = !hasRequestImage &&
                            [text isKindOfClass:[NSString class]] &&
                            text.length > 0;
      NSInteger temporaryPasteChangeCount = -1;
      PBBeginInternalPasteboardReadWindow(requestId, targetBundleId);
      openedPasteboardReadWindow = YES;

      UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
      if (hasRequestImage) {
        NSString *stagingMode = @"raw-items";
        __unused BOOL beforeChangeCountSuccess = NO;
        __unused NSInteger beforeChangeCount =
            PBGeneralPasteboardChangeCount(pasteboard,
                                           &beforeChangeCountSuccess);
        if (PBSetPasteboardImageData(pasteboard, imageData, &stagingMode)) {
          temporaryPasteChangeCount = pasteboard.changeCount;
          [PBInputBridge
              recordInternalPasteboardWriteWithPasteboard:pasteboard
                                          imageDataLength:imageData.length];
          PBInputBridgeDebugLog(
              @"prepared request image to local pasteboard id=%@ bytes=%lu",
              requestId, (unsigned long)imageData.length);
          if (shouldRecordImageDiagnostic) {
            PB_RECORD_IMAGE_PASTE_DIAGNOSTIC(@"prepared"
                                      requestId:requestId
                                        details:@{
                                          @"imageBytes" : @(imageData.length),
                                          @"imageType" :
                                              PBImagePasteboardTypeForData(
                                                  imageData),
                                          @"pasteboardTypes" :
                                              PBImagePasteboardTypesForData(
                                                  imageData),
                                          @"changeCount" :
                                              @(temporaryPasteChangeCount),
                                          @"beforeChangeCount" :
                                              @(beforeChangeCount),
                                          @"beforeChangeCountSuccess" :
                                              @(beforeChangeCountSuccess),
                                          @"stagingMode" : stagingMode ?: @""
                                        });
          }
        } else {
          PBInputBridgeDebugLog(
              @"request image staging failed id=%@ bytes=%lu",
              requestId, (unsigned long)imageData.length);
          if (shouldRecordImageDiagnostic) {
            PB_RECORD_IMAGE_PASTE_DIAGNOSTIC(@"stage-failed"
                                      requestId:requestId
                                        details:@{
                                          @"imageBytes" : @(imageData.length),
                                          @"stagingMode" : stagingMode ?: @""
                                        });
          }
        }
      } else if (hasRequestText) {
        NSString *stagingMode = @"text-items";
        if (PBSetPasteboardText(pasteboard, text, &stagingMode)) {
          temporaryPasteChangeCount = pasteboard.changeCount;
          [PBInputBridge recordInternalPasteboardWriteWithPasteboard:pasteboard
                                                     imageDataLength:0];
          PBInputBridgeDebugLog(
              @"prepared request text to local pasteboard id=%@ length=%lu",
              requestId, (unsigned long)text.length);
        } else {
          PBInputBridgeDebugLog(
              @"request text staging failed id=%@ length=%lu mode=%@",
              requestId, (unsigned long)text.length, stagingMode ?: @"");
        }
      }
      PBBeginThreadLocalPaste(requestId);
      @try {
        handled = PBPerformPaste(responder, requestId);
      } @finally {
        PBEndThreadLocalPaste(requestId);
      }
      if (hasRequestImage && temporaryPasteChangeCount > 0) {
        PBScheduleTemporaryImagePasteboardCleanup(temporaryPasteChangeCount,
                                                  requestId);
      } else if (hasRequestText && temporaryPasteChangeCount > 0) {
        PBScheduleTemporaryTextPasteboardCleanup(temporaryPasteChangeCount,
                                                 requestId);
      }
      if (handled) {
        PBScheduleInternalPasteboardReadWindowClose(
            requestId, kPBOneShotPasteboardReadCloseDelay);
      }
    } else {
      BOOL changeCountSuccess = NO;
      keyboardTextPasteboardChangeCount =
          PBGeneralPasteboardChangeCount(nil, &changeCountSuccess);
      if (shouldRecordTextInsertDiagnostic) {
        PBRecordTextInsertDiagnosticPhase(
            @"keyboard-pasteboard-before-insert", requestId, @{
              @"changeCount" : @(keyboardTextPasteboardChangeCount),
              @"changeCountSuccess" : @(changeCountSuccess)
            });
      }
      handled = PBKeyboardInsertText(text, requestId, responder);
      if (handled) {
        PBScheduleKeyboardTextPasteboardCleanup(
            keyboardTextPasteboardChangeCount, requestId);
      }
    }
  } @finally {
    PBInputBridgeDebugLog(
        @"request id=%@ type=%@ handled=%d allowFlagBeforeClose=%d", requestId,
        requestType, handled, PBInputBridgeAllowsInternalPasteboardRead);
    if (openedPasteboardReadWindow && !handled) {
      PBEndInternalPasteboardReadWindow();
    }
  }
  if (shouldRecordImageDiagnostic) {
    PB_RECORD_IMAGE_PASTE_DIAGNOSTIC(@"performed"
                              requestId:requestId
                                details:@{
                                  @"handled" : @(handled),
                                  @"responderClass" :
                                          NSStringFromClass([responder class])
                                      ?: @"",
                                  @"allowFlagAfterPerform" : @(
                                      PBInputBridgeAllowsInternalPasteboardRead)
                                });
  }
  if (shouldRecordTextInsertDiagnostic) {
    NSMutableDictionary *details =
        [PBTextInsertResponderDiagnosticDetails(responder) mutableCopy];
    if (!details) {
      details = [NSMutableDictionary dictionary];
    }
    details[@"handled"] = @(handled);
    PBRecordTextInsertDiagnosticPhase(@"performed", requestId, details);
  }

  if (!handled) {
    if (isPasteRequest) {
      PBInputBridgeDebugLog(@"paste request %@ was not handled in %@",
                            requestId,
                            [[NSBundle mainBundle] bundleIdentifier]
                                ?: @"unknown");
      if (shouldRecordImageDiagnostic) {
        PB_RECORD_IMAGE_PASTE_DIAGNOSTIC(@"failed"
                                             requestId:requestId
                                               details:@{});
      }
      [kPBResponderRestoreSettledRequestIds removeObject:requestId];
      NSDictionary *currentRequest =
          [NSDictionary dictionaryWithContentsOfFile:requestPath];
      if ([currentRequest[@"id"] isEqualToString:requestId]) {
        [[NSFileManager defaultManager] removeItemAtPath:requestPath error:nil];
      }
      return;
    }

    if (!kPBInsertRetryCounts) {
      kPBInsertRetryCounts = [NSMutableDictionary dictionary];
    }

    NSInteger retryCount = [kPBInsertRetryCounts[requestId] integerValue];
    if (retryCount < kPBMaxInsertRetries) {
      kPBInsertRetryCounts[requestId] = @(retryCount + 1);
      PBInputBridgeDebugLog(@"request id=%@ not handled, retry=%ld", requestId,
                            (long)retryCount + 1);
      if (shouldRecordImageDiagnostic) {
        PB_RECORD_IMAGE_PASTE_DIAGNOSTIC(@"retry"
                                  requestId:requestId
                                    details:@{
                                      @"retry" : @((long)retryCount + 1)
                                    });
      }
      if (shouldRecordTextInsertDiagnostic) {
        PBRecordTextInsertDiagnosticPhase(
            @"retry", requestId,
            @{@"retry" : @((long)retryCount + 1)});
      }
      dispatch_after(
          dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
          dispatch_get_main_queue(), ^{
            PBHandleInsertRequest();
          });
    } else {
      [kPBInsertRetryCounts removeObjectForKey:requestId];
      PBInputBridgeDebugLog(@"insert request %@ was not handled in %@",
                            requestId,
                            [[NSBundle mainBundle] bundleIdentifier]
                                ?: @"unknown");
      if (shouldRecordImageDiagnostic) {
        PB_RECORD_IMAGE_PASTE_DIAGNOSTIC(@"failed"
                                             requestId:requestId
                                               details:@{});
      }
      if (shouldRecordTextInsertDiagnostic) {
        PBRecordTextInsertDiagnosticPhase(@"failed", requestId, @{});
      }
    }
    return;
  }

  kPBLastHandledRequestId = [requestId copy];
  [kPBInsertRetryCounts removeObjectForKey:requestId];
  [kPBResponderRestoreSettledRequestIds removeObject:requestId];
  [[NSFileManager defaultManager] removeItemAtPath:requestPath error:nil];
}

static void PBInputBridgeNotificationCallback(CFNotificationCenterRef center,
                                              void *observer,
                                              CFNotificationName name,
                                              const void *object,
                                              CFDictionaryRef userInfo) {
  PBInputBridgeDebugLog(@"darwin insert notification received");
  if (!PBInputBridgeMainFeatureEnabled()) {
    return;
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    PBHandleInsertRequest();
  });
}

@implementation PBInputBridge (AppExecutor)

+ (void)recordRecentEditableResponder:(UIResponder *)responder {
  PBRecordRecentEditableResponder(responder);
}

+ (BOOL)hasOneShotPasteboardReadAuthorization {
  @synchronized([PBInputBridge class]) {
    if (!PBInputBridgeAllowsInternalPasteboardRead ||
        kPBActivePasteRequestId.length == 0 ||
        !PBActivePasteTargetsCurrentProcess() ||
        kPBActivePastePolicyAllowCount >= kPBMaxOneShotPasteboardPolicyAllows) {
      return NO;
    }

    NSTimeInterval elapsed =
        [[NSDate date] timeIntervalSince1970] - kPBActivePasteWindowStartedAt;
    return elapsed >= 0 &&
           elapsed <= kPBOneShotPasteboardReadAuthorizationTimeout;
  }
}

+ (BOOL)hasRecentPasteRequestForCurrentProcess {
  NSDictionary *request =
      [NSDictionary dictionaryWithContentsOfFile:PBInputBridgeRequestPath()];
  if (![request isKindOfClass:[NSDictionary class]]) {
    return NO;
  }

  NSString *requestId = request[@"id"];
  NSString *requestType = request[@"type"];
  NSNumber *timestamp = request[@"timestamp"];
  if (requestId.length == 0 || ![requestType isEqualToString:@"paste"] ||
      ![timestamp isKindOfClass:[NSNumber class]]) {
    return NO;
  }

  NSTimeInterval age =
      [[NSDate date] timeIntervalSince1970] - timestamp.doubleValue;
  if (age < 0 || age > kPBOneShotPasteboardReadAuthorizationTimeout) {
    return NO;
  }

  @synchronized([PBInputBridge class]) {
    return [kPBActivePasteRequestId isEqualToString:requestId] &&
           PBInputBridgeAllowsInternalPasteboardRead &&
           PBActivePasteTargetsCurrentProcess() &&
           PBRequestTargetsCurrentProcess(request) &&
           kPBActivePastePolicyAllowCount < kPBMaxOneShotPasteboardPolicyAllows;
  }
}

+ (NSString *)
    consumePasteboardReadAuthorizationForPasteboardName:(id)pasteboardName
                                             policyName:(NSString *)policyName
                                            dataPurpose:(long long)dataPurpose {
  NSString *authorizationReason = nil;
  NSString *requestIdToClose = nil;
  BOOL shouldCloseSoon = NO;
  BOOL shouldCloseNow = NO;

  @synchronized([PBInputBridge class]) {
    if (!PBInputBridgeAllowsInternalPasteboardRead ||
        kPBActivePasteRequestId.length == 0) {
      return nil;
    }

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval elapsed = now - kPBActivePasteWindowStartedAt;
    if (elapsed < 0 || elapsed > kPBOneShotPasteboardReadAuthorizationTimeout) {
      shouldCloseNow = YES;
    } else if (!PBActivePasteTargetsCurrentProcess()) {
      PBInputBridgeDebugLog(@"reject paste policy target mismatch policy=%@ "
                            @"activeTarget=%@ current=%@",
                            policyName ?: @"",
                            kPBActivePasteTargetBundleId ?: @"",
                            PBCurrentBundleId());
    } else if (!PBPasteboardNameLooksGeneral(pasteboardName)) {
      PBInputBridgeDebugLog(
          @"reject paste policy pasteboard mismatch policy=%@ name=%@",
          policyName ?: @"", [pasteboardName description] ?: @"");
    } else if (kPBActivePastePolicyAllowCount >=
               kPBMaxOneShotPasteboardPolicyAllows) {
      PBInputBridgeDebugLog(@"reject paste policy allow count exceeded "
                            @"policy=%@ requestId=%@ count=%ld",
                            policyName ?: @"", kPBActivePasteRequestId ?: @"",
                            (long)kPBActivePastePolicyAllowCount);
    } else {
      NSString *threadRequestId = PBThreadLocalPasteRequestId();
      BOOL threadLocalMatch =
          [threadRequestId isEqualToString:kPBActivePasteRequestId];
      authorizationReason =
          threadLocalMatch ? @"thread-local" : @"async-fallback";
      kPBActivePastePolicyAllowCount++;

      PBInputBridgeDebugLog(@"allow paste policy=%@ reason=%@ requestId=%@ "
                            @"count=%ld elapsed=%.3f purpose=%lld",
                            policyName ?: @"", authorizationReason,
                            kPBActivePasteRequestId ?: @"",
                            (long)kPBActivePastePolicyAllowCount, elapsed,
                            dataPurpose);

      if (kPBActivePastePolicyAllowCount >=
          kPBMaxOneShotPasteboardPolicyAllows) {
        requestIdToClose = [kPBActivePasteRequestId copy];
        shouldCloseSoon = YES;
      }
    }
  }

  if (shouldCloseNow) {
    PBEndInternalPasteboardReadWindow();
  } else if (shouldCloseSoon) {
    PBScheduleInternalPasteboardReadWindowClose(requestIdToClose, 0.05);
  }

  return authorizationReason;
}

+ (void)endOneShotPasteboardReadAuthorization {
  PBEndThreadLocalPaste(kPBActivePasteRequestId);
  PBEndInternalPasteboardReadWindow();
}

+ (void)startListeningForInsertRequests {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        PBInputBridgeNotificationCallback,
        (__bridge CFStringRef)PBInputBridgeInsertNotification, NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);

    Class applicationClass = NSClassFromString(@"UIApplication");
    if (applicationClass &&
        [applicationClass respondsToSelector:@selector(sharedApplication)]) {
      [[NSNotificationCenter defaultCenter]
          addObserverForName:UIApplicationDidBecomeActiveNotification
                      object:nil
                       queue:[NSOperationQueue mainQueue]
                  usingBlock:^(__unused NSNotification *notification) {
                    PBHandleInsertRequest();
                  }];
    }
  });
}

@end
