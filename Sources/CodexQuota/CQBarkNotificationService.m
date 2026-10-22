#import "CQBarkNotificationService.h"
#import <Security/Security.h>

static NSString * const CQBarkKeychainService = @"com.muyang.codexquota.bark";
static NSString * const CQBarkEnabledKey = @"BarkNotificationsEnabled";
static NSString * const CQBarkBaselineKey = @"BarkNotificationBaseline";
static NSString * const CQBarkDeliveredKey = @"BarkNotificationDeliveredEvents";
static NSTimeInterval const CQBarkRetentionInterval = 7 * 24 * 60 * 60;

static NSError *CQBarkError(NSString *message) {
    return [NSError errorWithDomain:@"com.muyang.codexquota.bark" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

@interface CQBarkSessionDelegate : NSObject <NSURLSessionTaskDelegate>
@end

@implementation CQBarkSessionDelegate
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    (void)session; (void)task; (void)response; (void)request;
    // A redirect must never forward the device key or task metadata to a different endpoint.
    completionHandler(nil);
}
@end

@interface CQBarkNotificationService ()
@property(nonatomic) BOOL enabled;
@property(nonatomic, copy) NSString *deliveryStatus;
@property(nonatomic) BOOL deliveryFailed;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong, nullable) NSURL *endpointURL;
@property(nonatomic) BOOL endpointLoaded;
@property(nonatomic, strong, nullable) CQTaskSnapshot *latestSnapshot;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *deliveredEvents;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSUUID *> *pendingEvents;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSURLSessionDataTask *> *requests;
@property(nonatomic, strong) NSMutableSet<NSString *> *failedEvents;
@end

@implementation CQBarkNotificationService

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _enabled = [NSUserDefaults.standardUserDefaults boolForKey:CQBarkEnabledKey];
    _deliveryStatus = @"";
    _deliveredEvents = [NSMutableDictionary dictionary];
    NSDictionary *stored = [NSUserDefaults.standardUserDefaults dictionaryForKey:CQBarkDeliveredKey];
    [stored enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        (void)stop;
        if ([key isKindOfClass:NSString.class] && [value isKindOfClass:NSNumber.class]) self.deliveredEvents[key] = value;
    }];
    _pendingEvents = [NSMutableDictionary dictionary];
    _requests = [NSMutableDictionary dictionary];
    _failedEvents = [NSMutableSet set];
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = 15;
    configuration.timeoutIntervalForResource = 20;
    configuration.HTTPShouldSetCookies = NO;
    configuration.URLCache = nil;
    _session = [NSURLSession sessionWithConfiguration:configuration delegate:[CQBarkSessionDelegate new] delegateQueue:nil];
    return self;
}

- (void)dealloc {
    [_session invalidateAndCancel];
}

- (NSDictionary *)keychainQuery {
    return @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword, (__bridge id)kSecAttrService: CQBarkKeychainService,
        (__bridge id)kSecAttrAccount: @"push-endpoint"};
}

