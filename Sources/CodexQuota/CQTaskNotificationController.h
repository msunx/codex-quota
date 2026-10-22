#import <Foundation/Foundation.h>
#import "CQTaskMonitor.h"
#import "CQBarkNotificationService.h"

NS_ASSUME_NONNULL_BEGIN

@interface CQTaskNotificationController : NSObject
@property(nonatomic, copy, nullable) void (^taskSelectedHandler)(CQCodexTask *task);
@property(nonatomic, strong, readonly) CQBarkNotificationService *barkService;

- (void)start;
- (void)handleSnapshot:(CQTaskSnapshot *)snapshot;
@end

NS_ASSUME_NONNULL_END
