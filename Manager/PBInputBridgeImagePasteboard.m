#import "PBInputBridgePrivate.h"
#if !IOSCOPY_INPUTBRIDGE_TWEAK
#import <ImageIO/ImageIO.h>
#endif
#import <UIKit/UIKit.h>

static BOOL PBImageDataLooksJPEG(NSData *data) {
  if (![data isKindOfClass:[NSData class]] || data.length < 2) {
    return NO;
  }

  const unsigned char *bytes = data.bytes;
  return bytes[0] == 0xFF && bytes[1] == 0xD8;
}

static BOOL PBImageDataLooksPNG(NSData *data) {
  if (![data isKindOfClass:[NSData class]] || data.length < 8) {
    return NO;
  }

  const unsigned char *bytes = data.bytes;
  return bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E &&
         bytes[3] == 0x47;
}

static BOOL PBImageDataLooksGIF(NSData *data) {
  if (![data isKindOfClass:[NSData class]] || data.length < 3) {
    return NO;
  }

  const unsigned char *bytes = data.bytes;
  return bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46;
}

static BOOL PBImageDataLooksTIFF(NSData *data) {
  if (![data isKindOfClass:[NSData class]] || data.length < 4) {
    return NO;
  }

  const unsigned char *bytes = data.bytes;
  return (bytes[0] == 0x49 && bytes[1] == 0x49 && bytes[2] == 0x2A &&
          bytes[3] == 0x00) ||
         (bytes[0] == 0x4D && bytes[1] == 0x4D && bytes[2] == 0x00 &&
          bytes[3] == 0x2A);
}

static BOOL PBImageDataLooksHEIF(NSData *data) {
  if (![data isKindOfClass:[NSData class]] || data.length < 12) {
    return NO;
  }

  const unsigned char *bytes = data.bytes;
  return bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 &&
         bytes[7] == 0x70;
}

NSString *PBImagePasteboardTypeForData(NSData *data) {
  if (PBImageDataLooksPNG(data)) {
    return @"public.png";
  }
  if (PBImageDataLooksJPEG(data)) {
    return @"public.jpeg";
  }
  if (PBImageDataLooksGIF(data)) {
    return @"com.compuserve.gif";
  }
  if (PBImageDataLooksTIFF(data)) {
    return @"public.tiff";
  }
  if (PBImageDataLooksHEIF(data)) {
    return @"public.heic";
  }
  return @"public.image";
}

