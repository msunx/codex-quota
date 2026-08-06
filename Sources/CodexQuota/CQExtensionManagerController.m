#import "CQExtensionManagerController.h"
#import "CQModels.h"
#import "CQTheme.h"
#import <QuartzCore/QuartzCore.h>

static NSView *CQExtensionDivider(void) {
    NSView *view = [NSView new];
    view.wantsLayer = YES;
    view.layer.backgroundColor = [CQTheme.surface colorWithAlphaComponent:0.9].CGColor;
    [view.heightAnchor constraintEqualToConstant:1].active = YES;
    return view;
}

static NSStackView *CQExtensionHorizontal(void) {
    NSStackView *stack = [NSStackView new];
    stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    stack.alignment = NSLayoutAttributeCenterY;
    stack.spacing = 8;
    return stack;
}

@interface CQExtensionsFlippedView : NSView
@end

@implementation CQExtensionsFlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface CQExtensionRowView : NSStackView
@property(nonatomic, strong) CQExtensionItem *item;
@property(nonatomic, copy) void (^updateHandler)(CQExtensionItem *item);
@property(nonatomic, copy) void (^openFolderHandler)(CQExtensionItem *item);
@property(nonatomic, copy) void (^uninstallHandler)(CQExtensionItem *item);
@property(nonatomic, strong) NSTextField *nameLabel;
@property(nonatomic, strong) NSTextField *kindLabel;
@property(nonatomic, strong) NSTextField *metaLabel;
@property(nonatomic, strong) NSTextField *descriptionLabel;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSTextField *errorLabel;
@property(nonatomic, strong) NSButton *updateButton;
@property(nonatomic, strong) NSButton *openFolderButton;
@property(nonatomic, strong) NSButton *uninstallButton;
- (instancetype)initWithItem:(CQExtensionItem *)item;
- (void)render;
@end

@implementation CQExtensionRowView

