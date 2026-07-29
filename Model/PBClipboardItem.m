#import "PBClipboardItem.h"
#import "../Shared/PBLocalization.h"

@implementation PBClipboardItem

- (BOOL)isEqual:(id)object {
    if (self == object) {
        return YES;
    }
    if (![object isKindOfClass:[PBClipboardItem class]]) {
        return NO;
    }

    PBClipboardItem *otherItem = (PBClipboardItem *)object;
    if (self.itemId <= 0 || otherItem.itemId <= 0) {
        return NO;
    }
    return self.itemId == otherItem.itemId;
}

- (NSUInteger)hash {
    return self.itemId > 0 ? (NSUInteger)self.itemId : [super hash];
}

+ (instancetype)itemWithContent:(NSString *)content
                    contentType:(PBContentType)contentType
                 sourceBundleId:(NSString *)bundleId
                  sourceAppName:(NSString *)appName {
    PBClipboardItem *item = [[PBClipboardItem alloc] init];
    item.content = content;
    item.contentType = contentType;
    item.sourceBundleId = bundleId ?: @"";
    item.sourceAppName = appName ?: PBLocalizedString(@"Unknown");
    item.timestamp = [[NSDate date] timeIntervalSince1970];
    item.isPinned = NO;
    item.isFavorite = NO;
    item.dataSize = [content lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    item.ocrText = @"";
    item.ocrError = @"";
    item.ocrStatus = PBOCRStatusPending;
    item.ocrRevision = 0;
    item.ocrUpdatedAt = 0;
    return item;
}

- (NSString *)relativeTimeString {
    NSTimeInterval elapsed = [[NSDate date] timeIntervalSince1970] - self.timestamp;
    
    if (elapsed < 5) return PBLocalizedString(@"Just Now");
    if (elapsed < 60) return [NSString stringWithFormat:PBLocalizedString(@"%.0f SEC AGO"), elapsed];
    if (elapsed < 3600) return [NSString stringWithFormat:PBLocalizedString(@"%.0f MIN AGO"), elapsed / 60.0];
    if (elapsed < 86400) return [NSString stringWithFormat:PBLocalizedString(@"%.0f HOURS AGO"), elapsed / 3600.0];
    if (elapsed < 604800) return [NSString stringWithFormat:PBLocalizedString(@"%.0f DAYS AGO"), elapsed / 86400.0];
    
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateStyle = NSDateFormatterMediumStyle;
    formatter.timeStyle = NSDateFormatterShortStyle;
    return [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:self.timestamp]];
}

- (NSString *)contentPreview {
    if (!self.content) return @"";
    
    switch (self.contentType) {
        case PBContentTypeImage: {
            NSString *trimmedOCR = [self.ocrText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            trimmedOCR = [trimmedOCR stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
            if (trimmedOCR.length > 0) {
                if (trimmedOCR.length > 200) {
                    return [[trimmedOCR substringToIndex:200] stringByAppendingString:@"…"];
                }
                return trimmedOCR;
            }

            CGFloat sizeKB = self.dataSize / 1024.0;
            if (sizeKB > 1024) {
                return [NSString stringWithFormat:PBLocalizedString(@"📷 Image (%.1f MB)"), sizeKB / 1024.0];
            }
            return [NSString stringWithFormat:PBLocalizedString(@"📷 Image (%.0f KB)"), sizeKB];
        }
        case PBContentTypeURL:
            return self.content;
        case PBContentTypeText: {
            NSString *trimmed = [self.content stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            // 预览文本中用空格替换换行，避免列表卡片高度抖动
            trimmed = [trimmed stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
            if (trimmed.length > 200) {
                return [[trimmed substringToIndex:200] stringByAppendingString:@"…"];
            }
            return trimmed;
        }
        default:
            return PBLocalizedString(@"[Other Content]");
    }
}

- (NSString *)contentTypeIcon {
    switch (self.contentType) {
        case PBContentTypeText: return @"doc.text";
        case PBContentTypeImage: return @"photo";
        case PBContentTypeURL: return @"link";
        default: return @"doc";
    }
}

@end
