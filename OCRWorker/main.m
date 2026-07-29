#import "../Manager/PBImageOCRIndexer.h"
#import <Foundation/Foundation.h>
#import <rootless.h>
#import <notify.h>
#import <stdio.h>
#import <unistd.h>

static NSString * const kPBOCRWorkerRequestNotification = @"com.ssdsl.ioscopy/ocrworkerrequest";

static NSInteger PBOCRWorkerLimitFromArguments(NSArray<NSString *> *arguments) {
    NSUInteger index = [arguments indexOfObject:@"--limit"];
    if (index == NSNotFound || index + 1 >= arguments.count) {
        return 1;
    }

    NSInteger limit = [arguments[index + 1] integerValue];
    if (limit < 1) {
        return 1;
    }
    if (limit > 50) {
        return 50;
    }
    return limit;
}

static NSString *PBOCRWorkerRequestPath(void) {
    return ROOT_PATH_NS(@"/var/mobile/Library/iOSCopy/ocr-request.plist");
}

static NSDictionary *PBOCRWorkerRequest(void) {
    NSDictionary *request = [NSDictionary dictionaryWithContentsOfFile:PBOCRWorkerRequestPath()];
    return [request isKindOfClass:[NSDictionary class]] ? request : @{};
}

static NSInteger PBOCRWorkerBoundedLimit(NSInteger limit) {
    if (limit < 1) {
        return 1;
    }
    if (limit > 50) {
        return 50;
    }
    return limit;
}

static void PBOCRWorkerProcessRequest(NSInteger defaultLimit, BOOL defaultRetryFailed) {
    @autoreleasepool {
        NSDictionary *request = PBOCRWorkerRequest();
        NSInteger limit = request[@"limit"] ? [request[@"limit"] integerValue] : defaultLimit;
        BOOL retryFailed = request[@"retryFailed"] ? [request[@"retryFailed"] boolValue] : defaultRetryFailed;
        limit = PBOCRWorkerBoundedLimit(limit);

        [[PBImageOCRIndexer sharedIndexer] processPendingImageIndexingWithLimit:limit
                                                                    retryFailed:retryFailed];
    }
}

static void PBOCRWorkerKeepAlive(void) {
    for (;;) {
        sleep(3600);
    }
}

static int PBOCRWorkerRunDaemon(void) {
    @autoreleasepool {
        dispatch_queue_t queue = dispatch_queue_create("com.ssdsl.ioscopy.ocrd", DISPATCH_QUEUE_SERIAL);
        int token = NOTIFY_TOKEN_INVALID;
        notify_register_dispatch([kPBOCRWorkerRequestNotification UTF8String],
                                 &token,
                                 queue,
                                 ^(int notificationToken) {
            PBOCRWorkerProcessRequest(1, NO);
        });
        dispatch_async(queue, ^{
            PBOCRWorkerProcessRequest(3, NO);
        });
        PBOCRWorkerKeepAlive();
    }
    return 0;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        setvbuf(stderr, NULL, _IONBF, 0);

        NSArray<NSString *> *arguments = [[NSProcessInfo processInfo] arguments];
        if ([arguments containsObject:@"--daemon"]) {
            return PBOCRWorkerRunDaemon();
        }

        NSInteger limit = PBOCRWorkerLimitFromArguments(arguments);
        BOOL retryFailed = [arguments containsObject:@"--retry-failed"];

        NSInteger processedCount = [[PBImageOCRIndexer sharedIndexer] processPendingImageIndexingWithLimit:limit
                                                                                               retryFailed:retryFailed];
        return processedCount >= 0 ? 0 : 1;
    }
}
