#import <Cocoa/Cocoa.h>
#import <Network/Network.h>
#import <ServiceManagement/ServiceManagement.h>
#import <os/log.h>
#import "CQCodexClient.h"
#import "CQExtensionManagerController.h"
#import "CQExtensions.h"
#import "CQCodexConfigManager.h"
#import "CQPopoverController.h"
#import "CQNotificationSettingsController.h"
#import "CQTaskMonitor.h"
#import "CQTaskNotificationController.h"
#import "CQTheme.h"
#import "CQMenuBarStatusView.h"

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
    CQPopoverPageExtensions,
    CQPopoverPageNotificationSettings
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
@property(nonatomic, strong) CQMenuBarStatusView *statusView;
@property(nonatomic, strong) CQGlassPanel *panel;
@property(nonatomic, strong) CQPopoverController *popoverController;
@property(nonatomic, strong) CQExtensionManager *extensionManager;
@property(nonatomic, strong) CQExtensionManagerController *extensionController;
@property(nonatomic, strong) CQNotificationSettingsController *notificationSettingsController;
@property(nonatomic, strong, nullable) CQCodexClient *client;
@property(nonatomic, strong) CQCodexConfigManager *configManager;
@property(nonatomic, strong) CQTaskMonitor *taskMonitor;
@property(nonatomic, strong) CQTaskNotificationController *taskNotificationController;
@property(nonatomic, strong, nullable) CQCodexTask *pendingNotificationTask;
@property(nonatomic, strong) CQTaskSnapshot *taskSnapshot;
@property(nonatomic, strong, nullable) CQQuotaSnapshot *snapshot;
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

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    (void)notification;
    // Install the notification delegate before launch completes so clicks can relaunch the app.
    self.taskNotificationController = [CQTaskNotificationController new];
    __weak typeof(self) weakSelf = self;
    self.taskNotificationController.taskSelectedHandler = ^(CQCodexTask *task) {
        typeof(self) self = weakSelf;
        if (!self) return;
        if (!self.taskMonitor) {
            self.pendingNotificationTask = task;
            return;
        }
        [self focusCodexTask:task];
    };
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
    if ([arguments containsObject:@"--preview"]
        || [arguments containsObject:@"--preview-notifications"]
        || [arguments containsObject:@"--preview-extensions"]) {
        [self configureApplicationMenu];
        [self showPreviewWindow];
        return;
    }
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [self configureApplicationMenu];
    self.configManager = [CQCodexConfigManager new];
    self.networkAvailable = YES;
    self.connectionState = CQConnectionStateLocating;
    self.detail = @"正在查找 Codex…";
    [self configureMenuBar];
    [self configurePanel];
    [self configureSystemObservers];
    __weak typeof(self) weakSelf = self;
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
    [self locateAndConnect];
    if (self.pendingNotificationTask) {
        CQCodexTask *task = self.pendingNotificationTask;
        self.pendingNotificationTask = nil;
        [self focusCodexTask:task];
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

    if ([NSProcessInfo.processInfo.arguments containsObject:@"--preview-notifications"]) {
        self.notificationSettingsController = [[CQNotificationSettingsController alloc] initWithBarkService:nil];
        self.previewWindow.contentViewController = self.notificationSettingsController;
        (void)self.notificationSettingsController.view;
        [self.previewWindow setContentSize:self.notificationSettingsController.preferredContentSize];
        self.previewWindow.title = @"Codex Quota · 通知设置预览";
        return;
    }

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
                              taskSnapshot:taskSnapshot
                                    status:@"已连接"
                                    detail:@"额度已同步"
                                     error:nil
                                refreshing:NO
                                 signedOut:NO
                             launchAtLogin:NO];
    [self.previewWindow setContentSize:self.popoverController.preferredContentSize];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.pollTimer invalidate];
    [self.taskMonitor stop];
    if (self.pathMonitor) nw_path_monitor_cancel(self.pathMonitor);
    [self.extensionManager stop];
    [self.client stop];
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
    button.title = @"";
    self.statusView = [[CQMenuBarStatusView alloc] initWithFrame:NSMakeRect(6, 0, 0, NSHeight(button.bounds))];
    self.statusView.autoresizingMask = NSViewHeightSizable;
    [button addSubview:self.statusView];
    self.statusItem.length = self.statusView.preferredWidth + 12;
    self.statusView.frame = NSMakeRect(6, 0, self.statusView.preferredWidth, NSHeight(button.bounds));
    button.accessibilityLabel = @"额度与任务状态";
}

