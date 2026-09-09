#import "CQApprovalMonitor.h"
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <fcntl.h>
#import <unistd.h>
#import <os/log.h>

static NSUInteger const CQApprovalMaximumFrameBytes = 32 * 1024 * 1024;
static NSTimeInterval const CQApprovalReconnectInterval = 5;
static NSTimeInterval const CQApprovalResyncInterval = 30;

static os_log_t CQApprovalLogger(void) {
    static os_log_t logger;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ logger = os_log_create("com.muyang.codexquota", "approvals"); });
    return logger;
}

static NSDictionary *CQApprovalDictionary(id value) { return [value isKindOfClass:NSDictionary.class] ? value : @{}; }
static NSArray *CQApprovalArray(id value) { return [value isKindOfClass:NSArray.class] ? value : @[]; }
static NSString *CQApprovalString(id value) { return [value isKindOfClass:NSString.class] ? value : @""; }

static NSMutableDictionary *CQApprovalRequest(id value) {
    NSDictionary *request = CQApprovalDictionary(value);
    return [@{@"method": CQApprovalString(request[@"method"]), @"params": [@{@"turnId": CQApprovalString(CQApprovalDictionary(request[@"params"])[@"turnId"])} mutableCopy]} mutableCopy];
}

static NSMutableArray *CQApprovalRequests(id value) {
    NSMutableArray *requests = [NSMutableArray array];
    for (id request in CQApprovalArray(value)) [requests addObject:CQApprovalRequest(request)];
    return requests;
}

static NSMutableDictionary *CQApprovalStatus(id value) {
    NSDictionary *status = CQApprovalDictionary(value);
    NSMutableArray *flags = [NSMutableArray array];
    for (id flag in CQApprovalArray(status[@"activeFlags"])) [flags addObject:CQApprovalString(flag)];
    return [@{@"type": CQApprovalString(status[@"type"]), @"activeFlags": flags} mutableCopy];
}

static NSMutableDictionary *CQApprovalProjection(id value) {
    NSDictionary *state = CQApprovalDictionary(value);
    return [@{@"requests": CQApprovalRequests(state[@"requests"]), @"threadRuntimeStatus": CQApprovalStatus(state[@"threadRuntimeStatus"])} mutableCopy];
}

// Keep only approval metadata. Command arguments, message bodies and file changes are discarded.
static BOOL CQApplyApprovalPatch(NSMutableDictionary *state, NSDictionary *patch) {
    NSArray *path = CQApprovalArray(patch[@"path"]);
    NSString *operation = CQApprovalString(patch[@"op"]);
    if (![@[@"add", @"replace", @"remove"] containsObject:operation]) return NO;
    BOOL remove = [operation isEqualToString:@"remove"];
    id value = patch[@"value"];
    if (path.count == 0) {
        [state setDictionary:CQApprovalProjection(remove ? nil : value)];
        return YES;
    }
    NSString *root = CQApprovalString(path.firstObject);
    if (![@[@"requests", @"threadRuntimeStatus"] containsObject:root]) return YES;
    if (path.count == 1) {
        state[root] = [root isEqualToString:@"requests"] ? CQApprovalRequests(remove ? nil : value) : CQApprovalStatus(remove ? nil : value);
        return YES;
    }
    if ([root isEqualToString:@"requests"]) {
        if (path.count == 2) value = CQApprovalRequest(value);
        else if (path.count == 3 && [path[2] isEqual:@"params"]) value = [@{@"turnId": CQApprovalString(CQApprovalDictionary(value)[@"turnId"])} mutableCopy];
        else if ((path.count == 3 && [path[2] isEqual:@"method"]) || (path.count == 4 && [path[2] isEqual:@"params"] && [path[3] isEqual:@"turnId"])) value = CQApprovalString(value);
        else return YES;
    } else {
        if (path.count == 2 && [path[1] isEqual:@"type"]) value = CQApprovalString(value);
        else if (path.count == 2 && [path[1] isEqual:@"activeFlags"]) value = CQApprovalStatus(@{@"activeFlags": value ?: @[]})[@"activeFlags"];
        else if (path.count == 3 && [path[1] isEqual:@"activeFlags"]) value = CQApprovalString(value);
        else return YES;
    }
    id parent = state;
    for (NSUInteger index = 0; index + 1 < path.count; index++) {
        id key = path[index];
        if ([parent isKindOfClass:NSMutableDictionary.class] && [key isKindOfClass:NSString.class]) parent = parent[key];
        else if ([parent isKindOfClass:NSMutableArray.class] && [key isKindOfClass:NSNumber.class] && [key unsignedIntegerValue] < [parent count]) parent = parent[[key unsignedIntegerValue]];
        else return NO;
    }
    id key = path.lastObject;
    if ([parent isKindOfClass:NSMutableDictionary.class] && [key isKindOfClass:NSString.class]) {
        if (remove) [parent removeObjectForKey:key];
        else parent[key] = value;
        return YES;
    }
    if (![parent isKindOfClass:NSMutableArray.class] || ![key isKindOfClass:NSNumber.class]) return NO;
    NSUInteger index = [key unsignedIntegerValue];
    if ([operation isEqualToString:@"add"] && index <= [parent count]) [parent insertObject:value atIndex:index];
    else if (index >= [parent count]) return NO;
    else if (remove) [parent removeObjectAtIndex:index];
    else parent[index] = value;
    return YES;
}

