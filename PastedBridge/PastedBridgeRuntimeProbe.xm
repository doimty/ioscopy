#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "../Shared/PBDiagnosticLogger.h"
#import "../Shared/PBPathUtilities.h"
#import <rootless.h>

// 开发期 pasted runtime/signature 探针。默认不加入 PastedBridge target 构建。
static BOOL const kPBPastedBridgeProbeDebugLogging = NO;
static BOOL const kPBPastedBridgeSignatureProbeEnabledByDefault = NO;
static BOOL const kPBPastedBridgeRuntimeProbeEnabledByDefault = NO;

static NSString *PBPastedBridgeProbePath(void);

#if DEBUG_LOG
#define PBPastedBridgeProbeDebugLog(...) do { \
    if (kPBPastedBridgeProbeDebugLogging) { \
        PBDiagnosticLog(PBDiagnosticStreamPastedProbe, @"PastedBridgeProbe", __VA_ARGS__); \
    } \
} while (0)
#else
#define PBPastedBridgeProbeDebugLog(...) do { } while (0)
#endif

static NSString *PBPastedBridgeProbePath(void) {
    return PBIOSCopyPreferenceFilePath(@"com.ssdsl.ioscopy.pastedprobe.plist");
}

static NSString *PBPastedBridgeSignatureProbePath(void) {
    return PBIOSCopyPreferenceFilePath(@"com.ssdsl.ioscopy.pastedsignatures.plist");
}

static NSString *PBPastedBridgeSignatureProbeFlagPath(void) {
    return PBIOSCopyPreferenceFilePath(@"com.ssdsl.ioscopy.enablepastedsignatureprobe");
}

static NSString *PBPastedBridgeProbeFlagPath(void) {
    return PBIOSCopyPreferenceFilePath(@"com.ssdsl.ioscopy.enablepastedfullprobe");
}

static BOOL PBPastedBridgeShouldRunSignatureProbe(void) {
    if (kPBPastedBridgeSignatureProbeEnabledByDefault) {
        return YES;
    }

    return [[NSFileManager defaultManager] fileExistsAtPath:PBPastedBridgeSignatureProbeFlagPath()];
}

static BOOL PBPastedBridgeShouldRunRuntimeProbe(void) {
    if (kPBPastedBridgeRuntimeProbeEnabledByDefault) {
        return YES;
    }

    return [[NSFileManager defaultManager] fileExistsAtPath:PBPastedBridgeProbeFlagPath()];
}

static BOOL PBStringContainsAnyToken(NSString *string, NSArray<NSString *> *tokens) {
    NSString *lower = [string lowercaseString];
    for (NSString *token in tokens) {
        if ([lower containsString:token]) {
            return YES;
        }
    }
    return NO;
}

static NSArray<NSString *> *PBInterestingMethodTokens(void) {
    return @[
        @"paste",
        @"item",
        @"data",
        @"save",
        @"set",
        @"add",
        @"insert",
        @"update",
        @"write",
        @"receive",
        @"load",
        @"provide",
        @"material",
        @"continuity",
        @"universal",
        @"remote",
        @"sync"
    ];
}

static NSString *PBStringFromCopiedRuntimeType(char *type) {
    if (!type) {
        return @"";
    }

    NSString *result = [NSString stringWithUTF8String:type] ?: @"";
    free(type);
    return result;
}

static NSDictionary *PBMethodProbeDetail(Method method) {
    SEL selector = method_getName(method);
    NSString *methodName = NSStringFromSelector(selector);
    NSString *typeEncoding = @"";
    const char *rawTypeEncoding = method_getTypeEncoding(method);
    if (rawTypeEncoding) {
        typeEncoding = [NSString stringWithUTF8String:rawTypeEncoding] ?: @"";
    }

    unsigned int argumentCount = method_getNumberOfArguments(method);
    NSMutableArray<NSString *> *argumentTypes = [NSMutableArray arrayWithCapacity:argumentCount];
    for (unsigned int index = 0; index < argumentCount; index++) {
        [argumentTypes addObject:PBStringFromCopiedRuntimeType(method_copyArgumentType(method, index))];
    }

    return @{
        @"name": methodName ?: @"",
        @"typeEncoding": typeEncoding ?: @"",
        @"returnType": PBStringFromCopiedRuntimeType(method_copyReturnType(method)),
        @"argumentCount": @(argumentCount),
        @"argumentTypes": argumentTypes ?: @[]
    };
}

