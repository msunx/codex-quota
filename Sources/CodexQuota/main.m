#import <Cocoa/Cocoa.h>
#import <Network/Network.h>
#import <ServiceManagement/ServiceManagement.h>
#import <os/log.h>
#import "CQCodexClient.h"
#import "CQPopoverController.h"
#import "CQTheme.h"

static NSString * const CQSavedCodexPathKey = @"CodexExecutablePath";

static os_log_t CQLogger(void) {
    static os_log_t logger;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        logger = os_log_create("com.muyang.codexquota", "connection");
    });
    return logger;
}

typedef NS_ENUM(NSInteger, CQConnectionState) {
    CQConnectionStateLocating,
    CQConnectionStateConnecting,
    CQConnectionStateConnected,
    CQConnectionStateSignedOut,
    CQConnectionStateOffline,
    CQConnectionStateError
};

@interface CQAppDelegate : NSObject <NSApplicationDelegate, NSPopoverDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSPopover *popover;
@property(nonatomic, strong) CQPopoverController *popoverController;
@property(nonatomic, strong, nullable) CQCodexClient *client;
@property(nonatomic, strong, nullable) CQQuotaSnapshot *snapshot;
@property(nonatomic, strong, nullable) NSURL *codexURL;
@property(nonatomic, strong, nullable) NSTimer *pollTimer;
@property(nonatomic) nw_path_monitor_t pathMonitor;
@property(nonatomic) BOOL networkAvailable;
@property(nonatomic) BOOL refreshing;
@property(nonatomic) BOOL authenticating;
@property(nonatomic) NSInteger reconnectAttempt;
@property(nonatomic) NSInteger connectionGeneration;
@property(nonatomic) NSInteger loginPollRemaining;
@property(nonatomic) CQConnectionState connectionState;
@property(nonatomic, copy) NSString *detail;
@property(nonatomic, copy, nullable) NSString *errorMessage;
@property(nonatomic, strong, nullable) NSWindow *previewWindow;
@end

@implementation CQAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--preview"]) {
        [self showPreviewWindow];
        return;
    }
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.networkAvailable = YES;
    self.connectionState = CQConnectionStateLocating;
    self.detail = @"正在查找 Codex…";
    [self configureMenuBar];
    [self configurePopover];
    [self configureSystemObservers];
    [self render];
    [self locateAndConnect];
}

- (void)showPreviewWindow {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    self.popoverController = [CQPopoverController new];
    self.previewWindow = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 360, 420)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    self.previewWindow.title = @"Codex Quota · 界面预览";
    self.previewWindow.level = NSFloatingWindowLevel;
    self.previewWindow.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces
        | NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.previewWindow.contentViewController = self.popoverController;
    [self.previewWindow center];
    [self.previewWindow orderFrontRegardless];
    [NSApp activateIgnoringOtherApps:YES];

    CQRateLimitWindow *shortWindow = [CQRateLimitWindow new];
    shortWindow.limitID = @"preview-primary";
    shortWindow.name = @"Codex · 5 小时";
    shortWindow.usedPercent = 26;
    shortWindow.durationMinutes = 300;
    shortWindow.resetsAt = [NSDate dateWithTimeIntervalSinceNow:78 * 60];
    CQRateLimitWindow *weeklyWindow = [CQRateLimitWindow new];
    weeklyWindow.limitID = @"preview-secondary";
    weeklyWindow.name = @"Codex · 7 天";
    weeklyWindow.usedPercent = 68;
    weeklyWindow.durationMinutes = 7 * 24 * 60;
    weeklyWindow.resetsAt = [NSDate dateWithTimeIntervalSinceNow:3 * 24 * 3600];
    CQQuotaSnapshot *snapshot = [CQQuotaSnapshot new];
    snapshot.windows = @[shortWindow, weeklyWindow];
    snapshot.planType = @"Plus";
    snapshot.resetCreditsAvailable = @3;
    snapshot.hasWorkspaceCredits = YES;
    snapshot.workspaceBalance = @"128.50";
    snapshot.updatedAt = NSDate.date;
    [self.popoverController renderSnapshot:snapshot
                                    status:@"已连接"
                                    detail:@"额度已同步"
                                     error:nil
                                refreshing:NO
                                 signedOut:NO
                             launchAtLogin:NO];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.pollTimer invalidate];
    if (self.pathMonitor) nw_path_monitor_cancel(self.pathMonitor);
    [self.client stop];
}

