#import <Foundation/Foundation.h>
#import "CQTaskMonitor.h"

NS_ASSUME_NONNULL_BEGIN

@interface CQTaskNotificationController : NSObject
@property(nonatomic, copy, nullable) void (^taskSelectedHandler)(CQCodexTask *task);

- (void)start;
- (void)handleSnapshot:(CQTaskSnapshot *)snapshot;
@end

NS_ASSUME_NONNULL_END
