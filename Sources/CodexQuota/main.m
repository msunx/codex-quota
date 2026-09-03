#import <Cocoa/Cocoa.h>
#import <Network/Network.h>
#import <ServiceManagement/ServiceManagement.h>
#import <os/log.h>
#import "CQCodexClient.h"
#import "CQCodexConfigManager.h"
#import "CQDeepSeekClient.h"
#import "CQExtensionManagerController.h"
#import "CQExtensions.h"
#import "CQPopoverController.h"
#import "CQTaskMonitor.h"
#import "CQTaskNotificationController.h"
#import "CQTheme.h"

static NSString * const CQSavedCodexPathKey = @"CodexExecutablePath";
static CGFloat const CQPopoverWidth = 360.0;
static CGFloat const CQPanelAnchorGap = 6.0;
static CGFloat const CQPanelScreenEdgeInset = 8.0;
static CGFloat const CQPanelMinimumUsableHeight = 320.0;

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

typedef NS_ENUM(NSInteger, CQPopoverPage) {
    CQPopoverPageQuota,
    CQPopoverPageExtensions
};

@interface CQGlassPanel : NSPanel
@end

@implementation CQGlassPanel

- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
- (void)cancelOperation:(id)sender { [self orderOut:sender]; }

@end

@interface CQAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) CQGlassPanel *panel;
@property(nonatomic, strong) CQPopoverController *popoverController;
@property(nonatomic, strong) CQExtensionManager *extensionManager;
@property(nonatomic, strong) CQExtensionManagerController *extensionController;
@property(nonatomic, strong, nullable) CQCodexClient *client;
@property(nonatomic, strong) CQCodexConfigManager *configManager;
@property(nonatomic, strong) CQDeepSeekClient *deepSeekClient;
@property(nonatomic, strong) CQTaskMonitor *taskMonitor;
@property(nonatomic, strong) CQTaskNotificationController *taskNotificationController;
@property(nonatomic, strong) CQTaskSnapshot *taskSnapshot;
@property(nonatomic, strong, nullable) CQQuotaSnapshot *snapshot;
@property(nonatomic, strong, nullable) CQDeepSeekBalance *deepSeekBalance;
@property(nonatomic) CQProviderMode providerMode;
@property(nonatomic, copy) NSString *deepSeekModel;
@property(nonatomic, copy) NSString *glmModel;
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
@property(nonatomic) CQPopoverPage currentPopoverPage;
@property(nonatomic, copy) NSString *detail;
@property(nonatomic, copy, nullable) NSString *errorMessage;
@property(nonatomic, strong, nullable) NSWindow *previewWindow;
- (void)configurePanel;
- (void)positionPanel;
- (void)setPanelContentViewController:(NSViewController *)controller height:(CGFloat)height;
- (void)focusCodexTask:(CQCodexTask *)task;
- (BOOL)isCodexApplication:(nullable NSRunningApplication *)application;
- (BOOL)isCodexFrontmost;
@end

