#import "CQCodexClient.h"
#import <os/log.h>

static NSString * const CQClientErrorDomain = @"com.muyang.codexquota.client";

static NSNumber *CQClientNumber(id value) {
    if ([value isKindOfClass:NSNumber.class]) return value;
    if ([value isKindOfClass:NSString.class]) return @([value integerValue]);
    return nil;
}

static NSString *CQClientString(id value) {
    return [value isKindOfClass:NSString.class] ? value : nil;
}

@interface CQCodexClient ()
@property(nonatomic, strong, nullable) NSTask *task;
@property(nonatomic, strong, nullable) NSFileHandle *input;
@property(nonatomic, strong, nullable) NSFileHandle *output;
@property(nonatomic, strong) NSMutableData *buffer;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, void (^)(id, NSError *)> *pending;
@property(nonatomic) NSInteger nextRequestID;
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic) BOOL intentionallyStopping;
- (void)requestMethod:(NSString *)method
                params:(NSDictionary *)params
               timeout:(NSTimeInterval)timeout
            completion:(void (^)(id _Nullable result, NSError * _Nullable error))completion;
@end

@implementation CQCodexClient

- (instancetype)init {
    self = [super init];
    if (self) {
        _buffer = [NSMutableData data];
        _pending = [NSMutableDictionary dictionary];
        _nextRequestID = 1;
        _queue = dispatch_queue_create("com.muyang.codexquota.appserver", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)isRunning {
    return self.task.isRunning;
}

- (void)startAtURL:(NSURL *)url completion:(CQClientReadyBlock)completion {
    [self stop];
    self.intentionallyStopping = NO;
    self.buffer = [NSMutableData data];
    self.pending = [NSMutableDictionary dictionary];

    NSTask *task = [NSTask new];
    task.executableURL = url;
    task.arguments = @[@"app-server", @"--stdio"];
    NSPipe *stdinPipe = [NSPipe pipe];
    NSPipe *stdoutPipe = [NSPipe pipe];
    NSPipe *stderrPipe = [NSPipe pipe];
    task.standardInput = stdinPipe;
    task.standardOutput = stdoutPipe;
    task.standardError = stderrPipe;
    self.input = stdinPipe.fileHandleForWriting;
    self.output = stdoutPipe.fileHandleForReading;
    self.task = task;

    __weak typeof(self) weakSelf = self;
    self.output.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (data.length == 0) return;
        dispatch_async(weakSelf.queue, ^{
            [weakSelf consumeData:data];
        });
    };
    stderrPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        (void)handle.availableData;
    };
    task.terminationHandler = ^(NSTask *terminatedTask) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self || self.intentionallyStopping) return;
            NSError *error = [NSError errorWithDomain:CQClientErrorDomain
                                                  code:terminatedTask.terminationStatus
                                              userInfo:@{NSLocalizedDescriptionKey: @"Codex App Server 已停止"}];
            if (self.processDidExit) self.processDidExit(error);
        });
    };

    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        completion(launchError);
        return;
    }

    NSDictionary *params = @{
        @"clientInfo": @{
            @"name": @"codex-quota",
            @"title": @"Codex Quota",
            @"version": @"0.2.6"
        },
        @"capabilities": @{}
    };
    [self requestMethod:@"initialize" params:params completion:^(id result, NSError *error) {
        (void)result;
        if (error) {
            completion(error);
            return;
        }
        [self sendObject:@{@"method": @"initialized", @"params": @{}} error:nil];
        completion(nil);
    }];
}

- (void)stop {
    self.intentionallyStopping = YES;
    self.output.readabilityHandler = nil;
    if (self.task.isRunning) [self.task terminate];
    self.task = nil;
    self.input = nil;
    self.output = nil;
    dispatch_async(self.queue, ^{
        NSError *error = [NSError errorWithDomain:CQClientErrorDomain
                                              code:-1
                                          userInfo:@{NSLocalizedDescriptionKey: @"连接已关闭"}];
        NSArray<void (^)(id, NSError *)> *callbacks = self.pending.allValues.copy;
        [self.pending removeAllObjects];
        dispatch_async(dispatch_get_main_queue(), ^{
            for (void (^callback)(id, NSError *) in callbacks) callback(nil, error);
        });
    });
}

