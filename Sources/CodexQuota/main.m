#import <Cocoa/Cocoa.h>
#import <Network/Network.h>
#import <ServiceManagement/ServiceManagement.h>
#import <os/log.h>
#import "CQCodexClient.h"
#import "CQCodexConfigManager.h"
#import "CQDeepSeekClient.h"
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
@property(nonatomic, strong) CQCodexConfigManager *configManager;
@property(nonatomic, strong) CQDeepSeekClient *deepSeekClient;
@property(nonatomic, strong, nullable) CQQuotaSnapshot *snapshot;
@property(nonatomic, strong, nullable) CQDeepSeekBalance *deepSeekBalance;
@property(nonatomic) CQProviderMode providerMode;
@property(nonatomic, copy) NSString *deepSeekModel;
@property(nonatomic, strong, nullable) NSURL *codexURL;
@property(nonatomic, strong, nullable) NSTimer *pollTimer;
@property(nonatomic) nw_path_monitor_t pathMonitor;
@property(nonatomic) BOOL networkAvailable;
@property(nonatomic) BOOL refreshing;
@property(nonatomic) BOOL authenticating;
@property(nonatomic) NSInteger reconnectAttempt;
@property(nonatomic) NSInteger connectionGeneration;
@property(nonatomic) NSInteger refreshRetryAttempt;
@property(nonatomic) NSInteger refreshRetryToken;
@property(nonatomic) NSInteger loginPollRemaining;
@property(nonatomic) CQConnectionState connectionState;
@property(nonatomic, copy) NSString *detail;
@property(nonatomic, copy, nullable) NSString *errorMessage;
@property(nonatomic, strong, nullable) NSWindow *previewWindow;
@end

@implementation CQAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
    if ([arguments containsObject:@"--preview"]
        || [arguments containsObject:@"--preview-deepseek"]
        || [arguments containsObject:@"--preview-api-key"]) {
        [self configureApplicationMenu];
        [self showPreviewWindow];
        return;
    }
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [self configureApplicationMenu];
    self.configManager = [CQCodexConfigManager new];
    self.deepSeekClient = [CQDeepSeekClient new];
    self.providerMode = self.configManager.currentMode;
    self.deepSeekModel = self.configManager.currentDeepSeekModel;
    BOOL migratedHistoryConfiguration = NO;
    if (self.providerMode == CQProviderModeDeepSeek
        && self.configManager.managedConfigurationNeedsHistoryMigration) {
        NSString *apiKey = self.configManager.savedDeepSeekAPIKey;
        NSError *migrationError = nil;
        if (apiKey.length > 0
            && [self.configManager switchToDeepSeekModel:self.deepSeekModel apiKey:apiKey error:&migrationError]) {
            migratedHistoryConfiguration = YES;
        } else {
            self.errorMessage = migrationError.localizedDescription ?: @"无法升级 DeepSeek 配置以保留对话历史";
        }
    }
    self.networkAvailable = YES;
    self.connectionState = CQConnectionStateLocating;
    self.detail = self.providerMode == CQProviderModeDeepSeek
        ? @"正在读取 DeepSeek 余额…" : @"正在查找 Codex…";
    [self configureMenuBar];
    [self configurePopover];
    [self configureSystemObservers];
    [self render];
    if (self.providerMode == CQProviderModeDeepSeek) [self refreshDeepSeekBalance];
    else [self locateAndConnect];
    if (migratedHistoryConfiguration) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self offerToRestartCodexAfterChange:@"DeepSeek 配置已升级，Codex 登录身份将保持不变"];
        });
    }
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
    BOOL deepSeekPreview = [NSProcessInfo.processInfo.arguments containsObject:@"--preview-deepseek"];
    CQDeepSeekBalance *deepSeekBalance = nil;
    if (deepSeekPreview) {
        deepSeekBalance = [CQDeepSeekBalance balanceFromResponse:@{
            @"is_available": @YES,
            @"balance_infos": @[@{
                @"currency": @"CNY",
                @"total_balance": @"110.00",
                @"granted_balance": @"10.00",
                @"topped_up_balance": @"100.00"
            }]
        }];
    }
    [self.popoverController renderSnapshot:snapshot
                           deepSeekBalance:deepSeekBalance
                              providerMode:deepSeekPreview ? CQProviderModeDeepSeek : CQProviderModeCodex
                                     model:CQDeepSeekFlashModel
                                    status:@"已连接"
                                    detail:deepSeekPreview ? @"余额已同步" : @"额度已同步"
                                     error:nil
                                refreshing:NO
                                 signedOut:NO
                             launchAtLogin:NO];
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--preview-api-key"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *value = [self promptForDeepSeekAPIKeyWithTitle:@"API Key 粘贴验证"];
            if (value) {
                self.previewWindow.title = [NSString stringWithFormat:@"Codex Quota · 粘贴验证 %lu",
                    (unsigned long)value.length];
            }
        });
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.pollTimer invalidate];
    if (self.pathMonitor) nw_path_monitor_cancel(self.pathMonitor);
    [self.client stop];
    [self.deepSeekClient cancel];
}