@implementation CQAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
    if ([arguments containsObject:@"--preview"]
        || [arguments containsObject:@"--preview-deepseek"]
        || [arguments containsObject:@"--preview-glm"]
        || [arguments containsObject:@"--preview-api-key"]
        || [arguments containsObject:@"--preview-extensions"]) {
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
    self.glmModel = self.configManager.currentGLMModel;
    BOOL migratedHistoryConfiguration = NO;
    if (self.providerMode != CQProviderModeCodex && self.configManager.managedConfigurationNeedsHistoryMigration) {
        NSString *apiKey = self.providerMode == CQProviderModeDeepSeek
            ? self.configManager.savedDeepSeekAPIKey : self.configManager.savedGLMAPIKey;
        NSError *migrationError = nil;
        BOOL migrated = NO;
        if (apiKey.length > 0) {
            migrated = self.providerMode == CQProviderModeDeepSeek
                ? [self.configManager switchToDeepSeekModel:self.deepSeekModel apiKey:apiKey error:&migrationError]
                : [self.configManager switchToGLMModel:self.glmModel apiKey:apiKey error:&migrationError];
        }
        if (migrated) {
            migratedHistoryConfiguration = YES;
        } else {
            NSString *provider = self.providerMode == CQProviderModeDeepSeek ? @"DeepSeek" : @"GLM";
            self.errorMessage = migrationError.localizedDescription
                ?: [NSString stringWithFormat:@"无法升级 %@ 配置以保留对话历史", provider];
        }
    }
    self.networkAvailable = YES;
    self.connectionState = self.providerMode == CQProviderModeGLM
        ? CQConnectionStateConnected : CQConnectionStateLocating;
    self.detail = self.providerMode == CQProviderModeDeepSeek ? @"正在读取 DeepSeek 余额…"
        : (self.providerMode == CQProviderModeGLM ? @"GLM 配置已就绪" : @"正在查找 Codex…");
    [self configureMenuBar];
    [self configurePanel];
    [self configureSystemObservers];
    self.taskNotificationController = [CQTaskNotificationController new];
    __weak typeof(self) weakSelf = self;
    self.taskNotificationController.taskSelectedHandler = ^(CQCodexTask *task) {
        [weakSelf focusCodexTask:task];
    };
    [self.taskNotificationController start];
    self.taskSnapshot = [CQTaskSnapshot emptySnapshot];
    self.taskMonitor = [CQTaskMonitor new];
    self.taskMonitor.snapshotDidUpdate = ^(CQTaskSnapshot *taskSnapshot) {
        [weakSelf.taskNotificationController handleSnapshot:taskSnapshot];
        weakSelf.taskSnapshot = taskSnapshot;
        if (taskSnapshot.unreadCompletedTasks.count > 0 && [weakSelf isCodexFrontmost]) {
            [weakSelf.taskMonitor markAllCompletedViewed];
            return;
        }
        [weakSelf render];
    };
    [self.taskMonitor start];
    [self render];
    if (self.providerMode == CQProviderModeDeepSeek) [self refreshDeepSeekBalance];
    else if (self.providerMode == CQProviderModeCodex) [self locateAndConnect];
    if (migratedHistoryConfiguration) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *provider = self.providerMode == CQProviderModeDeepSeek ? @"DeepSeek" : @"GLM";
            [self offerToRestartCodexAfterChange:[NSString stringWithFormat:@"%@ 配置已升级，Codex 登录身份将保持不变", provider]];
        });
    }
}