@interface CQApprovalMonitor ()
@property(nonatomic) int socketFD;
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic, strong, nullable) dispatch_source_t readSource;
@property(nonatomic, strong) NSMutableData *inputBuffer;
@property(nonatomic, strong) NSMutableData *outputBuffer;
@property(nonatomic, copy, nullable) NSString *clientID;
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *turnsByThread;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary *> *states;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *lastSubscriptionAt;
@property(nonatomic) NSTimeInterval nextConnectAt;
@property(nonatomic, copy) NSSet<NSString *> *lastWaitingTurnIDs;
@end

@implementation CQApprovalMonitor

- (instancetype)initWithQueue:(dispatch_queue_t)queue {
    self = [super init];
    if (!self) return nil;
    _socketFD = -1;
    _queue = queue;
    _inputBuffer = [NSMutableData data];
    _outputBuffer = [NSMutableData data];
    _turnsByThread = @{};
    _states = [NSMutableDictionary dictionary];
    _lastSubscriptionAt = [NSMutableDictionary dictionary];
    _lastWaitingTurnIDs = [NSSet set];
    return self;
}

- (void)dealloc {
    if (_readSource) dispatch_source_cancel(_readSource);
    else if (_socketFD >= 0) close(_socketFD);
}

- (void)stop {
    if (self.readSource) {
        dispatch_source_cancel(self.readSource);
        self.readSource = nil;
    } else if (self.socketFD >= 0) close(self.socketFD);
    self.socketFD = -1;
    self.clientID = nil;
    [self.inputBuffer setLength:0];
    [self.outputBuffer setLength:0];
    [self.states removeAllObjects];
    [self.lastSubscriptionAt removeAllObjects];
    self.nextConnectAt = NSProcessInfo.processInfo.systemUptime + CQApprovalReconnectInterval;
}

- (void)connectIfNeeded {
    if (self.socketFD >= 0 || NSProcessInfo.processInfo.systemUptime < self.nextConnectAt) return;
    self.nextConnectAt = NSProcessInfo.processInfo.systemUptime + CQApprovalReconnectInterval;
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@".codex/ipc/ipc.sock"];
    struct stat attributes;
    if (lstat(path.fileSystemRepresentation, &attributes) != 0 || !S_ISSOCK(attributes.st_mode) || attributes.st_uid != getuid()) return;
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    address.sun_len = sizeof(address);
    if (strlen(path.fileSystemRepresentation) >= sizeof(address.sun_path)) return;
    strlcpy(address.sun_path, path.fileSystemRepresentation, sizeof(address.sun_path));
    int descriptor = socket(AF_UNIX, SOCK_STREAM, 0);
    if (descriptor < 0) return;
    int enabled = 1;
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
    fcntl(descriptor, F_SETFD, FD_CLOEXEC);
    fcntl(descriptor, F_SETFL, O_NONBLOCK);
    if (connect(descriptor, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(descriptor);
        return;
    }
    self.socketFD = descriptor;
    // Drain socket frames as they arrive; polling alone can take minutes to read a large snapshot.
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)descriptor, 0, self.queue);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(source, ^{ [weakSelf pumpSocket]; });
    dispatch_source_set_cancel_handler(source, ^{ close(descriptor); });
    self.readSource = source;
    dispatch_resume(source);
    [self enqueue:@{@"type": @"request", @"requestId": NSUUID.UUID.UUIDString, @"sourceClientId": @"initializing-client", @"version": @0,
        @"method": @"initialize", @"params": @{@"clientType": @"codex-quota"}}];
}