- (void)configurePanel {
    self.popoverController = [CQPopoverController new];
    __weak typeof(self) weakSelf = self;
    self.popoverController.refreshHandler = ^{ [weakSelf refreshNow]; };
    self.popoverController.loginHandler = ^{ [weakSelf startLogin]; };
    self.popoverController.chooseCodexHandler = ^{ [weakSelf chooseCodex]; };
    self.popoverController.extensionManagerHandler = ^{ [weakSelf showExtensionManager]; };
    self.popoverController.notificationSettingsHandler = ^{ [weakSelf showNotificationSettings]; };
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
    self.notificationSettingsController = [[CQNotificationSettingsController alloc] initWithBarkService:self.taskNotificationController.barkService];
    self.notificationSettingsController.backHandler = ^{ [weakSelf showQuotaPanel]; };
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
    // AppKit uses the controller's preferred size when constraining its hosting window.
    controller.preferredContentSize = NSMakeSize(CQPopoverWidth, constrainedHeight);
    [self.panel setContentSize:controller.preferredContentSize];
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
    else if (self.currentPopoverPage == CQPopoverPageNotificationSettings) [self showNotificationSettings];
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

- (void)showNotificationSettings {
    self.currentPopoverPage = CQPopoverPageNotificationSettings;
    (void)self.notificationSettingsController.view;
    [self setPanelContentViewController:self.notificationSettingsController height:340];
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
    if (self.client.running && self.networkAvailable) [self refreshNow];
    else if (!self.client.running && self.networkAvailable) [self scheduleReconnectImmediately];
    else [self render];
}

- (void)locateAndConnect {
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
    if (!self.codexURL) return;
    NSError *restoreError = nil;
    if (![self.configManager restoreLegacyConfigurationIfNeededWithError:&restoreError]) {
        self.connectionState = CQConnectionStateError;
        self.detail = @"无法恢复 Codex 原始配置";
        self.errorMessage = restoreError.localizedDescription;
        [self render];
        return;
    }
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
    [self.panel orderOut:nil];
    NSURL *url = [self codexApplicationURL];
    if (!url) {
        [self showCodexTaskOpenError:@"未找到 Codex / ChatGPT 客户端"];
        return;
    }
    NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
    configuration.activates = YES;
    __weak typeof(self) weakSelf = self;
    void (^completionHandler)(NSRunningApplication *, NSError *) = ^(NSRunningApplication *application, NSError *error) {
        (void)application;
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self) return;
            if (error) {
                os_log_error(CQLogger(), "Failed to open Codex task: %{public}@", error.localizedDescription);
                [self showCodexTaskOpenError:error.localizedDescription ?: @"无法打开 Codex 会话"];
                return;
            }
            if (task.state == CQTaskStateCompletedUnread) [self.taskMonitor markTaskViewed:task];
        });
    };
    NSString *threadID = [task.threadID stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (threadID.length == 0) {
        [NSWorkspace.sharedWorkspace openApplicationAtURL:url configuration:configuration completionHandler:completionHandler];
        return;
    }
    NSCharacterSet *pathCharacters = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    NSString *encodedThreadID = [threadID stringByAddingPercentEncodingWithAllowedCharacters:pathCharacters];
    NSURL *threadURL = [NSURL URLWithString:[@"codex://threads/" stringByAppendingString:encodedThreadID]];
    [NSWorkspace.sharedWorkspace openURLs:@[threadURL] withApplicationAtURL:url configuration:configuration completionHandler:completionHandler];
}

