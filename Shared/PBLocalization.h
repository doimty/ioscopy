#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NSString *PBLocalizedString(NSString *key);
NSString *PBLocalizedStringWithDefault(NSString *key, NSString *defaultValue);
NSString *PBLocalizedStringFromTable(NSString *key, NSString *table, NSString *defaultValue);

NS_ASSUME_NONNULL_END
