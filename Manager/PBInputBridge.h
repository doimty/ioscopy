#import <Foundation/Foundation.h>

#ifndef DEBUG_LOG
#define DEBUG_LOG 0
#endif

@class UIResponder;

extern NSString * const PBInputBridgeInsertNotification;
extern NSString * const PBInputBridgeUniversalInboxNotification;
extern NSString * const PBInputBridgeSavePasteboardNotification;
extern BOOL PBInputBridgeAllowsInternalPasteboardRead;

@interface PBInputBridge : NSObject
@end

@interface PBInputBridge (RequestClient)

+ (void)sendInsertRequestWithText:(NSString *)text targetInfo:(NSDictionary *)targetInfo;
+ (void)sendPasteRequestWithText:(NSString *)text targetInfo:(NSDictionary *)targetInfo;
+ (void)sendPasteRequestWithImageData:(NSData *)imageData targetInfo:(NSDictionary *)targetInfo;

@end

@interface PBInputBridge (AppExecutor)

+ (void)startListeningForInsertRequests;
+ (void)recordRecentEditableResponder:(UIResponder *)responder;
+ (BOOL)hasOneShotPasteboardReadAuthorization;
+ (BOOL)hasRecentPasteRequestForCurrentProcess;
+ (NSString *)consumePasteboardReadAuthorizationForPasteboardName:(id)pasteboardName
                                                      policyName:(NSString *)policyName
                                                     dataPurpose:(long long)dataPurpose;
+ (void)endOneShotPasteboardReadAuthorization;

@end

@interface PBInputBridge (SourceState)

+ (void)recordCurrentProcessAsRecentInputTarget;
+ (NSDictionary *)recentInputTargetInfo;
+ (BOOL)recordOpenTriggerTargetFromRecentInputTarget;
+ (NSDictionary *)consumeRecentOpenTriggerTargetInfo;

+ (void)recordPasteboardSourceWithPasteboard:(id)pasteboard;
+ (void)recordPasteboardSourceWithPasteboard:(id)pasteboard
                                     content:(NSString *)content
                                   imageData:(NSData *)imageData;
+ (void)recordPasteboardSourceWithPasteboard:(id)pasteboard
                                    bundleId:(NSString *)bundleId
                                     appName:(NSString *)appName
                                 processName:(NSString *)processName
                                     content:(NSString *)content
                                   imageData:(NSData *)imageData;
+ (void)recordUniversalPasteboardSourceWithPasteboard:(id)pasteboard
                                              content:(NSString *)content
                                            imageData:(NSData *)imageData;
+ (NSDictionary *)recentPasteboardSourceInfoForChangeCount:(NSInteger)changeCount;

@end

@interface PBInputBridge (SpringBoardCapture)

+ (void)requestSpringBoardPasteboardCaptureWithReason:(NSString *)reason
                                          changeCount:(NSInteger)changeCount
                                           sourceInfo:(NSDictionary *)sourceInfo;
+ (NSDictionary *)pendingSpringBoardPasteboardCaptureRequest;
+ (NSDictionary *)recentSpringBoardPasteboardCaptureForPasteAnnouncement;
+ (void)completeSpringBoardPasteboardCaptureRequestWithRequestId:(NSString *)requestId;

@end

@interface PBInputBridge (SpringBoardReadAuth)

+ (NSString *)beginSpringBoardPasteboardReadAuthorizationForChangeCount:(NSInteger)changeCount
                                                                 reason:(NSString *)reason
                                                             sourceInfo:(NSDictionary *)sourceInfo;
+ (NSString *)consumeSpringBoardPasteboardReadAuthorizationForChangeCount:(NSInteger)changeCount
                                                               policyName:(NSString *)policyName
                                                              dataPurpose:(long long)dataPurpose;
+ (void)endSpringBoardPasteboardReadAuthorizationWithRequestId:(NSString *)requestId;

@end

@interface PBInputBridge (UniversalInbox)

+ (BOOL)recordUniversalClipboardInboxItemWithContent:(NSString *)content
                                           imageData:(NSData *)imageData
                                             source:(NSString *)source;
+ (NSArray<NSDictionary *> *)pendingUniversalClipboardInboxItems;
+ (void)deleteUniversalClipboardInboxItem:(NSDictionary *)itemInfo;

@end

@interface PBInputBridge (PasteState)

+ (void)recordInternalPasteboardWriteWithPasteboard:(id)pasteboard
                                    imageDataLength:(NSUInteger)imageDataLength;
+ (NSDictionary *)recentInternalPasteboardWriteInfoForChangeCount:(NSInteger)changeCount;
+ (void)clearInternalPasteboardWriteInfo;

@end

@interface PBInputBridge (OutgoingSuppression)

+ (void)beginOutgoingPasteboardSuppressionForRequestId:(NSString *)requestId
                                           contentKind:(NSString *)contentKind
                                            targetInfo:(NSDictionary *)targetInfo;
+ (NSDictionary *)activeOutgoingPasteboardSuppressionInfoForChangeCount:(NSInteger)changeCount;

@end

#if DEBUG_LOG
#import "../Shared/PBDiagnosticLogger.h"

@interface PBInputBridge (Diagnostics)

+ (void)recordImagePasteDiagnosticPhase:(NSString *)phase
                              requestId:(NSString *)requestId
                                details:(NSDictionary *)details;
+ (void)clearImagePasteDiagnostic;
+ (void)recordClipboardCaptureDiagnosticPhase:(NSString *)phase
                                      details:(NSDictionary *)details;

@end
#endif

#if DEBUG_LOG
#define PB_CLEAR_IMAGE_PASTE_DIAGNOSTIC() [PBInputBridge clearImagePasteDiagnostic]
#define PB_RECORD_IMAGE_PASTE_DIAGNOSTIC(...) \
  [PBInputBridge recordImagePasteDiagnosticPhase:__VA_ARGS__]
#define PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(...) \
  [PBInputBridge recordClipboardCaptureDiagnosticPhase:__VA_ARGS__]
#else
#define PB_CLEAR_IMAGE_PASTE_DIAGNOSTIC() do { } while (0)
#define PB_RECORD_IMAGE_PASTE_DIAGNOSTIC(...) do { } while (0)
#define PB_RECORD_CLIPBOARD_CAPTURE_DIAGNOSTIC(...) do { } while (0)
#endif