static NSDictionary *PBMissingMethodProbeDetail(NSString *selectorName) {
    return @{
        @"name": selectorName ?: @"",
        @"present": @NO,
        @"typeEncoding": @"",
        @"returnType": @"",
        @"argumentCount": @0,
        @"argumentTypes": @[]
    };
}

static NSDictionary *PBMethodProbeDetailForSelector(Class cls, NSString *selectorName, BOOL classMethod) {
    SEL selector = NSSelectorFromString(selectorName);
    Method method = classMethod ? class_getClassMethod(cls, selector) : class_getInstanceMethod(cls, selector);
    if (!method) {
        return PBMissingMethodProbeDetail(selectorName);
    }

    NSMutableDictionary *detail = [PBMethodProbeDetail(method) mutableCopy];
    detail[@"present"] = @YES;
    return [detail copy];
}

static NSArray<NSDictionary *> *PBTargetMethodProbeDetails(Class cls,
                                                           NSArray<NSString *> *selectorNames,
                                                           BOOL classMethod) {
    NSMutableArray<NSDictionary *> *details = [NSMutableArray arrayWithCapacity:selectorNames.count];
    for (NSString *selectorName in selectorNames) {
        [details addObject:PBMethodProbeDetailForSelector(cls, selectorName, classMethod)];
    }
    return [details copy];
}

static NSArray<NSDictionary *> *PBMethodProbeDetailsForClass(Class cls, BOOL metaClass) {
    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(metaClass ? object_getClass(cls) : cls, &methodCount);
    NSMutableArray<NSDictionary *> *details = [NSMutableArray array];
    NSArray<NSString *> *interestingTokens = PBInterestingMethodTokens();

    for (unsigned int index = 0; index < methodCount; index++) {
        SEL selector = method_getName(methods[index]);
        NSString *methodName = NSStringFromSelector(selector);
        if (PBStringContainsAnyToken(methodName, interestingTokens)) {
            [details addObject:PBMethodProbeDetail(methods[index])];
        }
    }

    if (methods) {
        free(methods);
    }
    return [details copy];
}

static NSArray<NSString *> *PBMethodNamesFromProbeDetails(NSArray<NSDictionary *> *details) {
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:details.count];
    for (NSDictionary *detail in details) {
        NSString *name = detail[@"name"];
        if (name.length > 0) {
            [names addObject:name];
        }
    }
    return [names copy];
}