- (instancetype)initWithItem:(CQExtensionItem *)item {
    self = [super init];
    if (!self) return nil;
    self.item = item;
    self.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.alignment = NSLayoutAttributeLeading;
    self.spacing = 5;
    self.edgeInsets = NSEdgeInsetsMake(3, 0, 4, 0);

    NSStackView *titleRow = CQExtensionHorizontal();
    self.nameLabel = CQLabel(@"", [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], CQTheme.text);
    [self.nameLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                            forOrientation:NSLayoutConstraintOrientationHorizontal];
    [titleRow addArrangedSubview:self.nameLabel];
    self.kindLabel = CQLabel(@"", [NSFont systemFontOfSize:9 weight:NSFontWeightBold], CQTheme.lavender);
    [titleRow addArrangedSubview:self.kindLabel];
    NSView *spacer = [NSView new];
    [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [titleRow addArrangedSubview:spacer];
    self.updateButton = CQButton(@"更新", @"arrow.down.circle", self, @selector(update:));
    [self.updateButton.widthAnchor constraintGreaterThanOrEqualToConstant:64].active = YES;
    [titleRow addArrangedSubview:self.updateButton];
    self.uninstallButton = CQButton(@"卸载", @"trash", self, @selector(uninstall:));
    self.uninstallButton.contentTintColor = CQTheme.red;
    [self.uninstallButton.widthAnchor constraintGreaterThanOrEqualToConstant:56].active = YES;
    [titleRow addArrangedSubview:self.uninstallButton];
    [self addArrangedSubview:titleRow];

    NSStackView *metaRow = CQExtensionHorizontal();
    self.metaLabel = CQLabel(@"", [NSFont systemFontOfSize:10], CQTheme.subtext);
    self.metaLabel.maximumNumberOfLines = 1;
    self.metaLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.metaLabel.usesSingleLineMode = YES;
    [self.metaLabel setContentHuggingPriority:NSLayoutPriorityDefaultLow
                               forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.metaLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                              forOrientation:NSLayoutConstraintOrientationHorizontal];
    [metaRow addArrangedSubview:self.metaLabel];
    self.openFolderButton = CQButton(@"", @"folder", self, @selector(openFolder:));
    self.openFolderButton.imagePosition = NSImageOnly;
    self.openFolderButton.toolTip = @"在 Finder 中打开安装目录";
    [self.openFolderButton.widthAnchor constraintEqualToConstant:30].active = YES;
    [metaRow addArrangedSubview:self.openFolderButton];
    [self addArrangedSubview:metaRow];

    self.descriptionLabel = CQLabel(@"", [NSFont systemFontOfSize:11], CQTheme.subtext);
    self.descriptionLabel.maximumNumberOfLines = 1;
    self.descriptionLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.descriptionLabel.usesSingleLineMode = YES;
    [self.descriptionLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                                     forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self addArrangedSubview:self.descriptionLabel];

    self.statusLabel = CQLabel(@"", [NSFont systemFontOfSize:10 weight:NSFontWeightMedium], CQTheme.overlay);
    [self.statusLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                                forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self addArrangedSubview:self.statusLabel];

    self.errorLabel = CQLabel(@"", [NSFont systemFontOfSize:10], CQTheme.red);
    self.errorLabel.maximumNumberOfLines = 2;
    self.errorLabel.lineBreakMode = NSLineBreakByWordWrapping;
    [self.errorLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                               forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.errorLabel.hidden = YES;
    [self addArrangedSubview:self.errorLabel];

    [titleRow.widthAnchor constraintEqualToAnchor:self.widthAnchor].active = YES;
    [metaRow.widthAnchor constraintEqualToAnchor:self.widthAnchor].active = YES;
    [self.descriptionLabel.widthAnchor constraintEqualToAnchor:self.widthAnchor].active = YES;
    [self.statusLabel.widthAnchor constraintEqualToAnchor:self.widthAnchor].active = YES;
    [self.errorLabel.widthAnchor constraintEqualToAnchor:self.widthAnchor].active = YES;
    [self render];
    return self;
}

- (NSString *)versionText {
    NSString *installed = self.item.installedVersion;
    NSString *available = self.item.availableVersion;
    if (self.item.updateAvailable && installed.length > 0 && available.length > 0) {
        return [NSString stringWithFormat:@"%@ → %@", installed, available];
    }
    if (installed.length > 0) return installed;
    if (available.length > 0) return available;
    return nil;
}

- (void)render {
    self.nameLabel.stringValue = self.item.displayName ?: self.item.name;
    self.nameLabel.toolTip = self.item.name;
    self.kindLabel.stringValue = self.item.larkCLIManaged
        ? @"SKILL 套件" : (self.item.kind == CQExtensionKindSkill ? @"SKILL" : @"PLUGIN");
    NSString *version = [self versionText];
    self.metaLabel.stringValue = version.length > 0
        ? [NSString stringWithFormat:@"%@ · %@ · %@", self.item.sourceName, self.item.scopeDetail, version]
        : [NSString stringWithFormat:@"%@ · %@", self.item.sourceName, self.item.scopeDetail];
    self.metaLabel.toolTip = self.item.larkCLIManaged
        ? self.item.skillSource
        : (self.item.paths.count > 0 ? [self.item.paths componentsJoinedByString:@"\n"] : self.item.sourceName);
    self.descriptionLabel.hidden = self.item.summaryText.length == 0;
    self.descriptionLabel.stringValue = self.item.summaryText ?: @"";
    self.descriptionLabel.toolTip = self.item.summaryText;

    self.updateButton.hidden = NO;
    self.updateButton.enabled = NO;
    self.errorLabel.hidden = YES;
    self.errorLabel.stringValue = @"";
    switch (self.item.updateState) {
        case CQExtensionUpdateStateUnknown:
            self.updateButton.image = [NSImage imageWithSystemSymbolName:@"questionmark.circle" accessibilityDescription:nil];
            self.statusLabel.stringValue = @"等待检查更新";
            self.statusLabel.textColor = CQTheme.overlay;
            self.updateButton.title = @"待检查";
            break;
        case CQExtensionUpdateStateChecking:
            self.updateButton.image = [NSImage imageWithSystemSymbolName:@"arrow.clockwise" accessibilityDescription:nil];
            self.statusLabel.stringValue = @"正在检查上游版本…";
            self.statusLabel.textColor = CQTheme.yellow;
            self.updateButton.title = @"检查中…";
            break;
        case CQExtensionUpdateStateUpToDate:
            self.updateButton.image = [NSImage imageWithSystemSymbolName:@"checkmark.circle" accessibilityDescription:nil];
            self.statusLabel.stringValue = @"已是最新版本";
            self.statusLabel.textColor = CQTheme.accent;
            self.updateButton.title = @"已最新";
            break;
        case CQExtensionUpdateStateUpdateAvailable:
            self.updateButton.image = [NSImage imageWithSystemSymbolName:@"arrow.down.circle" accessibilityDescription:nil];
            self.statusLabel.stringValue = @"发现新版本，可直接更新";
            self.statusLabel.textColor = CQTheme.yellow;
            self.updateButton.title = @"更新";
            self.updateButton.enabled = YES;
            self.updateButton.contentTintColor = CQTheme.accent;
            break;
        case CQExtensionUpdateStateUntracked:
            self.updateButton.image = [NSImage imageWithSystemSymbolName:@"hammer" accessibilityDescription:nil];
            self.statusLabel.stringValue = @"本地维护 · 未声明可追踪的更新源";
            self.statusLabel.textColor = CQTheme.overlay;
            self.updateButton.title = @"本地";
            break;
        case CQExtensionUpdateStateUpdating:
            self.updateButton.image = [NSImage imageWithSystemSymbolName:@"arrow.down.circle.dottedline" accessibilityDescription:nil];
            self.statusLabel.stringValue = @"正在下载并应用更新…";
            self.statusLabel.textColor = CQTheme.yellow;
            self.updateButton.title = @"更新中…";
            break;
        case CQExtensionUpdateStateFailed:
            self.updateButton.image = [NSImage imageWithSystemSymbolName:@"exclamationmark.triangle" accessibilityDescription:nil];
            self.statusLabel.stringValue = @"更新检查或安装失败";
            self.statusLabel.textColor = CQTheme.red;
            self.updateButton.title = @"失败";
            self.errorLabel.stringValue = self.item.errorMessage ?: @"请稍后重新检查";
            self.errorLabel.hidden = NO;
            break;
    }
    self.updateButton.accessibilityLabel = [NSString stringWithFormat:@"%@：%@",
        self.item.displayName, self.statusLabel.stringValue];
    self.openFolderButton.hidden = self.item.kind != CQExtensionKindSkill;
    self.openFolderButton.enabled = self.item.kind == CQExtensionKindSkill && self.item.paths.count > 0;
    self.openFolderButton.toolTip = self.item.larkCLIManaged
        ? @"在 Finder 中显示整组 Skill 目录" : @"在 Finder 中打开安装目录";
    self.openFolderButton.accessibilityLabel = [NSString stringWithFormat:@"打开 %@ 的安装目录",
        self.item.displayName];
    self.uninstallButton.hidden = self.item.kind != CQExtensionKindSkill;
    self.uninstallButton.enabled = self.item.kind == CQExtensionKindSkill;
    self.uninstallButton.accessibilityLabel = [NSString stringWithFormat:@"卸载 %@", self.item.displayName];
}

- (void)update:(id)sender {
    (void)sender;
    if (self.updateHandler) self.updateHandler(self.item);
}

- (void)openFolder:(id)sender {
    (void)sender;
    if (self.openFolderHandler) self.openFolderHandler(self.item);
}

- (void)uninstall:(id)sender {
    (void)sender;
    if (self.uninstallHandler) self.uninstallHandler(self.item);
}

@end

@interface CQExtensionManagerController ()
@property(nonatomic, strong) CQExtensionManager *manager;
@property(nonatomic, strong) NSTextField *summaryLabel;
@property(nonatomic, strong) NSTextField *updatedLabel;
@property(nonatomic, strong) NSTextField *errorLabel;
@property(nonatomic, strong) NSSegmentedControl *filterControl;
@property(nonatomic, strong) NSStackView *listStack;
@property(nonatomic, strong) NSButton *checkButton;
- (void)confirmUninstallItem:(CQExtensionItem *)item;
- (void)openInstallationDirectoriesForItem:(CQExtensionItem *)item;
@end

@implementation CQExtensionManagerController

- (instancetype)initWithManager:(CQExtensionManager *)manager {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;
    _manager = manager;
    __weak typeof(self) weakSelf = self;
    _manager.changeHandler = ^{ [weakSelf render]; };
    return self;
}

- (void)loadView {
    NSView *root = [NSView new];
    root.wantsLayer = YES;
    root.layer.backgroundColor = CQTheme.base.CGColor;
    root.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    self.view = root;
    self.preferredContentSize = NSMakeSize(360, 500);

    NSStackView *header = CQExtensionHorizontal();
    header.translatesAutoresizingMaskIntoConstraints = NO;
    NSButton *back = CQButton(@"返回", @"chevron.left", self, @selector(back:));
    [header addArrangedSubview:back];
    NSTextField *title = CQLabel(@"扩展管理", [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold], CQTheme.text);
    [header addArrangedSubview:title];
    NSView *headerSpacer = [NSView new];
    [headerSpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [header addArrangedSubview:headerSpacer];
    [root addSubview:header];

    self.summaryLabel = CQLabel(@"正在读取已安装扩展…", [NSFont systemFontOfSize:11], CQTheme.subtext);
    self.summaryLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.summaryLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                                 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [root addSubview:self.summaryLabel];

    self.filterControl = [NSSegmentedControl segmentedControlWithLabels:@[@"全部", @"Skill", @"插件"]
                                                            trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                  target:self
                                                                  action:@selector(filterChanged:)];
    self.filterControl.segmentStyle = NSSegmentStyleRounded;
    self.filterControl.selectedSegment = 0;
    self.filterControl.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:self.filterControl];

    NSScrollView *scroll = [NSScrollView new];
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:scroll];

    CQExtensionsFlippedView *document = [CQExtensionsFlippedView new];
    document.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.documentView = document;
    self.listStack = [NSStackView new];
    self.listStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.listStack.alignment = NSLayoutAttributeLeading;
    self.listStack.spacing = 8;
    self.listStack.translatesAutoresizingMaskIntoConstraints = NO;
    [document addSubview:self.listStack];

    NSView *footer = [NSView new];
    footer.translatesAutoresizingMaskIntoConstraints = NO;
    footer.wantsLayer = YES;
    footer.layer.backgroundColor = CQTheme.mantle.CGColor;
    [root addSubview:footer];
    NSStackView *footerStack = [NSStackView new];
    footerStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    footerStack.alignment = NSLayoutAttributeCenterY;
    footerStack.spacing = 8;
    footerStack.translatesAutoresizingMaskIntoConstraints = NO;
    [footer addSubview:footerStack];
    self.updatedLabel = CQLabel(@"尚未检查更新", [NSFont systemFontOfSize:10], CQTheme.overlay);
    [footerStack addArrangedSubview:self.updatedLabel];
    NSView *footerSpacer = [NSView new];
    [footerSpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [footerStack addArrangedSubview:footerSpacer];
    self.checkButton = CQButton(@"检查更新", @"arrow.clockwise", self, @selector(check:));
    [footerStack addArrangedSubview:self.checkButton];

    self.errorLabel = CQLabel(@"", [NSFont systemFontOfSize:10], CQTheme.red);
    self.errorLabel.maximumNumberOfLines = 2;
    self.errorLabel.lineBreakMode = NSLineBreakByWordWrapping;
    [self.errorLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                               forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.errorLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.errorLabel.hidden = YES;
    [root addSubview:self.errorLabel];

    [NSLayoutConstraint activateConstraints:@[
        [header.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:14],
        [header.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-14],
        [header.topAnchor constraintEqualToAnchor:root.topAnchor constant:14],
        [self.summaryLabel.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:16],
        [self.summaryLabel.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-16],
        [self.summaryLabel.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:8],
        [self.filterControl.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:16],
        [self.filterControl.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-16],
        [self.filterControl.topAnchor constraintEqualToAnchor:self.summaryLabel.bottomAnchor constant:10],
        [self.errorLabel.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:16],
        [self.errorLabel.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-16],
        [self.errorLabel.topAnchor constraintEqualToAnchor:self.filterControl.bottomAnchor constant:6],
        [scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.errorLabel.bottomAnchor constant:6],
        [scroll.bottomAnchor constraintEqualToAnchor:footer.topAnchor],
        [document.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
        [document.trailingAnchor constraintEqualToAnchor:scroll.contentView.trailingAnchor],
        [document.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
        [document.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
        [self.listStack.leadingAnchor constraintEqualToAnchor:document.leadingAnchor constant:16],
        [self.listStack.trailingAnchor constraintEqualToAnchor:document.trailingAnchor constant:-16],
        [self.listStack.topAnchor constraintEqualToAnchor:document.topAnchor constant:8],
        [self.listStack.bottomAnchor constraintEqualToAnchor:document.bottomAnchor constant:-14],
        [footer.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [footer.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [footer.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [footer.heightAnchor constraintEqualToConstant:56],
        [footerStack.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor constant:16],
        [footerStack.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor constant:-16],
        [footerStack.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor]
    ]];
    [self render];
}

- (void)viewWillAppear {
    [super viewWillAppear];
    if (self.manager.items.count == 0 && !self.manager.checking) [self.manager loadInstalledExtensions];
    else [self render];
}

- (NSArray<CQExtensionItem *> *)filteredItems {
    NSInteger filter = self.filterControl.selectedSegment;
    if (filter == 0) return self.manager.items;
    CQExtensionKind kind = filter == 1 ? CQExtensionKindSkill : CQExtensionKindPlugin;
    return [self.manager.items filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(CQExtensionItem *item, NSDictionary *bindings) {
        (void)bindings;
        return item.kind == kind;
    }]];
}

- (void)render {
    if (!self.isViewLoaded) return;
    NSUInteger updateCount = 0;
    NSUInteger failedCount = 0;
    NSUInteger unknownCount = 0;
    for (CQExtensionItem *item in self.manager.items) {
        if (item.updateAvailable) updateCount++;
        else if (item.updateState == CQExtensionUpdateStateFailed) failedCount++;
        else if (item.updateState == CQExtensionUpdateStateUnknown) unknownCount++;
    }
    BOOL hasGlobalError = self.manager.lastError.length > 0;
    if (self.manager.uninstalling) {
        self.summaryLabel.stringValue = @"正在彻底卸载 Skill…";
        self.summaryLabel.textColor = CQTheme.yellow;
    } else if (self.manager.updating) {
        self.summaryLabel.stringValue = @"正在更新扩展，请稍候…";
        self.summaryLabel.textColor = CQTheme.yellow;
    } else if (self.manager.checking) {
        self.summaryLabel.stringValue = @"正在检查第三方与自建扩展…";
        self.summaryLabel.textColor = CQTheme.yellow;
    } else if (updateCount > 0) {
        self.summaryLabel.stringValue = (failedCount > 0 || hasGlobalError)
            ? [NSString stringWithFormat:@"已安装 %lu 项 · %lu 可更新 · 部分失败",
                (unsigned long)self.manager.items.count, (unsigned long)updateCount]
            : [NSString stringWithFormat:@"已安装 %lu 项 · %lu 项可更新",
                (unsigned long)self.manager.items.count, (unsigned long)updateCount];
        self.summaryLabel.textColor = CQTheme.yellow;
    } else if (failedCount > 0 || hasGlobalError) {
        self.summaryLabel.stringValue = failedCount > 0
            ? [NSString stringWithFormat:@"已安装 %lu 项 · %lu 项检查失败",
                (unsigned long)self.manager.items.count, (unsigned long)failedCount]
            : [NSString stringWithFormat:@"已安装 %lu 项 · 部分检查失败",
                (unsigned long)self.manager.items.count];
        self.summaryLabel.textColor = CQTheme.red;
    } else if (!self.manager.updatedAt || unknownCount > 0) {
        self.summaryLabel.stringValue = [NSString stringWithFormat:@"已安装 %lu 项 · %lu 项待检查",
            (unsigned long)self.manager.items.count, (unsigned long)unknownCount];
        if (unknownCount == 0) self.summaryLabel.stringValue = [NSString stringWithFormat:@"已安装 %lu 项 · 尚未检查更新",
            (unsigned long)self.manager.items.count];
        self.summaryLabel.textColor = CQTheme.subtext;
    } else {
        self.summaryLabel.stringValue = [NSString stringWithFormat:@"已安装 %lu 项 · 暂无可用更新",
            (unsigned long)self.manager.items.count];
        self.summaryLabel.textColor = CQTheme.subtext;
    }
    self.errorLabel.hidden = self.manager.lastError.length == 0;
    self.errorLabel.stringValue = self.manager.lastError ?: @"";
    self.updatedLabel.stringValue = self.manager.updatedAt
        ? [NSString stringWithFormat:@"%@ · %@",
            (failedCount > 0 || hasGlobalError) ? @"上次尝试" : @"自动检查",
            CQRelativeDateString(self.manager.updatedAt)]
        : @"每 6 小时自动检查";
    self.checkButton.enabled = !self.manager.checking && !self.manager.updating && !self.manager.uninstalling;
    self.checkButton.title = self.manager.uninstalling
        ? @"卸载进行中" : (self.manager.updating
            ? @"更新进行中" : (self.manager.checking ? @"检查中…" : @"检查更新"));

    for (NSView *view in self.listStack.arrangedSubviews.copy) {
        [self.listStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    NSArray<CQExtensionItem *> *filtered = [self filteredItems];
    if (filtered.count == 0) {
        NSTextField *empty = CQLabel(self.manager.checking ? @"正在读取扩展列表…" : @"没有符合条件的扩展",
            [NSFont systemFontOfSize:12], CQTheme.overlay);
        [self.listStack addArrangedSubview:empty];
        [empty.widthAnchor constraintEqualToAnchor:self.listStack.widthAnchor].active = YES;
        return;
    }

    NSArray<NSNumber *> *kinds = self.filterControl.selectedSegment == 0
        ? @[@(CQExtensionKindSkill), @(CQExtensionKindPlugin)]
        : @[@(self.filterControl.selectedSegment == 1 ? CQExtensionKindSkill : CQExtensionKindPlugin)];
    __weak typeof(self) weakSelf = self;
    for (NSNumber *kindNumber in kinds) {
        CQExtensionKind kind = kindNumber.integerValue;
        NSArray<CQExtensionItem *> *sectionItems = [filtered filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(CQExtensionItem *item, NSDictionary *bindings) {
            (void)bindings;
            return item.kind == kind;
        }]];
        if (sectionItems.count == 0) continue;
        NSString *title = kind == CQExtensionKindSkill ? @"Skill" : @"插件";
        NSTextField *section = CQLabel([NSString stringWithFormat:@"%@  %lu", title, (unsigned long)sectionItems.count],
            [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold], CQTheme.lavender);
        [self.listStack addArrangedSubview:section];
        [section.widthAnchor constraintEqualToAnchor:self.listStack.widthAnchor].active = YES;
        for (CQExtensionItem *item in sectionItems) {
            CQExtensionRowView *row = [[CQExtensionRowView alloc] initWithItem:item];
            row.updateHandler = ^(CQExtensionItem *selected) { [weakSelf.manager updateItem:selected]; };
            row.openFolderHandler = ^(CQExtensionItem *selected) {
                [weakSelf openInstallationDirectoriesForItem:selected];
            };
            row.uninstallHandler = ^(CQExtensionItem *selected) { [weakSelf confirmUninstallItem:selected]; };
            if (self.manager.checking || self.manager.updating || self.manager.uninstalling) {
                row.updateButton.enabled = NO;
                row.uninstallButton.enabled = NO;
            }
            if (self.manager.updating || self.manager.uninstalling) row.openFolderButton.enabled = NO;
            [self.listStack addArrangedSubview:row];
            [row.widthAnchor constraintEqualToAnchor:self.listStack.widthAnchor].active = YES;
            NSView *divider = CQExtensionDivider();
            [self.listStack addArrangedSubview:divider];
            [divider.widthAnchor constraintEqualToAnchor:self.listStack.widthAnchor].active = YES;
        }
    }
}

- (void)openInstallationDirectoriesForItem:(CQExtensionItem *)item {
    if (!item || item.kind != CQExtensionKindSkill) return;
    NSMutableOrderedSet<NSURL *> *directoryURLs = [NSMutableOrderedSet orderedSet];
    for (NSString *path in item.paths) {
        NSString *normalized = path.stringByStandardizingPath;
        NSString *directory = [normalized.lastPathComponent caseInsensitiveCompare:@"SKILL.md"] == NSOrderedSame
            ? normalized.stringByDeletingLastPathComponent : normalized;
        BOOL isDirectory = NO;
        if ([NSFileManager.defaultManager fileExistsAtPath:directory isDirectory:&isDirectory] && isDirectory) {
            [directoryURLs addObject:[NSURL fileURLWithPath:directory isDirectory:YES]];
        }
    }
    if (directoryURLs.count == 0) {
        NSAlert *alert = [NSAlert new];
        alert.alertStyle = NSAlertStyleWarning;
        alert.messageText = @"没有找到 Skill 安装目录";
        alert.informativeText = @"目录可能已被移动或删除。请刷新扩展列表后重试。";
        [alert addButtonWithTitle:@"知道了"];
        [alert runModal];
        return;
    }
    if (directoryURLs.count == 1) {
        if (![NSWorkspace.sharedWorkspace openURL:directoryURLs.firstObject]) {
            NSAlert *alert = [NSAlert new];
            alert.alertStyle = NSAlertStyleWarning;
            alert.messageText = @"无法打开 Skill 安装目录";
            alert.informativeText = @"请确认 Finder 可用，并检查目录访问权限。";
            [alert addButtonWithTitle:@"知道了"];
            [alert runModal];
        }
        return;
    }
    [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:directoryURLs.array];
}

- (void)confirmUninstallItem:(CQExtensionItem *)item {
    if (!item || item.kind != CQExtensionKindSkill) return;
    NSAlert *alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleCritical;
    alert.messageText = [NSString stringWithFormat:@"彻底卸载“%@”？", item.displayName];
    if (item.larkCLIManaged) {
        alert.informativeText = [NSString stringWithFormat:
            @"将删除套件中的 %lu 个飞书 Skill、所有安装位置及对应安装记录。lark-cli 程序会保留。此操作不可撤销。",
            (unsigned long)item.groupedSkillCount];
    } else if (item.paths.count > 1) {
        alert.informativeText = [NSString stringWithFormat:
            @"将删除这个 Skill 的全部 %lu 个安装位置及对应安装记录。此操作不可撤销。",
            (unsigned long)item.paths.count];
    } else {
        alert.informativeText = @"将删除这个 Skill 的完整目录及对应安装记录。此操作不可撤销。";
    }
    [alert addButtonWithTitle:@"彻底卸载"];
    [alert addButtonWithTitle:@"取消"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    __weak typeof(self) weakSelf = self;
    [self.manager uninstallItem:item completion:^(NSError *error) {
        if (!error) return;
        BOOL cleanupWarning = [error.domain isEqualToString:@"com.muyang.codexquota.extensions"]
            && (error.code == 26 || error.code == 27);
        NSAlert *failure = [NSAlert new];
        failure.alertStyle = NSAlertStyleWarning;
        failure.messageText = cleanupWarning
            ? @"卸载已完成，但检测到清理异常" : @"未能完整卸载 Skill";
        failure.informativeText = error.localizedDescription ?: @"请检查目录权限后重试";
        [failure addButtonWithTitle:@"知道了"];
        [failure runModal];
        [weakSelf render];
    }];
}

- (void)back:(id)sender {
    (void)sender;
    if (self.backHandler) self.backHandler();
}

- (void)check:(id)sender {
    (void)sender;
    [self.manager checkForUpdates];
}

- (void)filterChanged:(id)sender {
    (void)sender;
    [self render];
}

@end