- (void)configureMenuBar {
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    NSStatusBarButton *button = self.statusItem.button;
    button.target = self;
    button.action = @selector(togglePopover:);
    button.toolTip = @"Codex Quota";
    if (@available(macOS 13.0, *)) {
        NSImage *image = [NSImage imageWithSystemSymbolName:@"gauge.with.dots.needle.67percent"
                                   accessibilityDescription:@"Codex 剩余额度"];
        image.template = YES;
        button.image = image;
        button.imagePosition = NSImageLeading;
    }
    button.title = @" …";
    button.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium];
    button.accessibilityLabel = @"Codex 剩余额度";
}

- (void)configurePopover {
    self.popoverController = [CQPopoverController new];
    __weak typeof(self) weakSelf = self;
    self.popoverController.refreshHandler = ^{ [weakSelf refreshNow]; };
    self.popoverController.loginHandler = ^{ [weakSelf startLogin]; };
    self.popoverController.chooseCodexHandler = ^{ [weakSelf chooseCodex]; };
    self.popoverController.launchAtLoginHandler = ^(BOOL enabled) { [weakSelf setLaunchAtLogin:enabled]; };
    self.popoverController.quitHandler = ^{ [NSApp terminate:nil]; };

    self.popover = [NSPopover new];
    self.popover.behavior = NSPopoverBehaviorTransient;
    self.popover.animates = !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    self.popover.contentViewController = self.popoverController;
    self.popover.delegate = self;
}

- (void)configureSystemObservers {
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self
                                                       selector:@selector(systemDidWake:)
                                                           name:NSWorkspaceDidWakeNotification
                                                         object:nil];
    self.pathMonitor = nw_path_monitor_create();
    dispatch_queue_t queue = dispatch_queue_create("com.muyang.codexquota.network", DISPATCH_QUEUE_SERIAL);
    __weak typeof(self) weakSelf = self;
    nw_path_monitor_set_queue(self.pathMonitor, queue);
    nw_path_monitor_set_update_handler(self.pathMonitor, ^(nw_path_t path) {
        BOOL available = nw_path_get_status(path) == nw_path_status_satisfied;
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self) return;
            BOOL restored = !self.networkAvailable && available;
            self.networkAvailable = available;
            if (!available) {
                self.connectionState = CQConnectionStateOffline;
                self.detail = @"网络不可用，将在恢复后刷新";
                [self render];
            } else if (restored) {
                [self connectOrRefresh];
            }
        });
    });
    nw_path_monitor_start(self.pathMonitor);

    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:30.0
                                                     target:self
                                                   selector:@selector(poll:)
                                                   userInfo:nil
                                                    repeats:YES];
}

- (void)togglePopover:(id)sender {
    if (self.popover.shown) {
        [self.popover performClose:nil];
        return;
    }
    NSStatusBarButton *button = self.statusItem.button;
    [self.popover showRelativeToRect:button.bounds ofView:button preferredEdge:NSRectEdgeMinY];
    [self refreshNow];
}

- (void)popoverDidShow:(NSNotification *)notification {
    [self.popover.contentViewController.view.window makeKeyWindow];
}

- (void)systemDidWake:(NSNotification *)notification {
    [self connectOrRefresh];
}

- (void)poll:(NSTimer *)timer {
    if (self.client.running && self.networkAvailable) [self refreshNow];
    else if (!self.client.running && self.networkAvailable) [self scheduleReconnectImmediately];
    else [self render];
}

