#import "PBDiagnosticLogger.h"

#if DEBUG_LOG

#import "PBPathUtilities.h"
#import <UIKit/UIKit.h>
#import <rootless.h>
#import <stdarg.h>

NSString * const PBDiagnosticStreamPasteAuth = @"pasteauth";
NSString * const PBDiagnosticStreamImagePaste = @"imagepaste";
NSString * const PBDiagnosticStreamTextInsert = @"textinsert";
NSString * const PBDiagnosticStreamSearch = @"search";
NSString * const PBDiagnosticStreamFrameRate = @"framerate";
NSString * const PBDiagnosticStreamPastedProbe = @"pastedprobe";

static void *kPBDiagnosticQueueKey = &kPBDiagnosticQueueKey;

static dispatch_queue_t PBDiagnosticQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.ssdsl.ioscopy.diagnostic-logger", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(queue, kPBDiagnosticQueueKey, kPBDiagnosticQueueKey, NULL);
    });
    return queue;
}

static NSString *PBDiagnosticPathForStream(NSString *stream) {
    if ([stream isEqualToString:PBDiagnosticStreamPasteAuth]) {
        return PBIOSCopyPreferenceFilePath(@"com.ssdsl.ioscopy.pasteauth.diagnostic.plist");
    }
    if ([stream isEqualToString:PBDiagnosticStreamImagePaste]) {
        return PBIOSCopyPreferenceFilePath(@"com.ssdsl.ioscopy.imagepaste.diagnostic.plist");
    }
    if ([stream isEqualToString:PBDiagnosticStreamTextInsert]) {
        return PBIOSCopyPreferenceFilePath(@"com.ssdsl.ioscopy.textinsert.diagnostic.plist");
    }
    if ([stream isEqualToString:PBDiagnosticStreamSearch]) {
        return PBIOSCopyPreferenceFilePath(@"com.ssdsl.ioscopy.search.diagnostic.plist");
    }
    if ([stream isEqualToString:PBDiagnosticStreamFrameRate]) {
        return PBIOSCopyPreferenceFilePath(@"com.ssdsl.ioscopy.framerate.diagnostic.plist");
    }
    if ([stream isEqualToString:PBDiagnosticStreamPastedProbe]) {
        return PBIOSCopyPreferenceFilePath(@"com.ssdsl.ioscopy.pastedprobe.plist");
    }
    return nil;
}

static NSUInteger PBDiagnosticMaxEventsForStream(NSString *stream) {
    if ([stream isEqualToString:PBDiagnosticStreamPasteAuth]) {
        return 240;
    }
    if ([stream isEqualToString:PBDiagnosticStreamImagePaste]) {
        return 120;
    }
    if ([stream isEqualToString:PBDiagnosticStreamTextInsert] ||
        [stream isEqualToString:PBDiagnosticStreamSearch]) {
        return 80;
    }
    if ([stream isEqualToString:PBDiagnosticStreamFrameRate]) {
        return 240;
    }
    if ([stream isEqualToString:PBDiagnosticStreamPastedProbe]) {
        return 80;
    }
    return 120;
}

static void PBDiagnosticPerformSync(dispatch_block_t block) {
    if (!block) {
        return;
    }

    if (dispatch_get_specific(kPBDiagnosticQueueKey) == kPBDiagnosticQueueKey) {
        block();
        return;
    }

    dispatch_sync(PBDiagnosticQueue(), block);
}

static id PBDiagnosticSanitizedValue(NSString *key, id value) {
    if (!value) {
        return nil;
    }

    NSString *lowerKey = [[key ?: @"" lowercaseString] copy];
    if ([value isKindOfClass:[NSData class]]) {
        return @([(NSData *)value length]);
    }
    if ([value isKindOfClass:[NSString class]]) {
        BOOL mayContainClipboardText =
            [lowerKey isEqualToString:@"content"] ||
            [lowerKey isEqualToString:@"text"] ||
            [lowerKey isEqualToString:@"string"] ||
            [lowerKey isEqualToString:@"url"] ||
            [lowerKey containsString:@"textcontent"];
        if (mayContainClipboardText) {
            return @{@"length" : @([(NSString *)value length])};
        }
        if ([(NSString *)value length] > 240) {
            return [[(NSString *)value substringToIndex:240] stringByAppendingString:@"..."];
        }
        return value;
    }
    if ([value isKindOfClass:[NSNumber class]] ||
        [value isKindOfClass:[NSDate class]]) {
        return value;
    }
    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *items = [NSMutableArray array];
        for (id item in (NSArray *)value) {
            id sanitized = PBDiagnosticSanitizedValue(key, item);
            if (sanitized) {
                [items addObject:sanitized];
            }
            if (items.count >= 40) {
                break;
            }
        }
        return [items copy];
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
        [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id nestedKey, id nestedValue, BOOL *stop) {
            if (![nestedKey isKindOfClass:[NSString class]]) {
                return;
            }

            id sanitized = PBDiagnosticSanitizedValue(nestedKey, nestedValue);
            if (sanitized) {
                dictionary[nestedKey] = sanitized;
            }
            if (dictionary.count >= 60) {
                *stop = YES;
            }
        }];
        return [dictionary copy];
    }

    return [[value description] copy] ?: @"";
}

