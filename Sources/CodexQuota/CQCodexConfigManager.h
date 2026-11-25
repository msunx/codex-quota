#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CQCodexConfigManager : NSObject
- (BOOL)restoreLegacyConfigurationIfNeededWithError:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