- (nullable NSURL *)validatedEndpoint:(NSString *)endpoint error:(NSError **)error {
    NSString *trimmed = [endpoint stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSURLComponents *components = [NSURLComponents componentsWithString:trimmed];
    NSArray *parts = [components.path componentsSeparatedByString:@"/"];
    NSMutableArray *pathParts = [NSMutableArray array];
    for (NSString *part in parts) if (part.length > 0) [pathParts addObject:part];
    BOOL publicServer = [components.host.lowercaseString isEqual:@"api.day.app"];
    BOOL valid = [components.scheme.lowercaseString isEqual:@"https"] && components.host.length > 0 && pathParts.count > 0
        && components.user == nil && components.password == nil && components.query == nil && components.fragment == nil
        && ![pathParts.lastObject isEqual:@"push"] && (!publicServer || pathParts.count == 1)
        && [trimmed rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location == NSNotFound;
    if (!valid || !components.URL) {
        if (error) *error = CQBarkError(@"请输入 Bark App 中以设备 key 结尾的 HTTPS 链接，例如 https://api.day.app/你的key");
        return nil;
    }
    while ([components.path hasSuffix:@"/"]) components.path = [components.path substringToIndex:components.path.length - 1];
    return components.URL;
}

- (nullable NSString *)savedEndpointWithError:(NSError **)error {
    if (self.endpointLoaded) return self.endpointURL.absoluteString;
    NSMutableDictionary *query = [self.keychainQuery mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    NSData *data = result ? CFBridgingRelease(result) : nil;
    if (status == errSecItemNotFound) { self.endpointLoaded = YES; return nil; }
    if (status != errSecSuccess) {
        if (error) *error = CQBarkError(@"无法读取 Bark 链接，请允许访问 macOS 钥匙串后重试");
        return nil;
    }
    NSString *endpoint = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    self.endpointURL = [self validatedEndpoint:endpoint ?: @"" error:error];
    self.endpointLoaded = self.endpointURL != nil;
    return self.endpointURL.absoluteString;
}

- (void)setStatus:(NSString *)status failed:(BOOL)failed {
    if ([self.deliveryStatus isEqualToString:status] && self.deliveryFailed == failed) return;
    self.deliveryStatus = status;
    self.deliveryFailed = failed;
    if (self.statusDidChange) self.statusDidChange();
}

- (void)cancelPendingNotifications {
    [self.pendingEvents removeAllObjects];
    for (NSURLSessionDataTask *request in self.requests.allValues) [request cancel];
    [self.requests removeAllObjects];
    [self.failedEvents removeAllObjects];
}

- (BOOL)saveEndpoint:(NSString *)endpoint enabled:(BOOL)enabled error:(NSError **)error {
    if (!enabled && [endpoint stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length == 0) return [self clearConfigurationWithError:error];
    NSURL *url = [self validatedEndpoint:endpoint error:error];
    if (!url) return NO;
    NSData *data = [url.absoluteString dataUsingEncoding:NSUTF8StringEncoding];
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)self.keychainQuery, (__bridge CFDictionaryRef)@{(__bridge id)kSecValueData: data});
    if (status == errSecItemNotFound) {
        NSMutableDictionary *item = [self.keychainQuery mutableCopy];
        item[(__bridge id)kSecValueData] = data;
        item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
        status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
    }
    if (status != errSecSuccess) {
        if (error) *error = CQBarkError(@"无法保存 Bark 链接，请检查 macOS 钥匙串权限后重试");
        return NO;
    }
    BOOL changed = ![self.endpointURL isEqual:url];
    if (changed || (!self.enabled && enabled)) [NSUserDefaults.standardUserDefaults setDouble:floor(NSDate.date.timeIntervalSince1970) forKey:CQBarkBaselineKey];
    [self cancelPendingNotifications];
    if (changed) [self.deliveredEvents removeAllObjects];
    self.endpointURL = url;
    self.endpointLoaded = YES;
    self.enabled = enabled;
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:CQBarkEnabledKey];
    [NSUserDefaults.standardUserDefaults setObject:self.deliveredEvents forKey:CQBarkDeliveredKey];
    [self setStatus:enabled ? @"已开启，等待新的任务通知" : @"Bark 同步已暂停" failed:NO];
    if (enabled && self.latestSnapshot) [self handleSnapshot:self.latestSnapshot];
    return YES;
}

- (BOOL)clearConfigurationWithError:(NSError **)error {
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)self.keychainQuery);
    if (status != errSecSuccess && status != errSecItemNotFound) {
        if (error) *error = CQBarkError(@"无法移除 Bark 链接，请检查 macOS 钥匙串权限后重试");
        return NO;
    }
    [self cancelPendingNotifications];
    self.enabled = NO;
    self.endpointURL = nil;
    self.endpointLoaded = YES;
    [self.deliveredEvents removeAllObjects];
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:CQBarkEnabledKey];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:CQBarkDeliveredKey];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:CQBarkBaselineKey];
    [self setStatus:@"尚未配置 Bark 推送" failed:NO];
    return YES;
}

- (NSURLSessionDataTask *)sendPayload:(NSDictionary *)payload toURL:(NSURL *)url completion:(void (^)(NSError * _Nullable, BOOL))completion {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        id result = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSNumber *code = [result isKindOfClass:NSDictionary.class] && [result[@"code"] isKindOfClass:NSNumber.class] ? result[@"code"] : nil;
        BOOL accepted = !error && http.statusCode >= 200 && http.statusCode < 300 && code.integerValue == 200;
        BOOL retry = error ? error.code != NSURLErrorCancelled : (http.statusCode == 408 || http.statusCode == 429 || http.statusCode >= 500 || code.integerValue >= 500);
        // Server responses and NSURLSession errors may contain the device key. Only return fixed messages.
        NSString *message = error ? @"网络请求失败，请检查网络与 Bark 服务地址" : @"Bark 未接受推送，请检查设备 key 和服务地址";
        if (http.statusCode >= 300 && http.statusCode < 400) message = @"Bark 地址发生跳转，请填写最终的 HTTPS 推送链接";
        dispatch_async(dispatch_get_main_queue(), ^{ completion(accepted ? nil : CQBarkError(message), retry); });
    }];
    [task resume];
    return task;
}

- (void)sendTestToEndpoint:(NSString *)endpoint completion:(void (^)(NSError * _Nullable))completion {
    NSError *error = nil;
    NSURL *url = [self validatedEndpoint:endpoint error:&error];
    if (!url) { completion(error); return; }
    [self sendPayload:@{@"title": @"Codex Quota 测试通知", @"body": @"Bark 推送已连接，任务需要审批或完成时会在这里提醒你。", @"group": @"Codex Quota"}
        toURL:url completion:^(NSError *deliveryError, BOOL retry) { (void)retry; completion(deliveryError); }];
}

