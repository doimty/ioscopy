#import "PBInputBridgePrivate.h"

NSString *const PBInputBridgeInsertNotification =
    @"com.ssdsl.ioscopy/insertText.v2";
NSString *const PBInputBridgeUniversalInboxNotification =
    @"com.ssdsl.ioscopy/universalInboxChanged";
NSString *const PBInputBridgeSavePasteboardNotification =
    @"com.ssdsl.ioscopy/savePasteboard";
BOOL PBInputBridgeAllowsInternalPasteboardRead = NO;

@implementation PBInputBridge
@end