- (void)readAccount:(void (^)(NSDictionary *, NSError *))completion {
    [self requestMethod:@"account/read" params:@{@"refreshToken": @NO} completion:^(id result, NSError *error) {
        completion([result isKindOfClass:NSDictionary.class] ? result : nil, error);
    }];
}

- (void)refresh:(CQSnapshotBlock)completion {
    [self requestMethod:@"account/rateLimits/read" params:@{} completion:^(id result, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        NSDictionary *dictionary = [result isKindOfClass:NSDictionary.class] ? result : @{};
        completion([CQQuotaSnapshot snapshotFromRateLimitsResult:dictionary], nil);
    }];
}

- (void)startChatGPTLogin:(void (^)(NSURL *, NSError *))completion {
    [self requestMethod:@"account/login/start" params:@{@"type": @"chatgpt"} completion:^(id result, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        NSString *urlString = [self findHTTPURLInObject:result];
        NSURL *url = urlString ? [NSURL URLWithString:urlString] : nil;
        if (!url) {
            NSError *missing = [NSError errorWithDomain:CQClientErrorDomain
                                                   code:-2
                                               userInfo:@{NSLocalizedDescriptionKey: @"Codex 未返回登录地址"}];
            completion(nil, missing);
            return;
        }
        completion(url, nil);
    }];
}

- (void)listSkillsAtWorkingDirectory:(NSString *)workingDirectory
                         forceReload:(BOOL)forceReload
                          completion:(CQClientDictionaryBlock)completion {
    NSDictionary *params = @{
        @"cwds": @[workingDirectory.length > 0 ? workingDirectory : NSHomeDirectory()],
        @"forceReload": @(forceReload)
    };
    [self requestMethod:@"skills/list" params:params timeout:20 completion:^(id result, NSError *error) {
        completion([result isKindOfClass:NSDictionary.class] ? result : nil, error);
    }];
}

- (void)listPluginsAtWorkingDirectory:(NSString *)workingDirectory
                          forceRefetch:(BOOL)forceRefetch
                            completion:(CQClientDictionaryBlock)completion {
    NSDictionary *params = @{
        @"cwds": @[workingDirectory.length > 0 ? workingDirectory : NSHomeDirectory()],
        @"forceRefetch": @(forceRefetch)
    };
    [self requestMethod:@"plugin/list" params:params timeout:90 completion:^(id result, NSError *error) {
        completion([result isKindOfClass:NSDictionary.class] ? result : nil, error);
    }];
}

- (void)installPluginNamed:(NSString *)pluginName
           marketplacePath:(NSString *)marketplacePath
      remoteMarketplaceName:(NSString *)remoteMarketplaceName
                 completion:(CQClientDictionaryBlock)completion {
    NSMutableDictionary *params = [NSMutableDictionary dictionaryWithObject:pluginName forKey:@"pluginName"];
    if (marketplacePath.length > 0) params[@"marketplacePath"] = marketplacePath;
    if (remoteMarketplaceName.length > 0) params[@"remoteMarketplaceName"] = remoteMarketplaceName;
    [self requestMethod:@"plugin/install" params:params timeout:120 completion:^(id result, NSError *error) {
        completion([result isKindOfClass:NSDictionary.class] ? result : nil, error);
    }];
}

- (void)requestMethod:(NSString *)method
                params:(NSDictionary *)params
            completion:(void (^)(id _Nullable, NSError * _Nullable))completion {
    [self requestMethod:method params:params timeout:12 completion:completion];
}

