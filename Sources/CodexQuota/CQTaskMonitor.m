#import "CQTaskMonitor.h"
#import <sqlite3.h>

static NSString * const CQTaskMonitorBaselineKey = @"TaskMonitorCompletionBaseline";
static NSString * const CQTaskMonitorViewedTurnsKey = @"TaskMonitorViewedCompletedTurns";
static NSTimeInterval const CQTaskRetentionInterval = 7 * 24 * 60 * 60;

@implementation CQCodexTask
@end

@implementation CQTaskSnapshot

+ (instancetype)emptySnapshot {
    CQTaskSnapshot *snapshot = [CQTaskSnapshot new];
    snapshot.waitingForApprovalTasks = @[];
    snapshot.runningTasks = @[];
    snapshot.unreadCompletedTasks = @[];
    return snapshot;
}

- (NSUInteger)attentionCount {
    return self.waitingForApprovalTasks.count + self.runningTasks.count + self.unreadCompletedTasks.count;
}

- (NSString *)contentSignature {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSArray<NSArray<CQCodexTask *> *> *groups = @[
        self.waitingForApprovalTasks ?: @[],
        self.unreadCompletedTasks ?: @[],
        self.runningTasks ?: @[]
    ];
    for (NSArray<CQCodexTask *> *group in groups) {
        for (CQCodexTask *task in group) {
            [parts addObject:[NSString stringWithFormat:@"%@:%ld:%@:%@:%0.f:%0.f",
                task.turnID ?: @"",
                (long)task.state,
                task.title ?: @"",
                task.projectName ?: @"",
                task.startedAt.timeIntervalSince1970,
                task.completedAt.timeIntervalSince1970]];
        }
    }
    return [parts componentsJoinedByString:@"|"];
}

@end

@interface CQTaskMonitor ()
@property(nonatomic, strong) CQTaskSnapshot *snapshot;
@property(nonatomic, strong, nullable) NSTimer *timer;
@property(nonatomic) dispatch_queue_t queryQueue;
@property(nonatomic) BOOL queryInFlight;
@property(nonatomic, copy) NSString *lastDeliveredSignature;
@end

@implementation CQTaskMonitor

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _snapshot = [CQTaskSnapshot emptySnapshot];
    _queryQueue = dispatch_queue_create("com.muyang.codexquota.tasks", DISPATCH_QUEUE_SERIAL);
    _lastDeliveredSignature = @"";
    return self;
}

- (void)start {
    NSAssert(NSThread.isMainThread, @"CQTaskMonitor must be started on the main thread");
    if (self.timer) return;
    [self ensureCompletionBaseline];
    [self refreshNow];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                 target:self
                                               selector:@selector(timerFired:)
                                               userInfo:nil
                                                repeats:YES];
    self.timer.tolerance = 0.15;
}

- (void)stop {
    [self.timer invalidate];
    self.timer = nil;
}

- (void)timerFired:(NSTimer *)timer {
    (void)timer;
    [self refreshNow];
}

- (void)ensureCompletionBaseline {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:CQTaskMonitorBaselineKey]) return;
    [defaults setDouble:NSDate.date.timeIntervalSince1970 forKey:CQTaskMonitorBaselineKey];
}

- (void)refreshNow {
    NSAssert(NSThread.isMainThread, @"CQTaskMonitor refresh must be requested on the main thread");
    if (self.queryInFlight) return;
    self.queryInFlight = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.queryQueue, ^{
        CQTaskSnapshot *snapshot = [weakSelf loadSnapshot];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self) return;
            self.queryInFlight = NO;
            NSString *signature = snapshot.contentSignature;
            self.snapshot = snapshot;
            if (![signature isEqualToString:self.lastDeliveredSignature]) {
                self.lastDeliveredSignature = signature;
                if (self.snapshotDidUpdate) self.snapshotDidUpdate(snapshot);
            }
        });
    });
}

- (void)markTaskViewed:(CQCodexTask *)task {
    if (task.state != CQTaskStateCompletedUnread || task.turnID.length == 0) return;
    NSMutableDictionary<NSString *, NSNumber *> *viewed = [self viewedTurnsPrunedAtDate:NSDate.date];
    viewed[task.turnID] = @((task.completedAt ?: NSDate.date).timeIntervalSince1970);
    [NSUserDefaults.standardUserDefaults setObject:viewed forKey:CQTaskMonitorViewedTurnsKey];
    [self refreshNow];
}