- (void)locateAndConnect {
    self.codexURL = [self locateCodex];
    if (!self.codexURL) {
        self.connectionState = CQConnectionStateError;
        self.detail = @"未找到 Codex";
        self.errorMessage = @"请安装 ChatGPT/Codex，或点击“选择 Codex”指定可执行文件。";
        [self render];
        return;
    }
    [self connect];
}

- (NSURL *)locateCodex {
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:CQSavedCodexPathKey];
    if (saved.length) [candidates addObject:saved];
    [candidates addObjectsFromArray:@[
        @"/Applications/ChatGPT.app/Contents/Resources/codex",
        @"/Applications/Codex.app/Contents/Resources/codex",
        @"/opt/homebrew/bin/codex",
        @"/usr/local/bin/codex"
    ]];
    NSString *path = NSProcessInfo.processInfo.environment[@"PATH"] ?: @"";
    for (NSString *directory in [path componentsSeparatedByString:@":"]) {
        if (directory.length) [candidates addObject:[directory stringByAppendingPathComponent:@"codex"]];
    }
    NSFileManager *manager = NSFileManager.defaultManager;
    for (NSString *candidate in candidates) {
        NSString *expanded = candidate.stringByExpandingTildeInPath;
        if ([manager isExecutableFileAtPath:expanded]) return [NSURL fileURLWithPath:expanded];
    }
    return nil;
}

- (void)connect {
    if (!self.codexURL) return;
    os_log_info(CQLogger(), "Starting Codex App Server");
    self.connectionGeneration += 1;
    NSInteger generation = self.connectionGeneration;
    self.connectionState = CQConnectionStateConnecting;
    self.detail = @"正在连接 Codex App Server…";
    self.errorMessage = nil;
    [self render];

    [self.client stop];
    CQCodexClient *client = [CQCodexClient new];
    self.client = client;
    __weak typeof(self) weakSelf = self;
    __weak CQCodexClient *weakClient = client;
    client.snapshotDidUpdate = ^(CQQuotaSnapshot *snapshot) {
        if (weakSelf.client != weakClient) return;
        [weakSelf acceptSnapshot:snapshot];
    };
    client.processDidExit = ^(NSError *error) {
        if (weakSelf.client != weakClient) return;
        [weakSelf handleConnectionError:error];
    };
    [client startAtURL:self.codexURL completion:^(NSError *error) {
        typeof(self) self = weakSelf;
        if (!self || generation != self.connectionGeneration || self.client != weakClient) return;
        if (error) {
            [self handleConnectionError:error];
            return;
        }
        self.reconnectAttempt = 0;
        [self checkAccountThenRefresh];
    }];
}

- (void)checkAccountThenRefresh {
    __weak typeof(self) weakSelf = self;
    CQCodexClient *client = self.client;
    [client readAccount:^(NSDictionary *account, NSError *error) {
        typeof(self) self = weakSelf;
        if (!self || self.client != client) return;
        if (error) {
            [self handleRefreshError:error];
            return;
        }
        id accountValue = account[@"account"];
        BOOL signedOut = accountValue == NSNull.null || (!accountValue && account.count == 0);
        if (signedOut) {
            self.connectionState = CQConnectionStateSignedOut;
            self.detail = @"登录后即可读取额度";
            self.errorMessage = nil;
            [self render];
            return;
        }
        self.authenticating = NO;
        [self refreshNow];
    }];
}