- (void)configureApplicationMenu {
    NSMenu *mainMenu = [NSMenu new];
    NSMenuItem *editRoot = [[NSMenuItem alloc] initWithTitle:@"编辑" action:nil keyEquivalent:@""];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"编辑"];
    NSArray<NSArray *> *items = @[
        @[@"撤销", NSStringFromSelector(@selector(undo:)), @"z"],
        @[@"重做", NSStringFromSelector(@selector(redo:)), @"Z"],
        @[@"剪切", NSStringFromSelector(@selector(cut:)), @"x"],
        @[@"复制", NSStringFromSelector(@selector(copy:)), @"c"],
        @[@"粘贴", NSStringFromSelector(@selector(paste:)), @"v"],
        @[@"全选", NSStringFromSelector(@selector(selectAll:)), @"a"]
    ];
    for (NSArray<NSString *> *definition in items) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:definition[0]
                                                     action:NSSelectorFromString(definition[1])
                                              keyEquivalent:definition[2].lowercaseString];
        item.target = nil;
        if ([definition[0] isEqualToString:@"重做"]) {
            item.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
        }
        [editMenu addItem:item];
    }
    editRoot.submenu = editMenu;
    [mainMenu addItem:editRoot];
    NSApp.mainMenu = mainMenu;
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
    self.popoverController.providerChangeHandler = ^(CQProviderMode mode) {
        [weakSelf switchToProviderMode:mode];
    };
    self.popoverController.modelChangeHandler = ^(NSString *model) {
        [weakSelf switchDeepSeekModel:model];
    };
    self.popoverController.changeAPIKeyHandler = ^{ [weakSelf promptToChangeDeepSeekAPIKey]; };
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
    if (self.providerMode == CQProviderModeDeepSeek && self.networkAvailable) [self refreshDeepSeekBalance];
    else if (self.client.running && self.networkAvailable) [self refreshNow];
    else if (!self.client.running && self.networkAvailable) [self scheduleReconnectImmediately];
    else [self render];
}