- (void)enqueue:(NSDictionary *)message {
    NSData *data = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
    if (!data || self.outputBuffer.length + data.length + 4 > 1024 * 1024) {
        [self stop];
        return;
    }
    uint32_t length = CFSwapInt32HostToLittle((uint32_t)data.length);
    [self.outputBuffer appendBytes:&length length:sizeof(length)];
    [self.outputBuffer appendData:data];
}

- (void)followThread:(NSString *)threadID following:(BOOL)following {
    if (!self.clientID) return;
    [self enqueue:@{@"type": @"broadcast", @"method": @"thread-stream-following-changed", @"sourceClientId": self.clientID, @"version": @1,
        @"params": @{@"conversationId": threadID, @"hostId": @"local", @"following": @(following)}}];
    if (following) self.lastSubscriptionAt[threadID] = @(NSProcessInfo.processInfo.systemUptime);
    else [self.lastSubscriptionAt removeObjectForKey:threadID];
}

- (void)pumpSocket {
    while (self.socketFD >= 0 && self.outputBuffer.length > 0) {
        ssize_t count = send(self.socketFD, self.outputBuffer.bytes, self.outputBuffer.length, 0);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
        if (count <= 0) { [self stop]; return; }
        [self.outputBuffer replaceBytesInRange:NSMakeRange(0, (NSUInteger)count) withBytes:NULL length:0];
    }
    uint8_t buffer[65536];
    NSUInteger received = 0;
    while (self.socketFD >= 0 && received < CQApprovalMaximumFrameBytes) {
        ssize_t count = recv(self.socketFD, buffer, sizeof(buffer), 0);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
        if (count <= 0) { [self stop]; return; }
        received += (NSUInteger)count;
        [self.inputBuffer appendBytes:buffer length:(NSUInteger)count];
        while (self.inputBuffer.length >= 4) {
            uint32_t length;
            memcpy(&length, self.inputBuffer.bytes, sizeof(length));
            length = CFSwapInt32LittleToHost(length);
            if (length == 0 || length > CQApprovalMaximumFrameBytes) { [self stop]; return; }
            if (self.inputBuffer.length < length + 4) break;
            @autoreleasepool {
                NSData *frame = [self.inputBuffer subdataWithRange:NSMakeRange(4, length)];
                [self.inputBuffer replaceBytesInRange:NSMakeRange(0, length + 4) withBytes:NULL length:0];
                NSDictionary *message = CQApprovalDictionary([NSJSONSerialization JSONObjectWithData:frame options:0 error:nil]);
                [self handleMessage:message];
            }
        }
    }
}

