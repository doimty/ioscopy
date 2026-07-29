#import "PBInputBridgePrivate.h"

#if DEBUG_LOG

@implementation PBInputBridge (Diagnostics)

+ (void)clearImagePasteDiagnostic {
  PBDiagnosticClearStream(PBDiagnosticStreamImagePaste);
}

+ (void)recordImagePasteDiagnosticPhase:(NSString *)phase
                              requestId:(NSString *)requestId
                                details:(NSDictionary *)details {
  if (phase.length == 0) {
    return;
  }

  NSMutableDictionary *entry = [NSMutableDictionary dictionary];
  entry[@"requestId"] = requestId ?: @"";
  if ([details isKindOfClass:[NSDictionary class]]) {
    [entry addEntriesFromDictionary:details];
  }
  PBDiagnosticRecordEvent(PBDiagnosticStreamImagePaste, phase, entry);
}

+ (void)recordClipboardCaptureDiagnosticPhase:(NSString *)phase
                                      details:(NSDictionary *)details {
  if (phase.length == 0) {
    return;
  }

  PBDiagnosticRecordEvent(PBDiagnosticStreamPasteAuth, phase, details);
}

@end

#endif
