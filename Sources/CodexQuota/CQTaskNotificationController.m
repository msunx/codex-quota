#import "CQTaskNotificationController.h"
#import <UserNotifications/UserNotifications.h>
#import <os/log.h>

static NSString * const CQTaskNotificationDeliveredEventsKey = @"TaskNotificationDeliveredEvents";
static NSString * const CQTaskNotificationBaselineKey = @"TaskNotificationBaseline";
static NSString * const CQTaskNotificationApprovalPrefix = @"approval:";
static NSString * const CQTaskNotificationCompletionPrefix = @"completed:";
static NSTimeInterval const CQTaskNotificationRetentionInterval = 7 * 24 * 60 * 60;

static os_log_t CQTaskNotificationLogger(void) {
    static os_log_t logger;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        logger = os_log_create("com.muyang.codexquota", "notifications");
    });
    return logger;
}

@interface CQTaskNotificationController () <UNUserNotificationCenterDelegate>
@property(nonatomic, strong) UNUserNotificationCenter *notificationCenter;
@property(nonatomic, copy) NSSet<NSString *> *waitingTurnIDs;
@property(nonatomic, copy) NSSet<NSString *> *completedTurnIDs;
@property(nonatomic, strong, nullable) CQTaskSnapshot *pendingSnapshot;
@property(nonatomic) BOOL authorizationResolved;
@property(nonatomic) BOOL notificationsAuthorized;
@end

@implementation CQTaskNotificationController

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _notificationCenter = UNUserNotificationCenter.currentNotificationCenter;
    _waitingTurnIDs = [NSSet set];
    _completedTurnIDs = [NSSet set];
    return self;
}

- (void)start {
    NSAssert(NSThread.isMainThread, @"CQTaskNotificationController must be started on the main thread");
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (![defaults objectForKey:CQTaskNotificationBaselineKey]) {
        [defaults setDouble:floor(NSDate.date.timeIntervalSince1970) forKey:CQTaskNotificationBaselineKey];
    }
    self.notificationCenter.delegate = self;
    __weak typeof(self) weakSelf = self;
    [self.notificationCenter requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound
                                           completionHandler:^(BOOL granted, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self) return;
            self.authorizationResolved = YES;
            self.notificationsAuthorized = granted;
            if (error) os_log_error(CQTaskNotificationLogger(), "Notification authorization failed: %{public}@", error.localizedDescription);
            CQTaskSnapshot *pendingSnapshot = self.pendingSnapshot;
            self.pendingSnapshot = nil;
            if (granted && pendingSnapshot) [self processSnapshot:pendingSnapshot];
        });
    }];
}

- (void)handleSnapshot:(CQTaskSnapshot *)snapshot {
    NSAssert(NSThread.isMainThread, @"CQTaskNotificationController snapshots must be handled on the main thread");
    if (!self.authorizationResolved) {
        self.pendingSnapshot = snapshot;
        return;
    }
    if (!self.notificationsAuthorized) return;
    [self processSnapshot:snapshot];
}

- (void)processSnapshot:(CQTaskSnapshot *)snapshot {
    NSMutableDictionary<NSString *, NSNumber *> *deliveredEvents = [self deliveredEventsPrunedAtDate:NSDate.date];
    NSSet<NSString *> *currentWaitingTurnIDs = [self turnIDsForTasks:snapshot.waitingForApprovalTasks];
    NSSet<NSString *> *currentCompletedTurnIDs = [self turnIDsForTasks:snapshot.unreadCompletedTasks];

    for (CQCodexTask *task in snapshot.waitingForApprovalTasks) {
        if ([self.waitingTurnIDs containsObject:task.turnID]) continue;
        [self deliverNotificationForTask:task prefix:CQTaskNotificationApprovalPrefix deliveredEvents:deliveredEvents];
    }
    for (CQCodexTask *task in snapshot.unreadCompletedTasks) {
        if ([self.completedTurnIDs containsObject:task.turnID]) continue;
        [self deliverNotificationForTask:task prefix:CQTaskNotificationCompletionPrefix deliveredEvents:deliveredEvents];
    }

    NSArray<NSString *> *eventKeys = deliveredEvents.allKeys.copy;
    for (NSString *eventKey in eventKeys) {
        if (![eventKey hasPrefix:CQTaskNotificationApprovalPrefix]) continue;
        NSString *turnID = [eventKey substringFromIndex:CQTaskNotificationApprovalPrefix.length];
        if (![currentWaitingTurnIDs containsObject:turnID]) [deliveredEvents removeObjectForKey:eventKey];
    }
    [NSUserDefaults.standardUserDefaults setObject:deliveredEvents forKey:CQTaskNotificationDeliveredEventsKey];
    self.waitingTurnIDs = currentWaitingTurnIDs;
    self.completedTurnIDs = currentCompletedTurnIDs;
}

- (NSSet<NSString *> *)turnIDsForTasks:(NSArray<CQCodexTask *> *)tasks {
    NSMutableSet<NSString *> *turnIDs = [NSMutableSet setWithCapacity:tasks.count];
    for (CQCodexTask *task in tasks) {
        if (task.turnID.length > 0) [turnIDs addObject:task.turnID];
    }
    return turnIDs;
}