- (void)showPreviewWindow {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    self.popoverController = [CQPopoverController new];
    self.previewWindow = [[CQGlassPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 360, 420)
                  styleMask:NSWindowStyleMaskBorderless
                    backing:NSBackingStoreBuffered
                      defer:NO];
    self.previewWindow.title = @"Codex Quota · 界面预览";
    self.previewWindow.opaque = NO;
    self.previewWindow.backgroundColor = NSColor.clearColor;
    self.previewWindow.hasShadow = YES;
    self.previewWindow.level = NSFloatingWindowLevel;
    self.previewWindow.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces
        | NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.previewWindow.contentViewController = self.popoverController;
    [self.previewWindow center];
    [self.previewWindow orderFrontRegardless];
    [NSApp activateIgnoringOtherApps:YES];

    BOOL previewExtensions = [NSProcessInfo.processInfo.arguments containsObject:@"--preview-extensions"];
    if (previewExtensions) {
        self.extensionManager = [[CQExtensionManager alloc] initWithCodexURL:[self locateCodex]];
        self.extensionController = [[CQExtensionManagerController alloc] initWithManager:self.extensionManager];
        self.extensionController.backHandler = ^{};
        self.previewWindow.contentViewController = self.extensionController;
        [self.previewWindow setContentSize:NSMakeSize(360, 500)];
        self.previewWindow.title = @"Codex Quota · 扩展管理预览";
        return;
    }

    CQRateLimitWindow *shortWindow = [CQRateLimitWindow new];
    shortWindow.limitID = @"preview-primary";
    shortWindow.name = @"GPT-5.3-Codex-Spark · 5 小时";
    shortWindow.usedPercent = 26;
    shortWindow.durationMinutes = 300;
    shortWindow.resetsAt = [NSDate dateWithTimeIntervalSinceNow:78 * 60];
    CQRateLimitWindow *weeklyWindow = [CQRateLimitWindow new];
    weeklyWindow.limitID = @"preview-secondary";
    weeklyWindow.name = @"GPT-5.3-Codex-Spark · 7 天";
    weeklyWindow.usedPercent = 68;
    weeklyWindow.durationMinutes = 7 * 24 * 60;
    weeklyWindow.resetsAt = [NSDate dateWithTimeIntervalSinceNow:3 * 24 * 3600];
    CQRateLimitWindow *monthlyWindow = [CQRateLimitWindow new];
    monthlyWindow.limitID = @"preview-monthly";
    monthlyWindow.name = @"GPT-5.3-Codex-Spark · 30 天";
    monthlyWindow.usedPercent = 0;
    monthlyWindow.durationMinutes = 30 * 24 * 60;
    monthlyWindow.resetsAt = [NSDate dateWithTimeIntervalSinceNow:12 * 24 * 3600];
    CQRateLimitWindow *reserveWindow = [CQRateLimitWindow new];
    reserveWindow.limitID = @"preview-reserve";
    reserveWindow.name = @"GPT Reserve · 7 天";
    reserveWindow.usedPercent = 88;
    reserveWindow.durationMinutes = 7 * 24 * 60;
    reserveWindow.resetsAt = [NSDate dateWithTimeIntervalSinceNow:2 * 24 * 3600];
    CQQuotaSnapshot *snapshot = [CQQuotaSnapshot new];
    snapshot.windows = @[shortWindow, weeklyWindow, monthlyWindow, reserveWindow];
    snapshot.planType = @"Plus";
    snapshot.resetCreditsAvailable = @3;
    snapshot.hasWorkspaceCredits = YES;
    snapshot.workspaceBalance = @"128.50";
    snapshot.updatedAt = NSDate.date;
    BOOL deepSeekPreview = [NSProcessInfo.processInfo.arguments containsObject:@"--preview-deepseek"];
    BOOL glmPreview = [NSProcessInfo.processInfo.arguments containsObject:@"--preview-glm"];
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
    CQProviderMode previewMode = glmPreview ? CQProviderModeGLM
        : (deepSeekPreview ? CQProviderModeDeepSeek : CQProviderModeCodex);
    CQCodexTask *waitingTask = [CQCodexTask new];
    waitingTask.threadID = @"preview-waiting";
    waitingTask.turnID = @"preview-waiting-turn";
    waitingTask.title = @"确认生产环境发布方案";
    waitingTask.projectName = @"codex-quota";
    waitingTask.workingDirectory = [NSHomeDirectory() stringByAppendingPathComponent:@"Develop/codex-quota"];
    waitingTask.state = CQTaskStateWaitingForApproval;
    waitingTask.startedAt = [NSDate dateWithTimeIntervalSinceNow:-8 * 60];
    CQCodexTask *runningTask = [CQCodexTask new];
    runningTask.threadID = @"preview-running";
    runningTask.turnID = @"preview-running-turn";
    runningTask.title = @"重新设计任务状态看板";
    runningTask.projectName = @"codex-quota";
    runningTask.workingDirectory = [NSHomeDirectory() stringByAppendingPathComponent:@"Develop/codex-quota"];
    runningTask.state = CQTaskStateRunning;
    runningTask.startedAt = [NSDate dateWithTimeIntervalSinceNow:-3 * 60];
    CQCodexTask *completedTask = [CQCodexTask new];
    completedTask.threadID = @"preview-completed";
    completedTask.turnID = @"preview-completed-turn";
    completedTask.title = @"修复 Markdown 文档预览";
    completedTask.projectName = @"docs-site";
    completedTask.workingDirectory = [NSHomeDirectory() stringByAppendingPathComponent:@"Develop/docs-site"];
    completedTask.state = CQTaskStateCompletedUnread;
    completedTask.startedAt = [NSDate dateWithTimeIntervalSinceNow:-14 * 60];
    completedTask.completedAt = [NSDate dateWithTimeIntervalSinceNow:-2 * 60];
    CQTaskSnapshot *taskSnapshot = [CQTaskSnapshot emptySnapshot];
    taskSnapshot.waitingForApprovalTasks = @[waitingTask];
    taskSnapshot.runningTasks = @[runningTask];
    taskSnapshot.unreadCompletedTasks = @[completedTask];
    [self.popoverController renderSnapshot:snapshot
                           deepSeekBalance:deepSeekBalance
                              taskSnapshot:taskSnapshot
                              providerMode:previewMode
                                     model:glmPreview ? CQGLMFlashModel : CQDeepSeekFlashModel
                                    status:@"已连接"
                                    detail:deepSeekPreview ? @"余额已同步" : (glmPreview ? @"GLM 配置已就绪" : @"额度已同步")
                                     error:nil
                                refreshing:NO
                                 signedOut:NO
                             launchAtLogin:NO];
    [self.previewWindow setContentSize:self.popoverController.preferredContentSize];
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--preview-api-key"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *value = [self promptForAPIKeyWithTitle:@"API Key 粘贴验证" providerMode:CQProviderModeDeepSeek];
            if (value) {
                self.previewWindow.title = [NSString stringWithFormat:@"Codex Quota · 粘贴验证 %lu",
                    (unsigned long)value.length];
            }
        });
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.pollTimer invalidate];
    [self.taskMonitor stop];
    if (self.pathMonitor) nw_path_monitor_cancel(self.pathMonitor);
    [self.client stop];
    [self.deepSeekClient cancel];
    [self.extensionManager stop];
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