- (void)markAllCompletedViewed {
    NSMutableDictionary<NSString *, NSNumber *> *viewed = [self viewedTurnsPrunedAtDate:NSDate.date];
    for (CQCodexTask *task in self.snapshot.unreadCompletedTasks) {
        if (task.turnID.length > 0) viewed[task.turnID] = @((task.completedAt ?: NSDate.date).timeIntervalSince1970);
    }
    [NSUserDefaults.standardUserDefaults setObject:viewed forKey:CQTaskMonitorViewedTurnsKey];
    [self refreshNow];
}

- (NSMutableDictionary<NSString *, NSNumber *> *)viewedTurnsPrunedAtDate:(NSDate *)date {
    NSDictionary *stored = [NSUserDefaults.standardUserDefaults dictionaryForKey:CQTaskMonitorViewedTurnsKey];
    NSMutableDictionary<NSString *, NSNumber *> *viewed = [NSMutableDictionary dictionary];
    NSTimeInterval cutoff = date.timeIntervalSince1970 - CQTaskRetentionInterval;
    [stored enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSNumber *timestamp, BOOL *stop) {
        (void)stop;
        if ([key isKindOfClass:NSString.class]
            && [timestamp isKindOfClass:NSNumber.class]
            && timestamp.doubleValue >= cutoff) {
            viewed[key] = timestamp;
        }
    }];
    if (![stored isEqualToDictionary:viewed]) {
        [NSUserDefaults.standardUserDefaults setObject:viewed forKey:CQTaskMonitorViewedTurnsKey];
    }
    return viewed;
}

- (nullable NSString *)freshestDatabaseNamedLike:(NSString *)prefix {
    NSString *codexDirectory = [NSHomeDirectory() stringByAppendingPathComponent:@".codex"];
    NSArray<NSString *> *directories = @[
        codexDirectory,
        [codexDirectory stringByAppendingPathComponent:@"sqlite"]
    ];
    NSString *bestPath = nil;
    NSDate *bestDate = nil;
    NSFileManager *fileManager = NSFileManager.defaultManager;
    for (NSString *directory in directories) {
        NSArray<NSString *> *entries = [fileManager contentsOfDirectoryAtPath:directory error:nil];
        for (NSString *entry in entries) {
            if (![entry hasPrefix:prefix] || ![entry.pathExtension isEqualToString:@"sqlite"]) continue;
            NSString *path = [directory stringByAppendingPathComponent:entry];
            NSDictionary<NSFileAttributeKey, id> *attributes = [fileManager attributesOfItemAtPath:path error:nil];
            NSDate *date = attributes[NSFileModificationDate] ?: NSDate.distantPast;
            if (!bestPath || [date compare:bestDate] == NSOrderedDescending) {
                bestPath = path;
                bestDate = date;
            }
        }
    }
    return bestPath;
}

- (NSDictionary<NSString *, NSDictionary *> *)loadThreadMetadataFromPath:(NSString *)path {
    sqlite3 *database = NULL;
    if (sqlite3_open_v2(path.fileSystemRepresentation, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, NULL) != SQLITE_OK) {
        if (database) sqlite3_close(database);
        return @{};
    }
    sqlite3_busy_timeout(database, 250);
    NSString *sql = @"SELECT id, COALESCE(NULLIF(name, ''), NULLIF(title, ''), NULLIF(preview, ''), '未命名任务'), cwd "
        "FROM threads WHERE archived = 0 ORDER BY updated_at DESC LIMIT 500";
    sqlite3_stmt *statement = NULL;
    NSMutableDictionary<NSString *, NSDictionary *> *metadata = [NSMutableDictionary dictionary];
    if (sqlite3_prepare_v2(database, sql.UTF8String, -1, &statement, NULL) == SQLITE_OK) {
        while (sqlite3_step(statement) == SQLITE_ROW) {
            NSString *threadID = [self stringFromColumn:statement index:0];
            if (threadID.length == 0) continue;
            NSString *title = [self stringFromColumn:statement index:1] ?: @"未命名任务";
            NSString *cwd = [self stringFromColumn:statement index:2] ?: @"";
            metadata[threadID] = @{ @"title": title, @"cwd": cwd };
        }
    }
    if (statement) sqlite3_finalize(statement);
    sqlite3_close(database);
    return metadata;
}

