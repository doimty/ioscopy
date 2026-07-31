#import "PBPasteboardUtilities.h"

#pragma mark - Pasteboard type classification

BOOL PBPasteboardTypeLooksImage(NSString *type) {
    NSString *lower = [type lowercaseString];
    return [lower containsString:@"image"] ||
           [lower containsString:@"png"] ||
           [lower containsString:@"jpeg"] ||
           [lower containsString:@"jpg"] ||
           [lower containsString:@"heic"] ||
           [lower containsString:@"heif"] ||
           [lower containsString:@"tiff"] ||
           [lower containsString:@"gif"];
}

BOOL PBPasteboardTypeLooksHTML(NSString *type) {
    NSString *lower = [type lowercaseString];
    return [lower containsString:@"html"];
}

BOOL PBPasteboardTypeLooksPlainText(NSString *type) {
    NSString *lower = [type lowercaseString];
    return [lower isEqualToString:@"public.utf8-plain-text"] ||
           [lower isEqualToString:@"public.plain-text"] ||
           [lower isEqualToString:@"public.text"] ||
           [lower containsString:@"plain-text"] ||
           [lower containsString:@"utf8-plain-text"] ||
           ([lower containsString:@"text"] && ![lower containsString:@"html"]);
}

BOOL PBPasteboardTypeLooksText(NSString *type) {
    NSString *lower = [type lowercaseString];
    return !PBPasteboardTypeLooksHTML(type) &&
           (PBPasteboardTypeLooksPlainText(type) ||
            [lower containsString:@"string"] ||
            [lower containsString:@"utf8"] ||
            [lower isEqualToString:@"public.url"] ||
            [lower isEqualToString:@"public.uri"] ||
            [lower containsString:@"url"]);
}

#pragma mark - Data → text conversion

NSString *PBTextFromData(NSData *data) {
    if (![data isKindOfClass:[NSData class]] || data.length == 0) {
        return nil;
    }

    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text.length == 0) {
        text = [[NSString alloc] initWithData:data encoding:NSUTF16StringEncoding];
    }
    return text.length > 0 ? text : nil;
}

#pragma mark - HTML → plain text conversion

NSString *PBStringByReplacingRegularExpression(NSString *text,
                                               NSString *pattern,
                                               NSString *replacement) {
    if (text.length == 0 || pattern.length == 0) {
        return text;
    }

    NSRegularExpression *expression =
        [NSRegularExpression regularExpressionWithPattern:pattern
                                                  options:0
                                                    error:nil];
    if (!expression) {
        return text;
    }

    NSRange range = NSMakeRange(0, text.length);
    return [expression stringByReplacingMatchesInString:text
                                                options:0
                                                  range:range
                                           withTemplate:replacement ?: @""];
}

NSString *PBStringByDecodingCommonHTMLEntities(NSString *text) {
    if (text.length == 0) {
        return text;
    }

    NSDictionary<NSString *, NSString *> *entities = @{
        @"&nbsp;": @" ",
        @"&#160;": @" ",
        @"&lt;": @"<",
        @"&gt;": @">",
        @"&amp;": @"&",
        @"&quot;": @"\"",
        @"&#34;": @"\"",
        @"&#39;": @"'",
        @"&apos;": @"'"
    };

    NSMutableString *result = [text mutableCopy];
    for (NSString *entity in entities) {
        [result replaceOccurrencesOfString:entity
                                 withString:entities[entity]
                                    options:NSCaseInsensitiveSearch
                                      range:NSMakeRange(0, result.length)];
    }
    return [result copy];
}

NSString *PBStringByStrippingHTMLTags(NSString *html) {
    if (html.length == 0) {
        return html;
    }

    NSMutableString *result = [NSMutableString string];
    BOOL insideTag = NO;
    unichar quote = 0;
    for (NSUInteger index = 0; index < html.length; index++) {
        unichar character = [html characterAtIndex:index];
        if (insideTag) {
            if (quote != 0) {
                if (character == quote) {
                    quote = 0;
                }
                continue;
            }
            if (character == '"' || character == '\'') {
                quote = character;
                continue;
            }
            if (character == '>') {
                insideTag = NO;
            }
            continue;
        }

        if (character == '<') {
            insideTag = YES;
            quote = 0;
            continue;
        }

        [result appendFormat:@"%C", character];
    }
    return [result copy];
}

NSString *PBPlainTextFromHTMLString(NSString *html) {
    if (html.length == 0) {
        return nil;
    }

    NSString *text = html;
    text = PBStringByReplacingRegularExpression(text, @"(?is)<(script|style)[^>]*>.*?</\\1>", @"");
    text = PBStringByReplacingRegularExpression(text, @"(?i)<br\\s*/?>", @"\n");
    text = PBStringByReplacingRegularExpression(text, @"(?i)</(div|p|li|tr|h[1-6])\\s*>", @"\n");
    text = PBStringByStrippingHTMLTags(text);
    text = PBStringByDecodingCommonHTMLEntities(text);
    text = [text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
    text = [text stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return text.length > 0 ? text : nil;
}

#pragma mark - Process identification

BOOL PBIsSpringBoardProcess(NSString *processName, NSString *bundleId) {
    return [bundleId isEqualToString:@"com.apple.springboard"] ||
           [processName isEqualToString:@"SpringBoard"];
}
