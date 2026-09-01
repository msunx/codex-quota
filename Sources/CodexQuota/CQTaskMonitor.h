#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CQTaskState) {
    CQTaskStateWaitingForApproval,
    CQTaskStateCompletedUnread,
    CQTaskStateRunning
};

@interface CQCodexTask : NSObject
@property(nonatomic, copy) NSString *threadID;
@property(nonatomic, copy) NSString *turnID;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *projectName;
@property(nonatomic, copy) NSString *workingDirectory;
@property(nonatomic) CQTaskState state;
@property(nonatomic, strong) NSDate *startedAt;
@property(nonatomic, strong, nullable) NSDate *completedAt;
@end

@interface CQTaskSnapshot : NSObject
@property(nonatomic, copy) NSArray<CQCodexTask *> *waitingForApprovalTasks;
@property(nonatomic, copy) NSArray<CQCodexTask *> *runningTasks;
@property(nonatomic, copy) NSArray<CQCodexTask *> *unreadCompletedTasks;

+ (instancetype)emptySnapshot;
- (NSUInteger)attentionCount;
- (NSString *)contentSignature;
@end

@interface CQTaskMonitor : NSObject
@property(nonatomic, copy, nullable) void (^snapshotDidUpdate)(CQTaskSnapshot *snapshot);
@property(nonatomic, strong, readonly) CQTaskSnapshot *snapshot;

- (void)start;
- (void)stop;
- (void)refreshNow;
- (void)markTaskViewed:(CQCodexTask *)task;
- (void)markAllCompletedViewed;
@end

NS_ASSUME_NONNULL_END