- (void)locateAndConnect {
    if (self.providerMode != CQProviderModeCodex) return;
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
    if (self.providerMode != CQProviderModeCodex || !self.codexURL) return;
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
        if (weakSelf.providerMode != CQProviderModeCodex || weakSelf.client != weakClient) return;
        [weakSelf acceptSnapshot:snapshot];
    };
    client.processDidExit = ^(NSError *error) {
        if (weakSelf.providerMode != CQProviderModeCodex || weakSelf.client != weakClient) return;
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
    if (self.providerMode == CQProviderModeDeepSeek) {
        [self refreshDeepSeekBalance];
        return;
    }
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

- (NSString *)promptForDeepSeekAPIKeyWithTitle:(NSString *)title {
    NSAlert *alert = [NSAlert new];
    alert.messageText = title;
    alert.informativeText = @"API Key 以 sk- 开头。它会写入 Codex 官方配置，并额外保存到 macOS 钥匙串，供下次切换使用。";
    [alert addButtonWithTitle:@"保存并切换"];
    [alert addButtonWithTitle:@"取消"];
    NSSecureTextField *field = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 330, 26)];
    field.placeholderString = @"sk-…";
    field.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    alert.accessoryView = field;
    alert.window.initialFirstResponder = field;
    [NSApp activateIgnoringOtherApps:YES];
    [alert.window makeFirstResponder:field];
    if ([alert runModal] != NSAlertFirstButtonReturn) return nil;
    return [field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

- (NSArray<NSRunningApplication *> *)runningCodexApplications {
    return [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.openai.codex"];
}

- (NSURL *)codexApplicationURL {
    for (NSRunningApplication *application in [self runningCodexApplications]) {
        if (application.bundleURL) return application.bundleURL;
    }
    NSURL *url = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"com.openai.codex"];
    if (url) return url;
    for (NSString *path in @[@"/Applications/ChatGPT.app", @"/Applications/Codex.app"]) {
        if ([NSFileManager.defaultManager fileExistsAtPath:path]) return [NSURL fileURLWithPath:path];
    }
    return nil;
}

- (void)openCodexApplicationAtURL:(NSURL *)url {
    NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
    configuration.activates = YES;
    NSURL *bridgeURL = [NSBundle.mainBundle.bundleURL
        URLByAppendingPathComponent:@"Contents/MacOS/CodexQuotaHistoryBridge" isDirectory:NO];
    NSURL *realCLIURL = [url URLByAppendingPathComponent:@"Contents/Resources/codex" isDirectory:NO];
    if ([NSFileManager.defaultManager isExecutableFileAtPath:bridgeURL.path]
        && [NSFileManager.defaultManager isExecutableFileAtPath:realCLIURL.path]) {
        configuration.environment = @{
            @"CODEX_CLI_PATH": bridgeURL.path,
            @"CODEX_QUOTA_REAL_CLI_PATH": realCLIURL.path,
            @"CODEX_APP_SERVER_FORCE_CLI": @"1"
        };
    }
    __weak typeof(self) weakSelf = self;
    [NSWorkspace.sharedWorkspace openApplicationAtURL:url
                                        configuration:configuration
                                    completionHandler:^(NSRunningApplication *application, NSError *error) {
        (void)application;
        if (!error) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.errorMessage = error.localizedDescription ?: @"无法重新打开 Codex";
            [weakSelf render];
        });
    }];
}

- (void)waitForCodexToQuitThenOpenURL:(NSURL *)url attempt:(NSInteger)attempt {
    if ([self runningCodexApplications].count == 0) {
        [self openCodexApplicationAtURL:url];
        return;
    }
    if (attempt >= 20) {
        self.errorMessage = @"Codex 未能自动退出，请手动退出后重新打开";
        [self render];
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [weakSelf waitForCodexToQuitThenOpenURL:url attempt:attempt + 1];
    });
}

- (void)restartCodexApplication {
    NSURL *url = [self codexApplicationURL];
    if (!url) {
        self.errorMessage = @"未找到 Codex / ChatGPT 客户端，请手动重新打开";
        [self render];
        return;
    }
    NSArray<NSRunningApplication *> *applications = [self runningCodexApplications];
    if (applications.count == 0) {
        [self openCodexApplicationAtURL:url];
        return;
    }
    BOOL requested = NO;
    for (NSRunningApplication *application in applications) requested = [application terminate] || requested;
    if (!requested) {
        self.errorMessage = @"无法自动退出 Codex，请手动重启";
        [self render];
        return;
    }
    [self waitForCodexToQuitThenOpenURL:url attempt:0];
}

