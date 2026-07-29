#import <Foundation/Foundation.h>

#ifndef DEBUG_LOG
#define DEBUG_LOG 0
#endif

#if DEBUG_LOG

#ifdef __cplusplus
extern "C" {
#endif

FOUNDATION_EXPORT NSString * const PBDiagnosticStreamPasteAuth;
FOUNDATION_EXPORT NSString * const PBDiagnosticStreamImagePaste;
FOUNDATION_EXPORT NSString * const PBDiagnosticStreamTextInsert;
FOUNDATION_EXPORT NSString * const PBDiagnosticStreamSearch;
FOUNDATION_EXPORT NSString * const PBDiagnosticStreamFrameRate;
FOUNDATION_EXPORT NSString * const PBDiagnosticStreamPastedProbe;

void PBDiagnosticClearStream(NSString *stream);
void PBDiagnosticAppendEvent(NSString *stream, NSDictionary *event);
void PBDiagnosticRecordEvent(NSString *stream, NSString *phase, NSDictionary *details);
void PBDiagnosticLog(NSString *stream, NSString *category, NSString *format, ...) NS_FORMAT_FUNCTION(3, 4);
NSDictionary *PBDiagnosticSanitizedDetails(NSDictionary *details);

#ifdef __cplusplus
}
#endif

#endif