static void PBDumpPastedTargetedSignatureProbe(void) {
    if (!PBPastedBridgeShouldRunSignatureProbe()) {
        return;
    }
    if (!kPBPastedBridgeSignatureProbeEnabledByDefault) {
        [[NSFileManager defaultManager] removeItemAtPath:PBPastedBridgeSignatureProbeFlagPath() error:nil];
    }

    NSArray<NSDictionary *> *targets = @[
        @{
            @"class": @"PBPasteboardModel",
            @"instanceSelectors": @[
                @"_pushRemotePasteboard:",
                @"_remotePasteboardDidBecomeAvailable:",
                @"_remotePasteboardWillBeFetched:",
                @"workQueue_createRemoteGeneralPasteboardWithChangeCount:",
                @"workQueue_saveGeneralPasteboardFromContinuityPasteboard:",
                @"workQueue_reallyFaultDataForRemotePasteboard:processInfo:completionBlock:",
                @"workQueue_faultDataForRemotePasteboard:processInfo:completionBlock:",
                @"workQueue_reallyFaultMetadataForRemotePasteboard:processInfo:completionBlock:",
                @"workQueue_faultMetadataForRemotePasteboard:processInfo:completionBlock:",
                @"workQueue_savePasteboard:isServerToServerCopy:outNotificationState:outChangeCount:",
                @"savePasteboard:deviceIslocked:completionBlock:"
            ],
            @"classSelectors": @[]
        },
        @{
            @"class": @"PBPasteboardServerServicer",
            @"instanceSelectors": @[
                @"savePasteboard:dataProviderEndpoint:completionBlock:",
                @"requestFromPasteboardWithName:UUID:authenticationMessage:itemIndex:needData:dataOwner:loadContext:errorBlock:pasteboardItemBlock:",
                @"requestItemFromPasteboardWithName:UUID:authenticationMessage:itemIndex:typeIdentifier:dataOwner:loadContext:completionBlock:",
                @"getRemoteContentForLayerContextWithId:slotStyle:pasteButtonTag:completionBlock:"
            ],
            @"classSelectors": @[]
        },
        @{
            @"class": @"PBRemotePasteboardItemProvider",
            @"instanceSelectors": @[
                @"initWithType:item:",
                @"getDataWithCompletionBlock:",
                @"getDataFileWithCompletionBlock:",
                @"item",
                @"type",
                @"setItem:",
                @"setType:"
            ],
            @"classSelectors": @[]
        },
        @{
            @"class": @"UASharedPasteboard",
            @"instanceSelectors": @[
                @"requestRemotePasteboardTypesForProcess:withCompletion:",
                @"requestRemotePasteboardDataForProcess:withCompletion:",
                @"prefetchRemotePasteboardTypes:",
                @"returnPasteboardDataBeforeArchives",
                @"currentRemoteDeviceName"
            ],
            @"classSelectors": @[
                @"remotePasteboard",
                @"localPasteboardDidAddData:toItemAtIndex:generation:",
                @"localPasteboardDidAddItems:forGeneration:",
                @"localPasteboardDidPasteGeneration:"
            ]
        },
        @{
            @"class": @"UASharedPasteboardManager",
            @"instanceSelectors": @[
                @"requestRemotePasteboardTypesForProcess:withCompletion:",
                @"requestRemotePasteboardDataForProcess:withCompletion:",
                @"fetchPasteboardTypesForProcess:withCompletion:",
                @"fetchPasteboardDataForProcess:withCompletion:",
                @"addData:toItemAtIndex:generation:",
                @"localPasteboardWasFetched",
                @"remotePasteboardAvailable",
                @"setRemotePasteboardAvailable:",
                @"currentRemoteDeviceName",
                @"setCurrentGeneration:"
            ],
            @"classSelectors": @[]
        },
        @{
            @"class": @"UAPasteboardGeneration",
            @"instanceSelectors": @[
                @"items",
                @"setItems:",
                @"addItem:",
                @"addType:toItemAtIndex:",
                @"setAllTypes:",
                @"setTypePaths:"
            ],
            @"classSelectors": @[]
        },
        @{
            @"class": @"UAPasteboardDataProvider",
            @"instanceSelectors": @[
                @"initWithData:type:",
                @"data",
                @"type",
                @"setData:",
                @"setType:",
                @"getDataWithCompletionBlock:"
            ],
            @"classSelectors": @[]
        },
        @{
            @"class": @"UAPasteboardFileItemProvider",
            @"instanceSelectors": @[
                @"getDataWithCompletionBlock:",
                @"getDataFileWithCompletionBlock:",
                @"fileURL",
                @"type",
                @"setFileURL:",
                @"setType:"
            ],
            @"classSelectors": @[]
        }
    ];

    NSMutableArray<NSDictionary *> *matches = [NSMutableArray arrayWithCapacity:targets.count];
    NSUInteger presentMethodCount = 0;
    for (NSDictionary *target in targets) {
        NSString *className = target[@"class"];
        Class cls = NSClassFromString(className);
        NSArray<NSString *> *instanceSelectors = target[@"instanceSelectors"] ?: @[];
        NSArray<NSString *> *classSelectors = target[@"classSelectors"] ?: @[];
        NSArray<NSDictionary *> *instanceMethodDetails = cls ? PBTargetMethodProbeDetails(cls, instanceSelectors, NO) : @[];
        NSArray<NSDictionary *> *classMethodDetails = cls ? PBTargetMethodProbeDetails(cls, classSelectors, YES) : @[];

        for (NSDictionary *detail in instanceMethodDetails) {
            if ([detail[@"present"] boolValue]) {
                presentMethodCount++;
            }
        }
        for (NSDictionary *detail in classMethodDetails) {
            if ([detail[@"present"] boolValue]) {
                presentMethodCount++;
            }
        }

        [matches addObject:@{
            @"class": className ?: @"",
            @"present": @(cls != Nil),
            @"instanceMethodDetails": instanceMethodDetails ?: @[],
            @"classMethodDetails": classMethodDetails ?: @[]
        }];
    }

    NSDictionary *probe = @{
        @"timestamp": @([[NSDate date] timeIntervalSince1970]),
        @"processName": [[NSProcessInfo processInfo] processName] ?: @"",
        @"bundleId": [[NSBundle mainBundle] bundleIdentifier] ?: @"",
        @"targets": matches
    };

    NSString *path = PBPastedBridgeSignatureProbePath();
    BOOL wrote = PBIOSCopyWritePropertyListToFile(probe, path, YES);
    PBPastedBridgeProbeDebugLog(@"targeted signature probe wrote=%d path=%@ targets=%lu methods=%lu",
                                wrote,
                                path,
                                (unsigned long)matches.count,
                                (unsigned long)presentMethodCount);
}