- (void)offerToRestartCodexAfterChange:(NSString *)changeDescription {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"配置已切换";
    alert.informativeText = [NSString stringWithFormat:
        @"%@。是否立即由 Codex Quota 重启 Codex？这样既会应用配置，也会同时显示 Codex 与 DeepSeek 的本机对话。",
        changeDescription];
    [alert addButtonWithTitle:@"立即重启"];
    [alert addButtonWithTitle:@"稍后"];
    [NSApp activateIgnoringOtherApps:YES];
    if ([alert runModal] == NSAlertFirstButtonReturn) [self restartCodexApplication];
}

- (void)switchToProviderMode:(CQProviderMode)mode {
    if (mode == self.providerMode) {
        [self render];
        return;
    }
    if (mode == CQProviderModeDeepSeek) {
        NSString *apiKey = self.configManager.savedDeepSeekAPIKey;
        if (apiKey.length == 0) apiKey = [self promptForDeepSeekAPIKeyWithTitle:@"连接 DeepSeek"];
        if (apiKey.length == 0) {
            [self render];
            return;
        }
        NSError *error = nil;
        if (![self.configManager switchToDeepSeekModel:CQDeepSeekFlashModel apiKey:apiKey error:&error]) {
            self.providerMode = self.configManager.currentMode;
            self.errorMessage = error.localizedDescription;
            [self render];
            return;
        }
        self.providerMode = CQProviderModeDeepSeek;
        self.deepSeekModel = CQDeepSeekFlashModel;
        self.connectionGeneration += 1;
        [self.client stop];
        self.client = nil;
        self.snapshot = nil;
        self.deepSeekBalance = nil;
        self.refreshing = NO;
        self.authenticating = NO;
        self.connectionState = CQConnectionStateConnecting;
        self.detail = @"已切换，新开的 Codex 会话将使用 DeepSeek";
        self.errorMessage = nil;
        self.reconnectAttempt = 0;
        [self render];
        [self refreshDeepSeekBalance];
        [self offerToRestartCodexAfterChange:@"已切换到 DeepSeek V4 Flash"];
        return;
    }

    NSError *error = nil;
    if (![self.configManager switchToCodexWithError:&error]) {
        self.providerMode = self.configManager.currentMode;
        self.errorMessage = error.localizedDescription;
        [self render];
        return;
    }
    self.providerMode = CQProviderModeCodex;
    [self.deepSeekClient cancel];
    self.deepSeekBalance = nil;
    self.refreshing = NO;
    self.authenticating = NO;
    self.connectionState = CQConnectionStateLocating;
    self.detail = @"已恢复 Codex 订阅配置，正在连接…";
    self.errorMessage = nil;
    self.reconnectAttempt = 0;
    [self render];
    [self locateAndConnect];
    [self offerToRestartCodexAfterChange:@"已恢复 Codex 默认订阅"];
}

- (void)switchDeepSeekModel:(NSString *)model {
    if (self.providerMode != CQProviderModeDeepSeek || [model isEqualToString:self.deepSeekModel]) return;
    NSString *apiKey = self.configManager.savedDeepSeekAPIKey;
    NSError *error = nil;
    if (apiKey.length == 0
        || ![self.configManager switchToDeepSeekModel:model apiKey:apiKey error:&error]) {
        self.errorMessage = error.localizedDescription ?: @"DeepSeek API Key 不可用";
        [self render];
        return;
    }
    self.deepSeekModel = model;
    self.detail = @"模型已切换，新开的 Codex 会话生效";
    self.errorMessage = nil;
    [self render];
    [self offerToRestartCodexAfterChange:[NSString stringWithFormat:@"已切换到 %@", model]];
}