- (void)configurePanel {
    self.popoverController = [CQPopoverController new];
    __weak typeof(self) weakSelf = self;
    self.popoverController.refreshHandler = ^{ [weakSelf refreshNow]; };
    self.popoverController.loginHandler = ^{ [weakSelf startLogin]; };
    self.popoverController.chooseCodexHandler = ^{ [weakSelf chooseCodex]; };
    self.popoverController.providerChangeHandler = ^(CQProviderMode mode) {
        [weakSelf switchToProviderMode:mode];
    };
    self.popoverController.modelChangeHandler = ^(NSString *model) {
        [weakSelf switchExternalModel:model];
    };
    self.popoverController.changeAPIKeyHandler = ^{ [weakSelf promptToChangeExternalAPIKey]; };
    self.popoverController.extensionManagerHandler = ^{ [weakSelf showExtensionManager]; };
    self.popoverController.launchAtLoginHandler = ^(BOOL enabled) { [weakSelf setLaunchAtLogin:enabled]; };
    self.popoverController.taskSelectedHandler = ^(CQCodexTask *task) { [weakSelf focusCodexTask:task]; };
    self.popoverController.markAllTasksViewedHandler = ^{ [weakSelf.taskMonitor markAllCompletedViewed]; };
    self.popoverController.quitHandler = ^{ [NSApp terminate:nil]; };

    self.panel = [[CQGlassPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, CQPopoverWidth, self.popoverController.preferredContentSize.height)
                  styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                    backing:NSBackingStoreBuffered
                      defer:NO];
    self.panel.delegate = self;
    self.panel.opaque = NO;
    self.panel.backgroundColor = NSColor.clearColor;
    self.panel.hasShadow = YES;
    self.panel.level = NSPopUpMenuWindowLevel;
    self.panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces
        | NSWindowCollectionBehaviorFullScreenAuxiliary
        | NSWindowCollectionBehaviorTransient
        | NSWindowCollectionBehaviorIgnoresCycle;
    self.panel.animationBehavior = NSWindowAnimationBehaviorNone;
    self.panel.releasedWhenClosed = NO;
    self.panel.hidesOnDeactivate = NO;
    self.panel.movable = NO;
    self.panel.movableByWindowBackground = NO;
    self.panel.becomesKeyOnlyIfNeeded = NO;
    self.panel.accessibilityLabel = @"Codex Quota";
    self.panel.contentViewController = self.popoverController;
    self.currentPopoverPage = CQPopoverPageQuota;

    NSURL *extensionCodexURL = self.codexURL ?: [self locateCodex];
    self.extensionManager = [[CQExtensionManager alloc] initWithCodexURL:extensionCodexURL];
    self.extensionController = [[CQExtensionManagerController alloc] initWithManager:self.extensionManager];
    self.extensionController.backHandler = ^{ [weakSelf showQuotaPanel]; };
    [self.extensionManager startPeriodicChecks];
}

