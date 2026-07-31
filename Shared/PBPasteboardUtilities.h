#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Pasteboard type classification
BOOL PBPasteboardTypeLooksImage(NSString *type);
BOOL PBPasteboardTypeLooksHTML(NSString *type);
BOOL PBPasteboardTypeLooksPlainText(NSString *type);
BOOL PBPasteboardTypeLooksText(NSString *type);

// Data → text conversion
NSString *PBTextFromData(NSData *data);

// HTML → plain text conversion
NSString *PBStringByReplacingRegularExpression(NSString *text,
                                               NSString *pattern,
                                               NSString *replacement);
NSString *PBStringByDecodingCommonHTMLEntities(NSString *text);
NSString *PBStringByStrippingHTMLTags(NSString *html);
NSString *PBPlainTextFromHTMLString(NSString *html);

// Process identification
BOOL PBIsSpringBoardProcess(NSString *processName, NSString *bundleId);

#ifdef __cplusplus
}
#endif
