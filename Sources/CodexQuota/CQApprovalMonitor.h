#import <Foundation/Foundation.h>
#import "CQTaskMonitor.h"

NS_ASSUME_NONNULL_BEGIN

// Used only on the task monitor's serial query queue.
@interface CQApprovalMonitor : NSObject
- (instancetype)initWithQueue:(dispatch_queue_t)queue;
- (NSSet<NSString *> *)waitingTurnIDsForTasks:(NSArray<CQCodexTask *> *)tasks;
- (BOOL)isTaskConfirmedIdle:(CQCodexTask *)task;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