NSDictionary *PBDiagnosticSanitizedDetails(NSDictionary *details) {
    if (![details isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    NSMutableDictionary *sanitized = [NSMutableDictionary dictionary];
    [details enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        if (![key isKindOfClass:[NSString class]]) {
            return;
        }

        id sanitizedValue = PBDiagnosticSanitizedValue(key, value);
        if (sanitizedValue) {
            sanitized[key] = sanitizedValue;
        }
    }];
    return sanitized.count > 0 ? [sanitized copy] : nil;
}

void PBDiagnosticClearStream(NSString *stream) {
    NSString *path = PBDiagnosticPathForStream(stream);
    if (path.length == 0) {
        return;
    }

    PBDiagnosticPerformSync(^{
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    });
}

void PBDiagnosticAppendEvent(NSString *stream, NSDictionary *event) {
    NSString *path = PBDiagnosticPathForStream(stream);
    if (path.length == 0 || ![event isKindOfClass:[NSDictionary class]] || event.count == 0) {
        return;
    }

    NSDictionary *eventSnapshot = PBDiagnosticSanitizedDetails(event);
    if (eventSnapshot.count == 0) {
        return;
    }

    NSUInteger maxEvents = PBDiagnosticMaxEventsForStream(stream);
    dispatch_async(PBDiagnosticQueue(), ^{
        @autoreleasepool {
            NSMutableDictionary *diagnostic =
                [[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy];
            if (![diagnostic isKindOfClass:[NSMutableDictionary class]]) {
                diagnostic = [NSMutableDictionary dictionary];
            }

            NSMutableArray *events = [diagnostic[@"events"] mutableCopy];
            if (![events isKindOfClass:[NSMutableArray class]]) {
                events = [NSMutableArray array];
            }

            [events addObject:eventSnapshot];
            while (events.count > maxEvents) {
                [events removeObjectAtIndex:0];
            }

            id requestId = eventSnapshot[@"requestId"];
            if ([requestId isKindOfClass:[NSString class]] && [(NSString *)requestId length] > 0) {
                diagnostic[@"requestId"] = requestId;
            }
            diagnostic[@"updatedAt"] = @([[NSDate date] timeIntervalSince1970]);
            diagnostic[@"events"] = events;
            PBIOSCopyWritePropertyListToFile(diagnostic, path, YES);
        }
    });
}

void PBDiagnosticRecordEvent(NSString *stream, NSString *phase, NSDictionary *details) {
    if (phase.length == 0) {
        return;
    }

    NSInteger appState = -1;
    Class applicationClass = NSClassFromString(@"UIApplication");
    if (applicationClass && [applicationClass respondsToSelector:@selector(sharedApplication)]) {
        UIApplication *application = [applicationClass sharedApplication];
        appState = application.applicationState;
    }

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSMutableDictionary *event = [@{
        @"timestamp" : @(now),
        @"time" : @(now),
        @"phase" : phase,
        @"processName" : [[NSProcessInfo processInfo] processName] ?: @"",
        @"bundleId" : [[NSBundle mainBundle] bundleIdentifier] ?: @"",
        @"mainThread" : @([NSThread isMainThread]),
        @"appState" : @(appState)
    } mutableCopy];

    if ([details isKindOfClass:[NSDictionary class]]) {
        [event addEntriesFromDictionary:details];
    }

    PBDiagnosticAppendEvent(stream, event);
}

void PBDiagnosticLog(NSString *stream, NSString *category, NSString *format, ...) {
    if (format.length == 0) {
        return;
    }

    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    PBDiagnosticRecordEvent(stream, @"debug-log", @{
        @"category" : category ?: @"",
        @"message" : message ?: @""
    });
}

#endif