- (void)setPanelContentViewController:(NSViewController *)controller height:(CGFloat)height {
    if (self.panel.contentViewController != controller) self.panel.contentViewController = controller;
    NSStatusBarButton *button = self.statusItem.button;
    NSWindow *statusWindow = button.window;
    NSScreen *screen = statusWindow.screen ?: NSScreen.mainScreen;
    CGFloat constrainedHeight = height;
    if (screen) {
        NSRect availableFrame = screen.visibleFrame;
        CGFloat maximumHeight = NSHeight(availableFrame) - CQPanelScreenEdgeInset * 2;
        if (button && statusWindow) {
            NSRect anchorRect = [button convertRect:button.bounds toView:nil];
            anchorRect = [statusWindow convertRectToScreen:anchorRect];
            CGFloat heightBelowAnchor = NSMinY(anchorRect) - CQPanelAnchorGap
                - NSMinY(availableFrame) - CQPanelScreenEdgeInset;
            if (heightBelowAnchor > 0) maximumHeight = MIN(maximumHeight, heightBelowAnchor);
        }
        maximumHeight = MAX(CQPanelMinimumUsableHeight, floor(maximumHeight));
        constrainedHeight = MIN(height, maximumHeight);
    }
    [self.panel setContentSize:NSMakeSize(CQPopoverWidth, constrainedHeight)];
    [self positionPanel];
}

- (void)positionPanel {
    NSStatusBarButton *button = self.statusItem.button;
    NSWindow *statusWindow = button.window;
    if (!button || !statusWindow) return;
    NSRect anchorRect = [button convertRect:button.bounds toView:nil];
    anchorRect = [statusWindow convertRectToScreen:anchorRect];
    NSScreen *screen = statusWindow.screen ?: NSScreen.mainScreen;
    if (!screen) return;
    NSRect availableFrame = screen.visibleFrame;
    NSSize panelSize = self.panel.frame.size;
    CGFloat x = NSMidX(anchorRect) - panelSize.width / 2.0;
    x = MAX(NSMinX(availableFrame) + CQPanelScreenEdgeInset,
            MIN(x, NSMaxX(availableFrame) - panelSize.width - CQPanelScreenEdgeInset));
    CGFloat y = NSMinY(anchorRect) - panelSize.height - CQPanelAnchorGap;
    if (y < NSMinY(availableFrame) + CQPanelScreenEdgeInset) {
        y = MIN(NSMaxY(anchorRect) + CQPanelAnchorGap,
                NSMaxY(availableFrame) - panelSize.height - CQPanelScreenEdgeInset);
    }
    [self.panel setFrameOrigin:NSMakePoint(round(x), round(y))];
}

- (void)configureSystemObservers {
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self
                                                       selector:@selector(systemDidWake:)
                                                           name:NSWorkspaceDidWakeNotification
                                                         object:nil];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self
                                                       selector:@selector(workspaceDidActivateApplication:)
                                                           name:NSWorkspaceDidActivateApplicationNotification
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
    if (self.panel.visible) {
        [self.panel orderOut:nil];
        return;
    }
    if (self.currentPopoverPage == CQPopoverPageExtensions) [self showExtensionManager];
    else [self showQuotaPanel];
    [self positionPanel];
    [self.panel makeKeyAndOrderFront:nil];
    [self.taskMonitor refreshNow];
    [self refreshNow];
}

- (void)showExtensionManager {
    self.currentPopoverPage = CQPopoverPageExtensions;
    (void)self.extensionController.view;
    CGFloat height = self.extensionController.preferredContentSize.height;
    [self setPanelContentViewController:self.extensionController height:height];
    [self.extensionManager setCodexURL:self.codexURL ?: [self locateCodex]];
    if (self.extensionManager.items.count == 0) [self.extensionManager loadInstalledExtensions];
}

- (void)showQuotaPanel {
    self.currentPopoverPage = CQPopoverPageQuota;
    (void)self.popoverController.view;
    CGFloat height = self.popoverController.preferredContentSize.height;
    [self setPanelContentViewController:self.popoverController height:height];
}

- (void)windowDidResignKey:(NSNotification *)notification {
    if (notification.object != self.panel) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.panel.visible && !self.panel.keyWindow) [self.panel orderOut:nil];
    });
}

- (void)systemDidWake:(NSNotification *)notification {
    [self connectOrRefresh];
}

- (void)workspaceDidActivateApplication:(NSNotification *)notification {
    NSRunningApplication *application = notification.userInfo[NSWorkspaceApplicationKey];
    if (![self isCodexApplication:application]) return;
    [self.taskMonitor markAllCompletedViewed];
}