- (void)sendEvent:(NSString *)eventKey token:(NSUUID *)token payload:(NSDictionary *)payload attempt:(NSUInteger)attempt {
    if (!self.enabled || self.pendingEvents[eventKey] != token) return;
    __weak typeof(self) weakSelf = self;
    self.requests[eventKey] = [self sendPayload:payload toURL:self.endpointURL completion:^(NSError *error, BOOL retry) {
        typeof(self) self = weakSelf;
        if (!self || self.pendingEvents[eventKey] != token) return;
        [self.requests removeObjectForKey:eventKey];
        if (error && retry && attempt < 2) {
            [self setStatus:@"推送暂时失败，正在自动重试…" failed:YES];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((attempt == 0 ? 5 : 20) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [weakSelf sendEvent:eventKey token:token payload:payload attempt:attempt + 1];
            });
            return;
        }
        [self.pendingEvents removeObjectForKey:eventKey];
        if (error) {
            [self.failedEvents addObject:eventKey];
            [self setStatus:[error.localizedDescription stringByAppendingString:@"，请发送测试检查链接"] failed:YES];
        } else {
            self.deliveredEvents[eventKey] = @(NSDate.date.timeIntervalSince1970);
            [NSUserDefaults.standardUserDefaults setObject:self.deliveredEvents forKey:CQBarkDeliveredKey];
            [self setStatus:@"最近一条任务通知已发送至 Bark" failed:NO];
        }
    }];
}

- (void)handleSnapshot:(CQTaskSnapshot *)snapshot {
    NSAssert(NSThread.isMainThread, @"Bark notifications must be handled on the main thread");
    self.latestSnapshot = snapshot;
    if (!self.enabled) return;
    if (!self.endpointLoaded) {
        NSError *error = nil;
        [self savedEndpointWithError:&error];
        if (error) { [self setStatus:error.localizedDescription failed:YES]; return; }
    }
    if (!self.endpointURL) { [self setStatus:@"请在通知设置中重新保存 Bark 链接" failed:YES]; return; }
    NSMutableSet *waitingKeys = [NSMutableSet set];
    for (CQCodexTask *task in snapshot.waitingForApprovalTasks) [waitingKeys addObject:[@"approval:" stringByAppendingString:task.turnID]];
    NSMutableSet *knownKeys = [NSMutableSet setWithArray:self.deliveredEvents.allKeys];
    [knownKeys addObjectsFromArray:self.pendingEvents.allKeys];
    [knownKeys unionSet:self.failedEvents];
    NSTimeInterval cutoff = NSDate.date.timeIntervalSince1970 - CQBarkRetentionInterval;
    for (NSString *key in knownKeys) {
        BOOL approvalEnded = [key hasPrefix:@"approval:"] && ![waitingKeys containsObject:key];
        if (approvalEnded || (self.deliveredEvents[key] && self.deliveredEvents[key].doubleValue < cutoff)) [self.deliveredEvents removeObjectForKey:key];
        if (approvalEnded) {
            [self.pendingEvents removeObjectForKey:key];
            [self.requests[key] cancel];
            [self.requests removeObjectForKey:key];
            [self.failedEvents removeObject:key];
        }
    }
    [NSUserDefaults.standardUserDefaults setObject:self.deliveredEvents forKey:CQBarkDeliveredKey];
    NSTimeInterval baseline = [NSUserDefaults.standardUserDefaults doubleForKey:CQBarkBaselineKey];
    for (CQCodexTask *task in [snapshot.waitingForApprovalTasks arrayByAddingObjectsFromArray:snapshot.unreadCompletedTasks]) {
        if (task.turnID.length == 0) continue;
        BOOL waiting = task.state == CQTaskStateWaitingForApproval;
        if (!waiting && task.completedAt.timeIntervalSince1970 < baseline) continue;
        NSString *key = [(waiting ? @"approval:" : @"completed:") stringByAppendingString:task.turnID];
        if (self.deliveredEvents[key] || self.pendingEvents[key] || [self.failedEvents containsObject:key]) continue;
        NSUUID *token = NSUUID.UUID;
        self.pendingEvents[key] = token;
        NSDictionary *payload = @{@"title": waiting ? @"Codex Quota · 任务需要审批" : @"Codex Quota · 任务已完成", @"subtitle": task.title ?: @"未命名任务",
            @"body": [NSString stringWithFormat:@"项目：%@", task.projectName.length > 0 ? task.projectName : @"本机任务"], @"group": @"Codex Quota", @"id": token.UUIDString};
        [self sendEvent:key token:token payload:payload attempt:0];
    }
}

@end