- (void)refreshNow {
    if (!self.networkAvailable) {
        self.connectionState = CQConnectionStateOffline;
        self.detail = @"网络不可用，将在恢复后刷新";
        [self render];
        return;
    }
    if (!self.client.running) {
        [self scheduleReconnectImmediately];
        return;
    }
    if (self.refreshing) return;
    self.refreshing = YES;
    [self render];
    __weak typeof(self) weakSelf = self;
    CQCodexClient *client = self.client;
    [client refresh:^(CQQuotaSnapshot *snapshot, NSError *error) {
        typeof(self) self = weakSelf;
        if (!self || self.client != client) return;
        self.refreshing = NO;
        if (error) {
            [self handleRefreshError:error];
            return;
        }
        [self acceptSnapshot:snapshot];
    }];
}

- (void)acceptSnapshot:(CQQuotaSnapshot *)snapshot {
    os_log_info(CQLogger(), "Quota refreshed with %{public}lu windows",
                (unsigned long)snapshot.windows.count);
    self.snapshot = snapshot;
    self.connectionState = CQConnectionStateConnected;
    self.detail = snapshot.windows.count > 0 ? @"额度已同步" : @"已连接，暂无额度窗口";
    self.errorMessage = nil;
    self.refreshing = NO;
    self.reconnectAttempt = 0;
    [self render];
}

- (void)handleRefreshError:(NSError *)error {
    self.refreshing = NO;
    if (error.code == -4) {
        [self handleConnectionError:error];
        return;
    }
    NSString *message = error.localizedDescription ?: @"刷新失败";
    NSString *lower = message.lowercaseString;
    if ([lower containsString:@"login"] || [lower containsString:@"auth"] || [message containsString:@"登录"]) {
        self.connectionState = CQConnectionStateSignedOut;
        self.detail = @"登录后即可读取额度";
    } else {
        self.connectionState = self.networkAvailable ? CQConnectionStateError : CQConnectionStateOffline;
        self.detail = @"暂时无法刷新";
    }
    self.errorMessage = message;
    [self render];
}

- (void)handleConnectionError:(NSError *)error {
    os_log_error(CQLogger(), "Codex App Server connection failed with code %{public}ld",
                 (long)error.code);
    CQCodexClient *failedClient = self.client;
    self.client = nil;
    [failedClient stop];
    self.refreshing = NO;
    self.connectionState = self.networkAvailable ? CQConnectionStateError : CQConnectionStateOffline;
    self.detail = self.networkAvailable ? @"连接已中断，正在重试" : @"等待网络恢复";
    self.errorMessage = error.localizedDescription;
    [self render];
    [self scheduleReconnect];
}

- (void)scheduleReconnectImmediately {
    self.reconnectAttempt = 0;
    [self scheduleReconnect];
}

- (void)scheduleReconnect {
    if (!self.networkAvailable || !self.codexURL) return;
    static const NSTimeInterval delays[] = {2, 5, 15, 30, 60};
    NSInteger index = MIN(self.reconnectAttempt, 4);
    NSTimeInterval delay = delays[index];
    self.reconnectAttempt += 1;
    NSInteger expectedGeneration = ++self.connectionGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (expectedGeneration != self.connectionGeneration || self.client.running) return;
        [self connect];
    });
}

- (void)connectOrRefresh {
    if (self.client.running) [self refreshNow];
    else if (self.codexURL) [self connect];
    else [self locateAndConnect];
}

- (void)startLogin {
    if (!self.client.running) {
        [self connect];
        return;
    }
    self.authenticating = YES;
    self.detail = @"正在打开官方登录页面…";
    self.errorMessage = nil;
    [self render];
    __weak typeof(self) weakSelf = self;
    CQCodexClient *client = self.client;
    [client startChatGPTLogin:^(NSURL *url, NSError *error) {
        typeof(self) self = weakSelf;
        if (!self || self.client != client) return;
        if (error) {
            self.authenticating = NO;
            [self handleRefreshError:error];
            return;
        }
        [NSWorkspace.sharedWorkspace openURL:url];
        self.detail = @"请在浏览器完成登录";
        self.loginPollRemaining = 40;
        [self render];
        [self pollLoginCompletion];
    }];
}