- (void)showCodexTaskOpenError:(NSString *)message {
    self.errorMessage = message;
    [self render];
    [self showQuotaPanel];
    [self positionPanel];
    [self.panel makeKeyAndOrderFront:nil];
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
    if (!self.networkAvailable || !self.client.running) return;
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
            || !self.client.running) return;
        [self refreshNow];
    });
}

- (void)handleConnectionError:(NSError *)error {
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
        case CQConnectionStateConnected: {
            NSDate *updatedAt = self.snapshot.updatedAt;
            return updatedAt && -updatedAt.timeIntervalSinceNow > 120 ? @"数据陈旧" : @"已连接";
        }
        case CQConnectionStateSignedOut: return @"需要登录";
        case CQConnectionStateOffline: return @"离线";
        case CQConnectionStateError: return @"已断开";
        case CQConnectionStateConnecting: return @"连接中";
        case CQConnectionStateLocating: return @"查找中";
    }
}

- (void)render {
    NSString *metric = nil;
    double remainingPercent = NAN;
    if (self.connectionState == CQConnectionStateConnected && self.snapshot) {
        double minimum = self.snapshot.minimumRemainingPercent;
        if (isfinite(minimum)) {
            metric = [NSString stringWithFormat:@"%.0f%%", minimum];
            remainingPercent = minimum;
        }
    }
    NSString *taskSuffix = @"";
    NSColor *taskColor = nil;
    NSUInteger waitingCount = self.taskSnapshot.waitingForApprovalTasks.count;
    NSUInteger completedCount = self.taskSnapshot.unreadCompletedTasks.count;
    NSUInteger runningCount = self.taskSnapshot.runningTasks.count;
    if (waitingCount > 0) {
        taskSuffix = [NSString stringWithFormat:@" · !%lu", (unsigned long)waitingCount];
        taskColor = CQTheme.menuBarYellow;
    } else if (completedCount > 0) {
        taskSuffix = [NSString stringWithFormat:@" · ✓%lu", (unsigned long)completedCount];
        taskColor = CQTheme.menuBarGreen;
    } else if (runningCount > 0) {
        taskSuffix = [NSString stringWithFormat:@" · ●%lu", (unsigned long)runningCount];
        taskColor = CQTheme.menuBarAccent;
    }
    NSString *baseTitle = nil;
    if (metric) {
        baseTitle = metric;
    } else if (self.connectionState == CQConnectionStateConnected
               || self.connectionState == CQConnectionStateError
               || self.connectionState == CQConnectionStateOffline
               || self.connectionState == CQConnectionStateSignedOut) {
        baseTitle = @"—";
    } else {
        baseTitle = @"…";
    }
    [self.statusView updateMetric:baseTitle remainingPercent:remainingPercent taskSuffix:taskSuffix taskColor:taskColor];
    self.statusView.running = runningCount > 0 && waitingCount == 0 && completedCount == 0;
    self.statusItem.length = self.statusView.preferredWidth + 12;
    self.statusView.frame = NSMakeRect(6, 0, self.statusView.preferredWidth, NSHeight(self.statusItem.button.bounds));
    self.statusItem.button.toolTip = [NSString stringWithFormat:
        @"Codex Quota\n待审核 %lu · 未查看完成 %lu · 运行中 %lu",
        (unsigned long)waitingCount,
        (unsigned long)completedCount,
        (unsigned long)runningCount];
    self.statusItem.button.accessibilityLabel = @"额度与任务状态";
    self.statusItem.button.accessibilityValue = [NSString stringWithFormat:@"%@；待审核 %lu，未查看完成 %lu，运行中 %lu",
        metric ?: [self statusText],
        (unsigned long)waitingCount,
        (unsigned long)completedCount,
        (unsigned long)runningCount];
    [self.popoverController renderSnapshot:self.snapshot
                              taskSnapshot:self.taskSnapshot
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