static void PBDumpPastedRuntimeProbe(void) {
    if (!PBPastedBridgeShouldRunRuntimeProbe()) {
        return;
    }

    if (!kPBPastedBridgeRuntimeProbeEnabledByDefault) {
        [[NSFileManager defaultManager] removeItemAtPath:PBPastedBridgeProbeFlagPath() error:nil];
    }

    int classCount = objc_getClassList(NULL, 0);
    if (classCount <= 0) {
        return;
    }

    Class *classes = (Class *)calloc((size_t)classCount, sizeof(Class));
    if (!classes) {
        return;
    }

    objc_getClassList(classes, classCount);
    NSArray<NSString *> *classTokens = @[
        @"paste",
        @"pasteboard",
        @"clipboard",
        @"continuity",
        @"universal",
        @"remote",
        @"provider"
    ];

    NSMutableArray<NSDictionary *> *matches = [NSMutableArray array];
    for (int index = 0; index < classCount; index++) {
        Class cls = classes[index];
        const char *rawName = class_getName(cls);
        if (!rawName) {
            continue;
        }

        NSString *className = [NSString stringWithUTF8String:rawName];
        BOOL isPBClass = [className hasPrefix:@"PB"] || [className hasPrefix:@"_PB"];
        if (!isPBClass && !PBStringContainsAnyToken(className, classTokens)) {
            continue;
        }

        NSArray<NSDictionary *> *instanceMethodDetails = PBMethodProbeDetailsForClass(cls, NO);
        NSArray<NSDictionary *> *classMethodDetails = PBMethodProbeDetailsForClass(cls, YES);
        NSArray<NSString *> *instanceMethods = PBMethodNamesFromProbeDetails(instanceMethodDetails);
        NSArray<NSString *> *classMethods = PBMethodNamesFromProbeDetails(classMethodDetails);
        if (instanceMethods.count == 0 &&
            classMethods.count == 0 &&
            !PBStringContainsAnyToken(className, classTokens)) {
            continue;
        }

        [matches addObject:@{
            @"class": className,
            @"instanceMethods": instanceMethods ?: @[],
            @"classMethods": classMethods ?: @[],
            @"instanceMethodDetails": instanceMethodDetails ?: @[],
            @"classMethodDetails": classMethodDetails ?: @[]
        }];
    }

    free(classes);

    NSDictionary *probe = @{
        @"timestamp": @([[NSDate date] timeIntervalSince1970]),
        @"processName": [[NSProcessInfo processInfo] processName] ?: @"",
        @"bundleId": [[NSBundle mainBundle] bundleIdentifier] ?: @"",
        @"classCount": @(classCount),
        @"matches": matches
    };

    NSString *path = PBPastedBridgeProbePath();
    BOOL wrote = PBIOSCopyWritePropertyListToFile(probe, path, YES);
    PBPastedBridgeProbeDebugLog(@"runtime probe wrote=%d path=%@ matches=%lu classes=%d",
                                wrote,
                                path,
                                (unsigned long)matches.count,
                                classCount);
}

%ctor {
    @autoreleasepool {
        PBDumpPastedTargetedSignatureProbe();
        PBDumpPastedRuntimeProbe();
    }
}