- (void)poll:(NSTimer *)timer {
    if (self.providerMode == CQProviderModeDeepSeek && self.networkAvailable) [self refreshDeepSeekBalance];
    else if (self.providerMode == CQProviderModeGLM) [self render];
    else if (self.client.running && self.networkAvailable) [self refreshNow];
    else if (!self.client.running && self.networkAvailable) [self scheduleReconnectImmediately];
    else [self render];
}

- (void)locateAndConnect {
    if (self.providerMode != CQProviderModeCodex) return;
    self.codexURL = [self locateCodex];
    [self.extensionManager setCodexURL:self.codexURL];
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
    if (self.providerMode == CQProviderModeGLM) {
        self.connectionState = self.networkAvailable ? CQConnectionStateConnected : CQConnectionStateOffline;
        self.detail = self.networkAvailable ? @"GLM 配置已就绪" : @"网络不可用";
        [self render];
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

- (NSString *)promptForAPIKeyWithTitle:(NSString *)title providerMode:(CQProviderMode)providerMode {
    NSAlert *alert = [NSAlert new];
    alert.messageText = title;
    BOOL deepSeek = providerMode == CQProviderModeDeepSeek;
    NSString *provider = deepSeek ? @"DeepSeek" : @"智谱";
    alert.informativeText = deepSeek
        ? @"API Key 以 sk- 开头。它会写入 Codex 配置，并额外保存到 macOS 钥匙串，供下次切换使用。"
        : @"请输入智谱 API Key。它会通过 Codex Responses 协议调用 GLM，并额外保存到 macOS 钥匙串。";
    [alert addButtonWithTitle:@"保存并切换"];
    [alert addButtonWithTitle:@"取消"];
    NSSecureTextField *field = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 330, 26)];
    field.placeholderString = deepSeek ? @"sk-…" : [NSString stringWithFormat:@"%@ API Key", provider];
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

- (BOOL)isCodexApplication:(NSRunningApplication *)application {
    return [application.bundleIdentifier isEqualToString:@"com.openai.codex"];
}

- (BOOL)isCodexFrontmost {
    return [self isCodexApplication:NSWorkspace.sharedWorkspace.frontmostApplication];
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

- (void)focusCodexTask:(CQCodexTask *)task {
    if (task.state == CQTaskStateCompletedUnread) [self.taskMonitor markTaskViewed:task];
    NSArray<NSRunningApplication *> *applications = [self runningCodexApplications];
    if (applications.count > 0) {
        [applications.firstObject activateWithOptions:0];
        return;
    }
    NSURL *url = [self codexApplicationURL];
    if (!url) {
        self.errorMessage = @"未找到 Codex / ChatGPT 客户端";
        [self render];
        return;
    }
    NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
    configuration.activates = YES;
    __weak typeof(self) weakSelf = self;
    [NSWorkspace.sharedWorkspace openApplicationAtURL:url
                                        configuration:configuration
                                    completionHandler:^(NSRunningApplication *application, NSError *error) {
        (void)application;
        if (!error) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.errorMessage = error.localizedDescription ?: @"无法打开 Codex";
            [weakSelf render];
        });
    }];
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
        @"%@。是否立即由 Codex Quota 重启 Codex？这样既会应用配置，也会同时显示 Codex、DeepSeek 与 GLM 的本机对话。",
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
        if (apiKey.length == 0) apiKey = [self promptForAPIKeyWithTitle:@"连接 DeepSeek" providerMode:CQProviderModeDeepSeek];
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
    if (mode == CQProviderModeGLM) {
        NSString *apiKey = self.configManager.savedGLMAPIKey;
        if (apiKey.length == 0) apiKey = [self promptForAPIKeyWithTitle:@"连接智谱 GLM" providerMode:CQProviderModeGLM];
        if (apiKey.length == 0) {
            [self render];
            return;
        }
        NSError *error = nil;
        if (![self.configManager switchToGLMModel:CQGLMFlashModel apiKey:apiKey error:&error]) {
            self.providerMode = self.configManager.currentMode;
            self.errorMessage = error.localizedDescription;
            [self render];
            return;
        }
        self.providerMode = CQProviderModeGLM;
        self.glmModel = CQGLMFlashModel;
        self.connectionGeneration += 1;
        [self.client stop];
        self.client = nil;
        [self.deepSeekClient cancel];
        self.snapshot = nil;
        self.deepSeekBalance = nil;
        self.refreshing = NO;
        self.authenticating = NO;
        self.connectionState = self.networkAvailable ? CQConnectionStateConnected : CQConnectionStateOffline;
        self.detail = self.networkAvailable ? @"已切换，新开的 Codex 会话将使用 GLM" : @"网络不可用";
        self.errorMessage = nil;
        self.reconnectAttempt = 0;
        [self render];
        [self offerToRestartCodexAfterChange:@"已切换到 GLM-5.3-Flash"];
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

- (void)switchExternalModel:(NSString *)model {
    if (self.providerMode == CQProviderModeCodex) return;
    NSString *currentModel = self.providerMode == CQProviderModeDeepSeek ? self.deepSeekModel : self.glmModel;
    if ([model isEqualToString:currentModel]) return;
    NSString *apiKey = self.providerMode == CQProviderModeDeepSeek
        ? self.configManager.savedDeepSeekAPIKey : self.configManager.savedGLMAPIKey;
    NSError *error = nil;
    BOOL switched = NO;
    if (apiKey.length > 0) {
        switched = self.providerMode == CQProviderModeDeepSeek
            ? [self.configManager switchToDeepSeekModel:model apiKey:apiKey error:&error]
            : [self.configManager switchToGLMModel:model apiKey:apiKey error:&error];
    }
    if (!switched) {
        NSString *provider = self.providerMode == CQProviderModeDeepSeek ? @"DeepSeek" : @"智谱";
        self.errorMessage = error.localizedDescription ?: [NSString stringWithFormat:@"%@ API Key 不可用", provider];
        [self render];
        return;
    }
    if (self.providerMode == CQProviderModeDeepSeek) self.deepSeekModel = model;
    else self.glmModel = model;
    self.detail = @"模型已切换，新开的 Codex 会话生效";
    self.errorMessage = nil;
    [self render];
    [self offerToRestartCodexAfterChange:[NSString stringWithFormat:@"已切换到 %@", model]];
}

- (void)promptToChangeExternalAPIKey {
    if (self.providerMode == CQProviderModeCodex) return;
    BOOL deepSeek = self.providerMode == CQProviderModeDeepSeek;
    NSString *provider = deepSeek ? @"DeepSeek" : @"智谱 GLM";
    NSString *apiKey = [self promptForAPIKeyWithTitle:[NSString stringWithFormat:@"更换 %@ API Key", provider]
                                         providerMode:self.providerMode];
    if (apiKey.length == 0) {
        [self render];
        return;
    }
    NSError *error = nil;
    BOOL switched = deepSeek
        ? [self.configManager switchToDeepSeekModel:self.deepSeekModel apiKey:apiKey error:&error]
        : [self.configManager switchToGLMModel:self.glmModel apiKey:apiKey error:&error];
    if (!switched) {
        self.errorMessage = error.localizedDescription;
        [self render];
        return;
    }
    self.deepSeekBalance = nil;
    self.detail = @"API Key 已更新";
    self.errorMessage = nil;
    if (deepSeek) [self refreshDeepSeekBalance];
    else self.connectionState = self.networkAvailable ? CQConnectionStateConnected : CQConnectionStateOffline;
    [self render];
    [self offerToRestartCodexAfterChange:[NSString stringWithFormat:@"%@ API Key 已更新", provider]];
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
    else if (self.providerMode == CQProviderModeGLM) {
        self.connectionState = self.networkAvailable ? CQConnectionStateConnected : CQConnectionStateOffline;
        self.detail = self.networkAvailable ? @"GLM 配置已就绪" : @"网络不可用";
        [self render];
    }
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
    [self.extensionManager setCodexURL:url];
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
                NSDate *updatedAt = self.providerMode == CQProviderModeDeepSeek ? self.deepSeekBalance.updatedAt
                    : (self.providerMode == CQProviderModeCodex ? self.snapshot.updatedAt : nil);
                if (updatedAt && -updatedAt.timeIntervalSinceNow > 120) return @"数据陈旧";
            }
            return @"已连接";
        case CQConnectionStateSignedOut:
            return self.providerMode == CQProviderModeCodex ? @"需要登录" : @"需要 API Key";
        case CQConnectionStateOffline: return @"离线";
        case CQConnectionStateError: return @"已断开";
        case CQConnectionStateConnecting: return @"连接中";
        case CQConnectionStateLocating: return @"查找中";
    }
}