- (void)pollLoginCompletion {
    if (!self.authenticating || self.loginPollRemaining-- <= 0) {
        self.authenticating = NO;
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (!self || !self.authenticating) return;
        CQCodexClient *client = self.client;
        [client readAccount:^(NSDictionary *account, NSError *error) {
            if (self.client != client) return;
            id accountValue = account[@"account"];
            if (!error && accountValue != NSNull.null && (accountValue || account.count > 0)) {
                self.authenticating = NO;
                [self refreshNow];
            } else {
                [self pollLoginCompletion];
            }
        }];
    });
}

- (void)chooseCodex {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = @"选择 Codex 可执行文件";
    panel.message = @"请选择 ChatGPT App 内置或单独安装的 codex 文件。";
    panel.prompt = @"选择";
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    if ([panel runModal] != NSModalResponseOK) return;
    NSURL *url = panel.URL;
    if (![NSFileManager.defaultManager isExecutableFileAtPath:url.path]) {
        self.errorMessage = @"所选文件不可执行，请重新选择 Codex。";
        [self render];
        return;
    }
    [NSUserDefaults.standardUserDefaults setObject:url.path forKey:CQSavedCodexPathKey];
    self.codexURL = url;
    self.reconnectAttempt = 0;
    [self connect];
}

- (void)setLaunchAtLogin:(BOOL)enabled {
    if (![NSBundle.mainBundle.bundlePath hasPrefix:@"/Applications/"]) {
        self.errorMessage = @"请先将 Codex Quota.app 移入“应用程序”文件夹，再开启登录时启动。";
        [self render];
        return;
    }
    NSError *error = nil;
    BOOL success = enabled
        ? [SMAppService.mainAppService registerAndReturnError:&error]
        : [SMAppService.mainAppService unregisterAndReturnError:&error];
    if (!success) self.errorMessage = error.localizedDescription ?: @"无法更新登录项";
    else self.errorMessage = nil;
    [self render];
}

- (BOOL)isLaunchAtLoginEnabled {
    return SMAppService.mainAppService.status == SMAppServiceStatusEnabled;
}

- (NSString *)statusText {
    if (self.authenticating) return @"登录中";
    switch (self.connectionState) {
        case CQConnectionStateConnected:
            if (self.snapshot && -self.snapshot.updatedAt.timeIntervalSinceNow > 120) return @"数据陈旧";
            return @"已连接";
        case CQConnectionStateSignedOut: return @"需要登录";
        case CQConnectionStateOffline: return @"离线";
        case CQConnectionStateError: return @"已断开";
        case CQConnectionStateConnecting: return @"连接中";
        case CQConnectionStateLocating: return @"查找中";
    }
}

- (void)render {
    NSString *quota = nil;
    if (self.connectionState == CQConnectionStateConnected && self.snapshot) {
        double minimum = self.snapshot.minimumRemainingPercent;
        if (!isnan(minimum)) quota = [NSString stringWithFormat:@"%.0f%%", minimum];
    }
    if (quota) {
        self.statusItem.button.title = [@" " stringByAppendingString:quota];
    } else if (self.connectionState == CQConnectionStateError
               || self.connectionState == CQConnectionStateOffline
               || self.connectionState == CQConnectionStateSignedOut) {
        self.statusItem.button.title = @" —";
    } else {
        self.statusItem.button.title = @" …";
    }
    self.statusItem.button.accessibilityValue = quota ?: [self statusText];
    [self.popoverController renderSnapshot:self.snapshot
                                    status:[self statusText]
                                    detail:self.detail ?: @""
                                     error:self.errorMessage
                                refreshing:self.refreshing
                                 signedOut:self.connectionState == CQConnectionStateSignedOut
                             launchAtLogin:[self isLaunchAtLoginEnabled]];
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        (void)argc;
        (void)argv;
        NSApplication *application = NSApplication.sharedApplication;
        CQAppDelegate *delegate = [CQAppDelegate new];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
