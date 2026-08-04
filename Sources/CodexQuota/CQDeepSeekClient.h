#import <Foundation/Foundation.h>
#import "CQModels.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^CQDeepSeekBalanceBlock)(CQDeepSeekBalance * _Nullable balance,
                                       NSError * _Nullable error);

@interface CQDeepSeekClient : NSObject
- (void)fetchBalanceWithAPIKey:(NSString *)apiKey completion:(CQDeepSeekBalanceBlock)completion;
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