- (void)promptToChangeDeepSeekAPIKey {
    if (self.providerMode != CQProviderModeDeepSeek) return;
    NSString *apiKey = [self promptForDeepSeekAPIKeyWithTitle:@"更换 DeepSeek API Key"];
    if (apiKey.length == 0) {
        [self render];
        return;
    }
    NSError *error = nil;
    if (![self.configManager switchToDeepSeekModel:self.deepSeekModel apiKey:apiKey error:&error]) {
        self.errorMessage = error.localizedDescription;
        [self render];
        return;
    }
    self.deepSeekBalance = nil;
    self.detail = @"API Key 已更新";
    self.errorMessage = nil;
    [self render];
    [self refreshDeepSeekBalance];
    [self offerToRestartCodexAfterChange:@"DeepSeek API Key 已更新"];
}

- (void)refreshDeepSeekBalance {
    if (self.providerMode != CQProviderModeDeepSeek) return;
    if (!self.networkAvailable) {
        self.connectionState = CQConnectionStateOffline;
        self.detail = @"网络不可用，将在恢复后刷新";
        [self render];
        return;
    }
    if (self.refreshing) return;
    NSString *apiKey = self.configManager.savedDeepSeekAPIKey;
    if (apiKey.length == 0) {
        self.connectionState = CQConnectionStateSignedOut;
        self.detail = @"请设置 DeepSeek API Key";
        self.errorMessage = nil;
        [self render];
        return;
    }
    self.refreshing = YES;
    if (!self.deepSeekBalance) self.connectionState = CQConnectionStateConnecting;
    self.detail = @"正在读取 DeepSeek 余额…";
    [self render];
    __weak typeof(self) weakSelf = self;
    [self.deepSeekClient fetchBalanceWithAPIKey:apiKey completion:^(CQDeepSeekBalance *balance, NSError *error) {
        typeof(self) self = weakSelf;
        if (!self || self.providerMode != CQProviderModeDeepSeek) return;
        self.refreshing = NO;
        if (error) {
            self.connectionState = error.code == 401 ? CQConnectionStateSignedOut
                : (self.networkAvailable ? CQConnectionStateError : CQConnectionStateOffline);
            self.detail = error.code == 401 ? @"请更换 DeepSeek API Key" : @"暂时无法读取余额";
            self.errorMessage = error.localizedDescription;
            [self render];
            return;
        }
        self.deepSeekBalance = balance;
        self.connectionState = CQConnectionStateConnected;
        self.detail = balance.available ? @"余额已同步" : @"当前账户没有可用余额";
        self.errorMessage = nil;
        [self render];
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
    self.refreshRetryAttempt = 0;
    self.refreshRetryToken += 1;
    [self render];
}

- (void)handleRefreshError:(NSError *)error {
    self.refreshing = NO;
    if (error.code == -4) {
        [self handleConnectionError:error];
        return;
    }
    NSString *message = error.localizedDescription ?: @"刷新失败";
    os_log_error(CQLogger(), "Quota refresh failed: %{public}@", message);
    NSString *lower = message.lowercaseString;
    if ([lower containsString:@"login"] || [lower containsString:@"auth"] || [message containsString:@"登录"]) {
        self.connectionState = CQConnectionStateSignedOut;
        self.detail = @"登录后即可读取额度";
        self.errorMessage = message;
    } else {
        self.connectionState = self.networkAvailable ? CQConnectionStateError : CQConnectionStateOffline;
        self.detail = self.networkAvailable ? @"暂时无法刷新，正在自动重试" : @"等待网络恢复";
        self.errorMessage = self.networkAvailable
            ? @"Codex 额度服务暂时不可用" : @"网络不可用";
        [self scheduleRefreshRetry];
    }
    [self render];
}

- (void)scheduleRefreshRetry {
    if (self.providerMode != CQProviderModeCodex || !self.networkAvailable || !self.client.running) return;
    static const NSTimeInterval delays[] = {2, 5, 15, 30, 60};
    NSInteger index = MIN(self.refreshRetryAttempt, 4);
    NSTimeInterval delay = delays[index];
    self.refreshRetryAttempt += 1;
    NSInteger expectedToken = ++self.refreshRetryToken;
    NSInteger expectedGeneration = self.connectionGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (expectedToken != self.refreshRetryToken
            || expectedGeneration != self.connectionGeneration
            || self.providerMode != CQProviderModeCodex
            || !self.client.running) return;
        [self refreshNow];
    });
}