- (NSMutableDictionary<NSString *, NSNumber *> *)deliveredEventsPrunedAtDate:(NSDate *)date {
    NSDictionary *stored = [NSUserDefaults.standardUserDefaults dictionaryForKey:CQTaskNotificationDeliveredEventsKey];
    NSMutableDictionary<NSString *, NSNumber *> *deliveredEvents = [NSMutableDictionary dictionary];
    NSTimeInterval cutoff = date.timeIntervalSince1970 - CQTaskNotificationRetentionInterval;
    [stored enumerateKeysAndObjectsUsingBlock:^(NSString *eventKey, NSNumber *timestamp, BOOL *stop) {
        (void)stop;
        if ([eventKey isKindOfClass:NSString.class]
            && [timestamp isKindOfClass:NSNumber.class]
            && timestamp.doubleValue >= cutoff) {
            deliveredEvents[eventKey] = timestamp;
        }
    }];
    return deliveredEvents;
}

- (void)deliverNotificationForTask:(CQCodexTask *)task
                             prefix:(NSString *)prefix
                    deliveredEvents:(NSMutableDictionary<NSString *, NSNumber *> *)deliveredEvents {
    if (task.turnID.length == 0) return;
    NSString *eventKey = [prefix stringByAppendingString:task.turnID];
    if (deliveredEvents[eventKey]) return;

    BOOL waitingForApproval = [prefix isEqualToString:CQTaskNotificationApprovalPrefix];
    NSTimeInterval baseline = [NSUserDefaults.standardUserDefaults doubleForKey:CQTaskNotificationBaselineKey];
    if (!waitingForApproval && task.completedAt.timeIntervalSince1970 < baseline) {
        deliveredEvents[eventKey] = @(NSDate.date.timeIntervalSince1970);
        return;
    }
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = waitingForApproval ? @"任务需要审批" : @"任务已完成";
    content.subtitle = task.title.length > 0 ? task.title : @"未命名任务";
    content.body = task.projectName.length > 0
        ? [NSString stringWithFormat:@"项目：%@", task.projectName]
        : (waitingForApproval ? @"Codex 正在等待你的操作" : @"Codex 已完成任务");
    content.sound = UNNotificationSound.defaultSound;
    content.threadIdentifier = task.threadID ?: @"";
    content.userInfo = @{
        @"threadID": task.threadID ?: @"",
        @"turnID": task.turnID,
        @"title": task.title ?: @"未命名任务",
        @"projectName": task.projectName ?: @"本机任务",
        @"workingDirectory": task.workingDirectory ?: @"",
        @"state": @(task.state),
        @"startedAt": @(task.startedAt.timeIntervalSince1970),
        @"completedAt": @(task.completedAt.timeIntervalSince1970)
    };

    deliveredEvents[eventKey] = @(NSDate.date.timeIntervalSince1970);
    [NSUserDefaults.standardUserDefaults setObject:deliveredEvents forKey:CQTaskNotificationDeliveredEventsKey];
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:eventKey content:content trigger:nil];
    [self.notificationCenter addNotificationRequest:request withCompletionHandler:^(NSError *error) {
        if (!error) return;
        os_log_error(CQTaskNotificationLogger(), "Failed to deliver task notification: %{public}@", error.localizedDescription);
        dispatch_async(dispatch_get_main_queue(), ^{
            NSMutableDictionary *stored = [[NSUserDefaults.standardUserDefaults dictionaryForKey:CQTaskNotificationDeliveredEventsKey] mutableCopy];
            [stored removeObjectForKey:eventKey];
            [NSUserDefaults.standardUserDefaults setObject:stored ?: @{} forKey:CQTaskNotificationDeliveredEventsKey];
        });
    }];
}

- (CQCodexTask *)taskFromNotification:(UNNotification *)notification {
    NSDictionary *userInfo = notification.request.content.userInfo;
    CQCodexTask *task = [CQCodexTask new];
    task.threadID = [userInfo[@"threadID"] isKindOfClass:NSString.class] ? userInfo[@"threadID"] : @"";
    task.turnID = [userInfo[@"turnID"] isKindOfClass:NSString.class] ? userInfo[@"turnID"] : @"";
    task.title = [userInfo[@"title"] isKindOfClass:NSString.class] ? userInfo[@"title"] : @"未命名任务";
    task.projectName = [userInfo[@"projectName"] isKindOfClass:NSString.class] ? userInfo[@"projectName"] : @"本机任务";
    task.workingDirectory = [userInfo[@"workingDirectory"] isKindOfClass:NSString.class] ? userInfo[@"workingDirectory"] : @"";
    task.state = [userInfo[@"state"] isKindOfClass:NSNumber.class] ? [userInfo[@"state"] integerValue] : CQTaskStateRunning;
    NSTimeInterval startedAt = [userInfo[@"startedAt"] isKindOfClass:NSNumber.class] ? [userInfo[@"startedAt"] doubleValue] : NSDate.date.timeIntervalSince1970;
    NSTimeInterval completedAt = [userInfo[@"completedAt"] isKindOfClass:NSNumber.class] ? [userInfo[@"completedAt"] doubleValue] : 0;
    task.startedAt = [NSDate dateWithTimeIntervalSince1970:startedAt];
    task.completedAt = completedAt > 0 ? [NSDate dateWithTimeIntervalSince1970:completedAt] : nil;
    return task;
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler {
    (void)center;
    (void)notification;
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList | UNNotificationPresentationOptionSound);
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void (^)(void))completionHandler {
    (void)center;
    CQCodexTask *task = [self taskFromNotification:response.notification];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.taskSelectedHandler) self.taskSelectedHandler(task);
        completionHandler();
    });
}

@end