- (void)handleMessage:(NSDictionary *)message {
    NSString *type = CQApprovalString(message[@"type"]);
    NSString *method = CQApprovalString(message[@"method"]);
    if ([type isEqualToString:@"client-discovery-request"]) {
        [self enqueue:@{@"type": @"client-discovery-response", @"requestId": CQApprovalString(message[@"requestId"]), @"response": @{@"canHandle": @NO}}];
        return;
    }
    if ([type isEqualToString:@"response"] && [method isEqualToString:@"initialize"] && [message[@"resultType"] isEqual:@"success"]) {
        NSString *clientID = CQApprovalString(CQApprovalDictionary(message[@"result"])[@"clientId"]);
        if (clientID.length > 0) {
            self.clientID = clientID;
            os_log_info(CQApprovalLogger(), "Connected to Codex approval state stream");
        }
        return;
    }
    if (![type isEqualToString:@"broadcast"]) return;
    NSDictionary *params = CQApprovalDictionary(message[@"params"]);
    NSString *source = CQApprovalString(message[@"sourceClientId"]);
    if ([method isEqualToString:@"client-status-changed"] && [params[@"status"] isEqual:@"disconnected"]) {
        for (NSString *threadID in self.states.allKeys) {
            if (![self.states[threadID][@"owner"] isEqual:source]) continue;
            [self.states removeObjectForKey:threadID];
            [self.lastSubscriptionAt removeObjectForKey:threadID];
        }
        return;
    }
    if (![method isEqualToString:@"thread-stream-state-changed"] || ![params[@"hostId"] isEqual:@"local"]) return;
    NSString *threadID = CQApprovalString(params[@"conversationId"]);
    if (!self.turnsByThread[threadID]) return;
    if (![message[@"version"] isEqual:@11]) {
        [self.states removeObjectForKey:threadID];
        return;
    }
    NSDictionary *change = CQApprovalDictionary(params[@"change"]);
    NSNumber *revision = [change[@"revision"] isKindOfClass:NSNumber.class] ? change[@"revision"] : nil;
    if (!revision) return;
    if ([change[@"type"] isEqual:@"snapshot"]) {
        if (!self.states[threadID]) os_log_info(CQApprovalLogger(), "Received Codex task approval snapshot");
        self.states[threadID] = [@{@"projection": CQApprovalProjection(change[@"conversationState"]), @"revision": revision, @"owner": source} mutableCopy];
        return;
    }
    if (![change[@"type"] isEqual:@"patches"]) return;
    NSMutableDictionary *state = self.states[threadID];
    BOOL valid = state && [state[@"owner"] isEqual:source] && [state[@"revision"] isEqual:change[@"baseRevision"]] && [change[@"patches"] isKindOfClass:NSArray.class];
    if (valid) {
        for (id patch in change[@"patches"]) {
            if (!CQApplyApprovalPatch(state[@"projection"], CQApprovalDictionary(patch))) { valid = NO; break; }
        }
    }
    if (valid) state[@"revision"] = revision;
    else {
        [self.states removeObjectForKey:threadID];
        [self followThread:threadID following:YES];
    }
}

- (BOOL)isTaskConfirmedIdle:(CQCodexTask *)task {
    if (![self.turnsByThread[task.threadID] isEqual:task.turnID]) return NO;
    NSDictionary *projection = self.states[task.threadID][@"projection"];
    NSDictionary *status = CQApprovalDictionary(projection[@"threadRuntimeStatus"]);
    return [status[@"type"] isEqual:@"idle"] && CQApprovalArray(projection[@"requests"]).count == 0;
}

- (NSSet<NSString *> *)waitingTurnIDsForTasks:(NSArray<CQCodexTask *> *)tasks {
    NSMutableDictionary *turns = [NSMutableDictionary dictionary];
    for (CQCodexTask *task in tasks) {
        if (task.threadID.length > 0 && task.turnID.length > 0) turns[task.threadID] = task.turnID;
    }
    for (NSString *threadID in self.turnsByThread) {
        if ([self.turnsByThread[threadID] isEqual:turns[threadID]]) continue;
        [self followThread:threadID following:NO];
        [self.states removeObjectForKey:threadID];
    }
    self.turnsByThread = turns;
    [self connectIfNeeded];
    [self pumpSocket];
    if (self.clientID) {
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        for (NSString *threadID in turns) {
            if (!self.lastSubscriptionAt[threadID] || now - self.lastSubscriptionAt[threadID].doubleValue >= CQApprovalResyncInterval) [self followThread:threadID following:YES];
        }
        [self pumpSocket];
    }
    NSMutableSet *waiting = [NSMutableSet set];
    NSSet *methods = [NSSet setWithArray:@[@"item/commandExecution/requestApproval", @"item/fileChange/requestApproval", @"item/permissions/requestApproval", @"execCommandApproval", @"applyPatchApproval"]];
    for (NSString *threadID in turns) {
        NSDictionary *projection = self.states[threadID][@"projection"];
        NSDictionary *status = projection[@"threadRuntimeStatus"];
        BOOL pending = [status[@"type"] isEqual:@"active"] && [CQApprovalArray(status[@"activeFlags"]) containsObject:@"waitingOnApproval"];
        for (NSDictionary *request in CQApprovalArray(projection[@"requests"])) {
            NSString *turnID = CQApprovalString(CQApprovalDictionary(request[@"params"])[@"turnId"]);
            if ([methods containsObject:request[@"method"]] && [turnID isEqual:turns[threadID]]) pending = YES;
        }
        if (pending) [waiting addObject:turns[threadID]];
    }
    if (![waiting isEqualToSet:self.lastWaitingTurnIDs]) {
        os_log_info(CQApprovalLogger(), "Pending approval task count changed: %lu", (unsigned long)waiting.count);
        self.lastWaitingTurnIDs = waiting.copy;
    }
    return waiting;
}

@end