- (void)handleConnectionError:(NSError *)error {
    if (self.providerMode != CQProviderModeCodex) return;
    os_log_error(CQLogger(), "Codex App Server connection failed with code %{public}ld",
                 (long)error.code);
    CQCodexClient *failedClient = self.client;
    self.client = nil;
    [failedClient stop];
    self.refreshing = NO;
    self.refreshRetryToken += 1;
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
    if (self.providerMode != CQProviderModeCodex || !self.networkAvailable || !self.codexURL) return;
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
    if (self.providerMode == CQProviderModeDeepSeek) [self refreshDeepSeekBalance];
    else if (self.client.running) [self refreshNow];
    else if (self.codexURL) [self connect];
    else [self locateAndConnect];
}

- (void)startLogin {
    if (self.providerMode != CQProviderModeCodex) return;
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
            {
                NSDate *updatedAt = self.providerMode == CQProviderModeDeepSeek
                    ? self.deepSeekBalance.updatedAt : self.snapshot.updatedAt;
                if (updatedAt && -updatedAt.timeIntervalSinceNow > 120) return @"数据陈旧";
            }
            return @"已连接";
        case CQConnectionStateSignedOut:
            return self.providerMode == CQProviderModeDeepSeek ? @"需要 API Key" : @"需要登录";
        case CQConnectionStateOffline: return @"离线";
        case CQConnectionStateError: return @"已断开";
        case CQConnectionStateConnecting: return @"连接中";
        case CQConnectionStateLocating: return @"查找中";
    }
}

- (void)render {
    NSString *metric = nil;
    NSString *provider = self.providerMode == CQProviderModeDeepSeek ? @"DeepSeek" : @"Codex";
    if (self.providerMode == CQProviderModeCodex
        && self.connectionState == CQConnectionStateConnected && self.snapshot) {
        double minimum = self.snapshot.minimumRemainingPercent;
        if (!isnan(minimum)) metric = [NSString stringWithFormat:@"%.0f%%", minimum];
    } else if (self.providerMode == CQProviderModeDeepSeek
               && self.connectionState == CQConnectionStateConnected && self.deepSeekBalance) {
        CQDeepSeekBalanceInfo *info = self.deepSeekBalance.preferredBalanceInfo;
        if (info) {
            NSString *symbol = [info.currency isEqualToString:@"CNY"] ? @"¥"
                : ([info.currency isEqualToString:@"USD"] ? @"$" : @"");
            metric = [NSString stringWithFormat:@"%@%@", symbol, info.totalBalance];
        }
    }
    if (metric) {
        self.statusItem.button.title = [NSString stringWithFormat:@" %@ %@", provider, metric];
    } else if (self.connectionState == CQConnectionStateError
               || self.connectionState == CQConnectionStateOffline
               || self.connectionState == CQConnectionStateSignedOut) {
        self.statusItem.button.title = [NSString stringWithFormat:@" %@ —", provider];
    } else {
        self.statusItem.button.title = [NSString stringWithFormat:@" %@ …", provider];
    }
    self.statusItem.button.accessibilityLabel = [NSString stringWithFormat:@"%@ 模型状态", provider];
    self.statusItem.button.accessibilityValue = metric ?: [self statusText];
    [self.popoverController renderSnapshot:self.snapshot
                           deepSeekBalance:self.deepSeekBalance
                              providerMode:self.providerMode
                                     model:self.deepSeekModel ?: CQDeepSeekFlashModel
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
