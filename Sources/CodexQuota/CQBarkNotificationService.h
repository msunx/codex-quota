#import <Foundation/Foundation.h>
#import "CQTaskMonitor.h"

NS_ASSUME_NONNULL_BEGIN

@interface CQBarkNotificationService : NSObject
@property(nonatomic, readonly) BOOL enabled;
@property(nonatomic, copy, readonly) NSString *deliveryStatus;
@property(nonatomic, readonly) BOOL deliveryFailed;
@property(nonatomic, copy, nullable) void (^statusDidChange)(void);

- (nullable NSString *)savedEndpointWithError:(NSError **)error;
- (BOOL)saveEndpoint:(NSString *)endpoint enabled:(BOOL)enabled error:(NSError **)error;
- (BOOL)clearConfigurationWithError:(NSError **)error;
- (void)sendTestToEndpoint:(NSString *)endpoint completion:(void (^)(NSError * _Nullable error))completion;
- (void)handleSnapshot:(CQTaskSnapshot *)snapshot;
@end

NS_ASSUME_NONNULL_END