- (CQTaskSnapshot *)loadSnapshot {
    NSString *historyPath = [self freshestDatabaseNamedLike:@"thread_history_"];
    NSString *statePath = [self freshestDatabaseNamedLike:@"state_"];
    if (historyPath.length == 0 || statePath.length == 0) return [CQTaskSnapshot emptySnapshot];

    NSDictionary<NSString *, NSDictionary *> *metadata = [self loadThreadMetadataFromPath:statePath];
    if (metadata.count == 0) return [CQTaskSnapshot emptySnapshot];
    NSMutableDictionary<NSString *, NSNumber *> *viewed = [self viewedTurnsPrunedAtDate:NSDate.date];
    NSTimeInterval baseline = [NSUserDefaults.standardUserDefaults doubleForKey:CQTaskMonitorBaselineKey];
    NSTimeInterval cutoff = MAX(baseline, NSDate.date.timeIntervalSince1970 - CQTaskRetentionInterval);

    sqlite3 *database = NULL;
    if (sqlite3_open_v2(historyPath.fileSystemRepresentation, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, NULL) != SQLITE_OK) {
        if (database) sqlite3_close(database);
        return [CQTaskSnapshot emptySnapshot];
    }
    sqlite3_busy_timeout(database, 250);
    NSString *sql = @"SELECT turns.thread_id, turns.turn_id, turns.status, turns.started_at, turns.completed_at "
        "FROM thread_turns AS turns INNER JOIN ("
        "SELECT thread_id, MAX(rollout_ordinal) AS latest_ordinal FROM thread_turns GROUP BY thread_id"
        ") AS latest ON latest.thread_id = turns.thread_id AND latest.latest_ordinal = turns.rollout_ordinal "
        "WHERE turns.status = 'inProgress' OR (turns.status = 'completed' AND turns.completed_at >= ?) "
        "ORDER BY COALESCE(turns.completed_at, turns.started_at) DESC LIMIT 200";
    sqlite3_stmt *statement = NULL;
    NSMutableArray<CQCodexTask *> *running = [NSMutableArray array];
    NSMutableArray<CQCodexTask *> *completed = [NSMutableArray array];
    if (sqlite3_prepare_v2(database, sql.UTF8String, -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, (sqlite3_int64)floor(cutoff));
        while (sqlite3_step(statement) == SQLITE_ROW) {
            NSString *threadID = [self stringFromColumn:statement index:0];
            NSString *turnID = [self stringFromColumn:statement index:1];
            NSString *status = [self stringFromColumn:statement index:2];
            NSDictionary *thread = metadata[threadID];
            if (!thread || turnID.length == 0) continue;
            BOOL isCompleted = [status isEqualToString:@"completed"];
            if (isCompleted && viewed[turnID]) continue;
            NSTimeInterval startedAt = sqlite3_column_type(statement, 3) == SQLITE_NULL
                ? NSDate.date.timeIntervalSince1970 : sqlite3_column_int64(statement, 3);
            NSTimeInterval completedAt = sqlite3_column_type(statement, 4) == SQLITE_NULL
                ? 0 : sqlite3_column_int64(statement, 4);
            CQCodexTask *task = [CQCodexTask new];
            task.threadID = threadID;
            task.turnID = turnID;
            task.title = thread[@"title"];
            task.workingDirectory = thread[@"cwd"];
            task.projectName = [self projectNameForWorkingDirectory:task.workingDirectory];
            task.startedAt = [NSDate dateWithTimeIntervalSince1970:startedAt];
            task.completedAt = completedAt > 0 ? [NSDate dateWithTimeIntervalSince1970:completedAt] : nil;
            task.state = isCompleted ? CQTaskStateCompletedUnread : CQTaskStateRunning;
            [(isCompleted ? completed : running) addObject:task];
        }
    }
    if (statement) sqlite3_finalize(statement);
    sqlite3_close(database);

    CQTaskSnapshot *snapshot = [CQTaskSnapshot emptySnapshot];
    // Waiting-for-approval is intentionally left empty until Codex exposes an exact cross-process signal.
    // An in-progress persisted turn is not enough evidence to label a task as awaiting approval.
    snapshot.waitingForApprovalTasks = @[];
    snapshot.runningTasks = running;
    snapshot.unreadCompletedTasks = completed;
    return snapshot;
}

- (nullable NSString *)stringFromColumn:(sqlite3_stmt *)statement index:(int)index {
    const unsigned char *text = sqlite3_column_text(statement, index);
    return text ? [NSString stringWithUTF8String:(const char *)text] : nil;
}

- (NSString *)projectNameForWorkingDirectory:(NSString *)workingDirectory {
    if (workingDirectory.length == 0) return @"本机任务";
    NSString *name = workingDirectory.stringByStandardizingPath.lastPathComponent;
    return name.length > 0 ? name : @"本机任务";
}

@end