- (void)render {
    NSString *metric = nil;
    NSString *provider = self.providerMode == CQProviderModeDeepSeek ? @"DeepSeek"
        : (self.providerMode == CQProviderModeGLM ? @"GLM" : @"Codex");
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
    } else if (self.providerMode == CQProviderModeGLM && self.connectionState == CQConnectionStateConnected) {
        metric = [self.glmModel isEqualToString:CQGLMFlashModel] ? @"Flash" : @"5.3";
    }
    NSString *taskSuffix = @"";
    NSColor *taskColor = nil;
    NSUInteger waitingCount = self.taskSnapshot.waitingForApprovalTasks.count;
    NSUInteger completedCount = self.taskSnapshot.unreadCompletedTasks.count;
    NSUInteger runningCount = self.taskSnapshot.runningTasks.count;
    if (waitingCount > 0) {
        taskSuffix = [NSString stringWithFormat:@" · !%lu", (unsigned long)waitingCount];
        taskColor = CQTheme.yellow;
    } else if (completedCount > 0) {
        taskSuffix = [NSString stringWithFormat:@" · ✓%lu", (unsigned long)completedCount];
        taskColor = CQTheme.green;
    } else if (runningCount > 0) {
        taskSuffix = [NSString stringWithFormat:@" · ●%lu", (unsigned long)runningCount];
        taskColor = CQTheme.accent;
    }
    NSString *baseTitle = nil;
    if (metric) {
        baseTitle = [NSString stringWithFormat:@" %@ %@", provider, metric];
    } else if (self.connectionState == CQConnectionStateError
               || self.connectionState == CQConnectionStateOffline
               || self.connectionState == CQConnectionStateSignedOut) {
        baseTitle = [NSString stringWithFormat:@" %@ —", provider];
    } else {
        baseTitle = [NSString stringWithFormat:@" %@ …", provider];
    }
    NSFont *statusFont = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium];
    NSMutableAttributedString *statusTitle = [[NSMutableAttributedString alloc] initWithString:baseTitle attributes:@{
        NSFontAttributeName: statusFont,
        NSForegroundColorAttributeName: NSColor.labelColor
    }];
    if (taskSuffix.length > 0) {
        [statusTitle appendAttributedString:[[NSAttributedString alloc] initWithString:taskSuffix attributes:@{
            NSFontAttributeName: statusFont,
            NSForegroundColorAttributeName: taskColor
        }]];
    }
    self.statusItem.button.attributedTitle = statusTitle;
    self.statusItem.button.toolTip = [NSString stringWithFormat:
        @"Codex Quota\n待审核 %lu · 未查看完成 %lu · 运行中 %lu",
        (unsigned long)waitingCount,
        (unsigned long)completedCount,
        (unsigned long)runningCount];
    self.statusItem.button.accessibilityLabel = [NSString stringWithFormat:@"%@ 模型状态", provider];
    self.statusItem.button.accessibilityValue = [NSString stringWithFormat:@"%@；待审核 %lu，未查看完成 %lu，运行中 %lu",
        metric ?: [self statusText],
        (unsigned long)waitingCount,
        (unsigned long)completedCount,
        (unsigned long)runningCount];
    [self.popoverController renderSnapshot:self.snapshot
                           deepSeekBalance:self.deepSeekBalance
                              taskSnapshot:self.taskSnapshot
                              providerMode:self.providerMode
                                     model:self.providerMode == CQProviderModeGLM
                                         ? (self.glmModel ?: CQGLMFlashModel)
                                         : (self.deepSeekModel ?: CQDeepSeekFlashModel)
                                    status:[self statusText]
                                    detail:self.detail ?: @""
                                     error:self.errorMessage
                                refreshing:self.refreshing
                                 signedOut:self.connectionState == CQConnectionStateSignedOut
                             launchAtLogin:[self isLaunchAtLoginEnabled]];
    if (self.panel && self.currentPopoverPage == CQPopoverPageQuota) {
        [self setPanelContentViewController:self.popoverController
                                     height:self.popoverController.preferredContentSize.height];
    }
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