static NSData *PBCreateSRGBJPEGDataFromImageData(NSData *imageData) {
  if (![imageData isKindOfClass:[NSData class]] || imageData.length == 0) {
    return nil;
  }

#if IOSCOPY_INPUTBRIDGE_TWEAK
  UIImage *image = [UIImage imageWithData:imageData];
  CGImageRef decodedImage = image.CGImage;
  if (!decodedImage) {
    return nil;
  }

  size_t width = CGImageGetWidth(decodedImage);
  size_t height = CGImageGetHeight(decodedImage);
  if (width == 0 || height == 0) {
    return nil;
  }

  CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  if (!colorSpace) {
    return nil;
  }

  CGContextRef context = CGBitmapContextCreate(
      NULL, width, height, 8, 0, colorSpace,
      kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(colorSpace);
  if (!context) {
    return nil;
  }

  CGRect bounds = CGRectMake(0, 0, (CGFloat)width, (CGFloat)height);
  CGContextSetRGBFillColor(context, 1.0, 1.0, 1.0, 1.0);
  CGContextFillRect(context, bounds);
  CGContextDrawImage(context, bounds, decodedImage);

  CGImageRef normalizedImage = CGBitmapContextCreateImage(context);
  CGContextRelease(context);
  if (!normalizedImage) {
    return nil;
  }

  UIImage *normalizedUIImage = [UIImage imageWithCGImage:normalizedImage
                                                   scale:image.scale
                                             orientation:UIImageOrientationUp];
  CGImageRelease(normalizedImage);
  return UIImageJPEGRepresentation(normalizedUIImage, 0.96);
#else
  CGImageSourceRef source =
      CGImageSourceCreateWithData((__bridge CFDataRef)imageData, NULL);
  if (!source) {
    return nil;
  }

  NSDictionary *sourceOptions = @{
    (__bridge NSString *)kCGImageSourceShouldCache : @YES,
    (__bridge NSString *)kCGImageSourceShouldAllowFloat : @NO
  };
  CGImageRef decodedImage = CGImageSourceCreateImageAtIndex(
      source, 0, (__bridge CFDictionaryRef)sourceOptions);
  CFRelease(source);
  if (!decodedImage) {
    return nil;
  }

  size_t width = CGImageGetWidth(decodedImage);
  size_t height = CGImageGetHeight(decodedImage);
  if (width == 0 || height == 0) {
    CGImageRelease(decodedImage);
    return nil;
  }

  CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  if (!colorSpace) {
    CGImageRelease(decodedImage);
    return nil;
  }

  CGContextRef context = CGBitmapContextCreate(
      NULL, width, height, 8, 0, colorSpace,
      kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(colorSpace);
  if (!context) {
    CGImageRelease(decodedImage);
    return nil;
  }

  CGRect bounds = CGRectMake(0, 0, (CGFloat)width, (CGFloat)height);
  CGContextSetRGBFillColor(context, 1.0, 1.0, 1.0, 1.0);
  CGContextFillRect(context, bounds);
  CGContextDrawImage(context, bounds, decodedImage);
  CGImageRelease(decodedImage);

  CGImageRef normalizedImage = CGBitmapContextCreateImage(context);
  CGContextRelease(context);
  if (!normalizedImage) {
    return nil;
  }

  NSMutableData *jpegData = [NSMutableData data];
  CGImageDestinationRef destination = CGImageDestinationCreateWithData(
      (__bridge CFMutableDataRef)jpegData, CFSTR("public.jpeg"), 1, NULL);
  if (!destination) {
    CGImageRelease(normalizedImage);
    return nil;
  }

  NSDictionary *properties = @{
    (__bridge NSString *)kCGImageDestinationLossyCompressionQuality : @0.96
  };
  CGImageDestinationAddImage(destination, normalizedImage,
                             (__bridge CFDictionaryRef)properties);
  BOOL success = CGImageDestinationFinalize(destination);
  CFRelease(destination);
  CGImageRelease(normalizedImage);

  return success && jpegData.length > 0 ? [jpegData copy] : nil;
#endif
}

static NSDictionary *PBImagePasteboardItemForData(NSData *imageData) {
  NSString *type = PBImagePasteboardTypeForData(imageData);
  NSMutableDictionary *item = [@{type : imageData} mutableCopy];
  if (![type isEqualToString:@"public.image"]) {
    item[@"public.image"] = imageData;
  }
  return item;
}

#if DEBUG_LOG
NSArray<NSString *> *PBImagePasteboardTypesForData(NSData *imageData) {
  return [[PBImagePasteboardItemForData(imageData) allKeys]
      sortedArrayUsingSelector:@selector(compare:)];
}
#endif

BOOL PBSetPasteboardImageData(UIPasteboard *pasteboard,
                                     NSData *imageData,
                                     NSString **stagingMode) {
  if (![imageData isKindOfClass:[NSData class]] || imageData.length == 0) {
    return NO;
  }

  if (stagingMode) {
    *stagingMode = @"raw-items";
  }

  if (PBImageDataLooksHEIF(imageData)) {
    NSData *jpegData = PBCreateSRGBJPEGDataFromImageData(imageData);
    if (jpegData.length > 0) {
      pasteboard.items =
          @[ @{@"public.jpeg" : jpegData, @"public.image" : jpegData} ];
      if (stagingMode) {
        *stagingMode = @"jpeg-compatible";
      }
      return YES;
    }

    if (stagingMode) {
      *stagingMode = @"jpeg-compatible-failed";
    }
    return NO;
  }

  pasteboard.items = @[ PBImagePasteboardItemForData(imageData) ];
  return YES;
}

BOOL PBSetPasteboardText(UIPasteboard *pasteboard, NSString *text,
                                NSString **stagingMode) {
  if (![text isKindOfClass:[NSString class]] || text.length == 0) {
    return NO;
  }

  if (stagingMode) {
    *stagingMode = @"text-items";
  }

  pasteboard.items =
      @[ @{@"public.utf8-plain-text" : text, @"public.plain-text" : text} ];
  return YES;
}

NSInteger PBGeneralPasteboardChangeCount(UIPasteboard *pasteboard,
                                                BOOL *success) {
  if (success) {
    *success = NO;
  }

  UIPasteboard *targetPasteboard =
      pasteboard ?: [UIPasteboard generalPasteboard];
  if (!targetPasteboard) {
    return -1;
  }

  @try {
    NSInteger changeCount = targetPasteboard.changeCount;
    if (success) {
      *success = YES;
    }
    return changeCount;
  } @catch (__unused NSException *exception) {
    return -1;
  }
}