- (void)requestMethod:(NSString *)method
                params:(NSDictionary *)params
               timeout:(NSTimeInterval)timeout
            completion:(void (^)(id _Nullable, NSError * _Nullable))completion {
    dispatch_async(self.queue, ^{
        NSNumber *requestID = @(self.nextRequestID++);
        self.pending[requestID] = [completion copy];
        NSError *error = nil;
        [self sendObject:@{@"id": requestID, @"method": method, @"params": params ?: @{}} error:&error];
        if (error) {
            [self.pending removeObjectForKey:requestID];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); });
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), self.queue, ^{
            void (^callback)(id, NSError *) = self.pending[requestID];
            if (!callback) return;
            [self.pending removeObjectForKey:requestID];
            NSError *timeout = [NSError errorWithDomain:CQClientErrorDomain
                                                   code:-4
                                               userInfo:@{NSLocalizedDescriptionKey: @"Codex 请求超时"}];
            dispatch_async(dispatch_get_main_queue(), ^{ callback(nil, timeout); });
        });
    });
}

- (void)sendObject:(NSDictionary *)object error:(NSError **)error {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:error];
    if (!data) return;
    NSMutableData *line = [data mutableCopy];
    [line appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
    @try {
        [self.input writeData:line];
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:CQClientErrorDomain
                                         code:-3
                                     userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"无法写入 Codex"}];
        }
    }
}

- (void)consumeData:(NSData *)data {
    [self.buffer appendData:data];
    const uint8_t *bytes = self.buffer.bytes;
    NSUInteger start = 0;
    for (NSUInteger i = 0; i < self.buffer.length; i++) {
        if (bytes[i] != '\n') continue;
        NSData *line = [self.buffer subdataWithRange:NSMakeRange(start, i - start)];
        start = i + 1;
        if (line.length > 0) [self consumeLine:line];
    }
    if (start > 0) {
        [self.buffer replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
    }
}

- (void)consumeLine:(NSData *)line {
    NSError *jsonError = nil;
    id object = [NSJSONSerialization JSONObjectWithData:line options:0 error:&jsonError];
    if (![object isKindOfClass:NSDictionary.class]) return;
    NSDictionary *message = object;
    NSNumber *requestID = [message[@"id"] isKindOfClass:NSNumber.class] ? message[@"id"] : nil;
    if (requestID) {
        void (^callback)(id, NSError *) = self.pending[requestID];
        if (!callback) return;
        [self.pending removeObjectForKey:requestID];
        id rpcError = message[@"error"];
        NSError *error = nil;
        if ([rpcError isKindOfClass:NSDictionary.class]) {
            NSString *description = CQClientString(rpcError[@"message"]) ?: @"Codex 返回错误";
            error = [NSError errorWithDomain:CQClientErrorDomain
                                        code:[CQClientNumber(rpcError[@"code"]) integerValue]
                                    userInfo:@{NSLocalizedDescriptionKey: description}];
        }
        id result = message[@"result"];
        dispatch_async(dispatch_get_main_queue(), ^{ callback(result, error); });
        return;
    }

    NSString *method = [message[@"method"] isKindOfClass:NSString.class] ? message[@"method"] : nil;
    if ([method isEqualToString:@"account/rateLimits/updated"]) {
        NSDictionary *params = [message[@"params"] isKindOfClass:NSDictionary.class] ? message[@"params"] : @{};
        NSDictionary *payload = params;
        NSDictionary *nested = [params[@"rateLimits"] isKindOfClass:NSDictionary.class] ? params[@"rateLimits"] : nil;
        if (nested[@"rateLimits"] || nested[@"rateLimitsByLimitId"] || nested[@"rateLimitResetCredits"]) {
            payload = nested;
        }
        CQQuotaSnapshot *snapshot = [CQQuotaSnapshot snapshotFromRateLimitsResult:payload];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.snapshotDidUpdate) self.snapshotDidUpdate(snapshot);
        });
    }
}

- (NSString *)findHTTPURLInObject:(id)object {
    if ([object isKindOfClass:NSString.class]) {
        return [object hasPrefix:@"http://"] || [object hasPrefix:@"https://"] ? object : nil;
    }
    if ([object isKindOfClass:NSDictionary.class]) {
        for (id value in [(NSDictionary *)object allValues]) {
            NSString *found = [self findHTTPURLInObject:value];
            if (found) return found;
        }
    }
    if ([object isKindOfClass:NSArray.class]) {
        for (id value in object) {
            NSString *found = [self findHTTPURLInObject:value];
            if (found) return found;
        }
    }
    return nil;
}

@end
