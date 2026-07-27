#import "CQPopoverController.h"
#import "CQTheme.h"
#import <QuartzCore/QuartzCore.h>

@interface CQProgressView : NSView
@property(nonatomic) double progress;
- (void)setProgress:(double)progress color:(NSColor *)color animated:(BOOL)animated;
@end

@implementation CQProgressView {
    CALayer *_fillLayer;
}
- (BOOL)isFlipped { return YES; }
- (instancetype)init {
    self = [super initWithFrame:NSMakeRect(0, 0, 100, 6)];
    if (self) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = [CQTheme.surface colorWithAlphaComponent:0.8].CGColor;
        self.layer.cornerRadius = 3;
        self.layer.masksToBounds = YES;
        _fillLayer = [CALayer layer];
        _fillLayer.cornerRadius = 3;
        _fillLayer.anchorPoint = CGPointMake(0, 0.5);
        [self.layer addSublayer:_fillLayer];
        [self.heightAnchor constraintEqualToConstant:6].active = YES;
    }
    return self;
}
- (void)layout {
    [super layout];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _fillLayer.frame = NSMakeRect(0, 0, self.bounds.size.width * self.progress, self.bounds.size.height);
    [CATransaction commit];
}
- (void)setProgress:(double)progress color:(NSColor *)color animated:(BOOL)animated {
    progress = MAX(0, MIN(1, progress));
    _fillLayer.backgroundColor = color.CGColor;
    CGFloat width = self.bounds.size.width * progress;
    CGRect target = NSMakeRect(0, 0, width, self.bounds.size.height);
    BOOL reduceMotion = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    if (animated && !reduceMotion && self.window) {
        CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"bounds.size.width"];
        CALayer *presentation = (CALayer *)_fillLayer.presentationLayer;
        animation.fromValue = @(presentation ? presentation.bounds.size.width : _fillLayer.bounds.size.width);
        animation.toValue = @(width);
        animation.duration = 0.35;
        animation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [_fillLayer addAnimation:animation forKey:@"quota"];
    }
    self.progress = progress;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _fillLayer.frame = target;
    [CATransaction commit];
}
@end

static NSView *CQDivider(void) {
    NSView *view = [NSView new];
    view.wantsLayer = YES;
    view.layer.backgroundColor = [CQTheme.surface colorWithAlphaComponent:0.9].CGColor;
    [view.heightAnchor constraintEqualToConstant:1].active = YES;
    return view;
}

static NSStackView *CQHorizontal(void) {
    NSStackView *stack = [NSStackView new];
    stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    stack.alignment = NSLayoutAttributeCenterY;
    stack.spacing = 8;
    return stack;
}

@interface CQFlippedView : NSView
@end

@implementation CQFlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface CQQuotaRowView : NSStackView
@property(nonatomic, strong) NSTextField *nameLabel;
@property(nonatomic, strong) NSTextField *percentLabel;
@property(nonatomic, strong) NSTextField *resetLabel;
@property(nonatomic, strong) CQProgressView *progressView;
@property(nonatomic, strong, nullable) NSLayoutConstraint *stackWidthConstraint;
- (instancetype)initWithWindow:(CQRateLimitWindow *)window;
- (void)updateWithWindow:(CQRateLimitWindow *)window animated:(BOOL)animated;
@end

@implementation CQQuotaRowView

- (instancetype)initWithWindow:(CQRateLimitWindow *)window {
    self = [super init];
    if (!self) return nil;

    self.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.alignment = NSLayoutAttributeLeading;
    self.spacing = 6;

    NSStackView *line = CQHorizontal();
    self.nameLabel = CQLabel(@"", [NSFont systemFontOfSize:12 weight:NSFontWeightMedium], CQTheme.text);
    [line addArrangedSubview:self.nameLabel];
    NSView *spacer = [NSView new];
    [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow
                       forOrientation:NSLayoutConstraintOrientationHorizontal];
    [line addArrangedSubview:spacer];
    self.percentLabel = CQLabel(@"", [NSFont monospacedDigitSystemFontOfSize:15
                                                                     weight:NSFontWeightSemibold], CQTheme.accent);
    self.percentLabel.alignment = NSTextAlignmentRight;
    [line addArrangedSubview:self.percentLabel];
    [self addArrangedSubview:line];

    self.progressView = [CQProgressView new];
    [self addArrangedSubview:self.progressView];
    self.resetLabel = CQLabel(@"", [NSFont systemFontOfSize:10], CQTheme.overlay);
    [self addArrangedSubview:self.resetLabel];
    [line.widthAnchor constraintEqualToAnchor:self.widthAnchor].active = YES;
    [self.progressView.widthAnchor constraintEqualToAnchor:self.widthAnchor].active = YES;
    [self updateWithWindow:window animated:NO];
    return self;
}

- (void)updateWithWindow:(CQRateLimitWindow *)window animated:(BOOL)animated {
    NSColor *color = [CQTheme colorForRemaining:window.remainingPercent];
    self.nameLabel.stringValue = window.name;
    self.percentLabel.stringValue = [NSString stringWithFormat:@"%.0f%%", window.remainingPercent];
    self.percentLabel.textColor = color;
    self.resetLabel.stringValue = window.resetsAt
        ? [NSString stringWithFormat:@"%@ · %@",
           CQRelativeDateString(window.resetsAt), CQAbsoluteDateString(window.resetsAt)]
        : @"重置时间不可用";
    self.progressView.accessibilityLabel = [NSString stringWithFormat:@"%@剩余额度", window.name];
    self.progressView.accessibilityValue = [NSString stringWithFormat:@"%.0f%%", window.remainingPercent];
    [self.progressView setProgress:window.remainingPercent / 100.0 color:color animated:animated];
}

@end

@interface CQPopoverController ()
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSTextField *detailLabel;
@property(nonatomic, strong) NSTextField *planLabel;
@property(nonatomic, strong) NSStackView *contentStack;
@property(nonatomic, strong) NSStackView *quotaStack;
@property(nonatomic, strong) NSMutableDictionary<NSString *, CQQuotaRowView *> *quotaRows;
@property(nonatomic, strong, nullable) NSTextField *emptyQuotaLabel;
@property(nonatomic, strong) NSTextField *resetValueLabel;
@property(nonatomic, strong) NSStackView *workspaceRow;
@property(nonatomic, strong) NSTextField *workspaceValueLabel;
@property(nonatomic, strong) NSTextField *errorLabel;
@property(nonatomic, strong) NSTextField *updatedLabel;
@property(nonatomic, strong) NSButton *refreshButton;
@property(nonatomic, strong) NSButton *loginButton;
@property(nonatomic, strong) NSButton *launchCheckbox;
@end

@implementation CQPopoverController

- (void)loadView {
    NSView *root = [NSView new];
    root.wantsLayer = YES;
    root.layer.backgroundColor = CQTheme.base.CGColor;
    root.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    self.view = root;
    self.preferredContentSize = NSMakeSize(360, 390);

    NSScrollView *scroll = [NSScrollView new];
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:scroll];

    NSView *document = [CQFlippedView new];
    document.translatesAutoresizingMaskIntoConstraints = NO;
    document.wantsLayer = YES;
    document.layer.backgroundColor = NSColor.clearColor.CGColor;
    scroll.documentView = document;

    NSStackView *content = [NSStackView new];
    content.orientation = NSUserInterfaceLayoutOrientationVertical;
    content.alignment = NSLayoutAttributeLeading;
    content.spacing = 12;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [document addSubview:content];
    self.contentStack = content;
    self.quotaRows = [NSMutableDictionary dictionary];

    NSStackView *header = CQHorizontal();
    NSTextField *title = CQLabel(@"Codex Quota", [NSFont systemFontOfSize:18 weight:NSFontWeightSemibold], CQTheme.text);
    [header addArrangedSubview:title];
    NSView *spacer = [NSView new];
    [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [header addArrangedSubview:spacer];
    self.statusLabel = CQLabel(@"正在连接", [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold], CQTheme.yellow);
    self.statusLabel.alignment = NSTextAlignmentRight;
    [header addArrangedSubview:self.statusLabel];
    [content addArrangedSubview:header];

    NSStackView *subheader = CQHorizontal();
    self.detailLabel = CQLabel(@"正在查找 Codex…", [NSFont systemFontOfSize:12], CQTheme.subtext);
    self.planLabel = CQLabel(@"", [NSFont systemFontOfSize:11 weight:NSFontWeightMedium], CQTheme.lavender);
    [subheader addArrangedSubview:self.detailLabel];
    NSView *subSpacer = [NSView new];
    [subSpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [subheader addArrangedSubview:subSpacer];
    [subheader addArrangedSubview:self.planLabel];
    [content addArrangedSubview:subheader];
    [content addArrangedSubview:CQDivider()];

    NSTextField *quotaTitle = CQLabel(@"额度", [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold], CQTheme.subtext);
    [content addArrangedSubview:quotaTitle];
    self.quotaStack = [NSStackView new];
    self.quotaStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.quotaStack.alignment = NSLayoutAttributeLeading;
    self.quotaStack.spacing = 13;
    [content addArrangedSubview:self.quotaStack];

    [content addArrangedSubview:CQDivider()];
    NSStackView *resetRow = CQHorizontal();
    [resetRow addArrangedSubview:CQLabel(@"剩余重置次数", [NSFont systemFontOfSize:12], CQTheme.subtext)];
    NSView *resetSpacer = [NSView new];
    [resetSpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [resetRow addArrangedSubview:resetSpacer];
    self.resetValueLabel = CQLabel(@"不可用", [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightSemibold], CQTheme.text);
    [resetRow addArrangedSubview:self.resetValueLabel];
    [content addArrangedSubview:resetRow];

    self.workspaceRow = CQHorizontal();
    [self.workspaceRow addArrangedSubview:CQLabel(@"工作区额度", [NSFont systemFontOfSize:12], CQTheme.subtext)];
    NSView *workspaceSpacer = [NSView new];
    [workspaceSpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.workspaceRow addArrangedSubview:workspaceSpacer];
    self.workspaceValueLabel = CQLabel(@"", [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightSemibold], CQTheme.text);
    [self.workspaceRow addArrangedSubview:self.workspaceValueLabel];
    self.workspaceRow.hidden = YES;
    [content addArrangedSubview:self.workspaceRow];

    self.errorLabel = CQLabel(@"", [NSFont systemFontOfSize:11], CQTheme.red);
    self.errorLabel.maximumNumberOfLines = 3;
    self.errorLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.errorLabel.hidden = YES;
    [content addArrangedSubview:self.errorLabel];

    self.updatedLabel = CQLabel(@"尚未更新", [NSFont systemFontOfSize:10], CQTheme.overlay);
    [content addArrangedSubview:self.updatedLabel];

    NSView *footer = [NSView new];
    footer.translatesAutoresizingMaskIntoConstraints = NO;
    footer.wantsLayer = YES;
    footer.layer.backgroundColor = CQTheme.mantle.CGColor;
    [root addSubview:footer];

    NSStackView *footerStack = [NSStackView new];
    footerStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    footerStack.alignment = NSLayoutAttributeCenterX;
    footerStack.spacing = 7;
    footerStack.translatesAutoresizingMaskIntoConstraints = NO;
    [footer addSubview:footerStack];

    NSStackView *actions = CQHorizontal();
    self.refreshButton = CQButton(@"立即刷新", @"arrow.clockwise", self, @selector(refresh:));
    self.loginButton = CQButton(@"登录", @"person.crop.circle", self, @selector(login:));
    NSButton *choose = CQButton(@"选择 Codex", @"terminal", self, @selector(chooseCodex:));
    NSButton *quit = CQButton(@"退出", @"power", self, @selector(quit:));
    [actions addArrangedSubview:self.refreshButton];
    [actions addArrangedSubview:self.loginButton];
    [actions addArrangedSubview:choose];
    [actions addArrangedSubview:quit];
    [footerStack addArrangedSubview:actions];

    self.launchCheckbox = [NSButton checkboxWithTitle:@"登录时启动" target:self action:@selector(toggleLaunchAtLogin:)];
    self.launchCheckbox.attributedTitle = [[NSAttributedString alloc]
        initWithString:@"登录时启动"
            attributes:@{
                NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
                NSForegroundColorAttributeName: CQTheme.text
            }];
    self.launchCheckbox.contentTintColor = CQTheme.accent;
    [footerStack addArrangedSubview:self.launchCheckbox];

    [NSLayoutConstraint activateConstraints:@[
        [footer.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [footer.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [footer.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [footer.heightAnchor constraintEqualToConstant:76],
        [scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:root.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:footer.topAnchor],
        [document.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
        [document.trailingAnchor constraintEqualToAnchor:scroll.contentView.trailingAnchor],
        [document.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
        [document.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
        [content.leadingAnchor constraintEqualToAnchor:document.leadingAnchor constant:16],
        [content.trailingAnchor constraintEqualToAnchor:document.trailingAnchor constant:-16],
        [content.topAnchor constraintEqualToAnchor:document.topAnchor constant:16],
        [content.bottomAnchor constraintEqualToAnchor:document.bottomAnchor constant:-16],
        [header.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [subheader.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [self.quotaStack.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [resetRow.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [self.workspaceRow.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [self.errorLabel.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [footerStack.leadingAnchor constraintGreaterThanOrEqualToAnchor:footer.leadingAnchor constant:14],
        [footerStack.trailingAnchor constraintLessThanOrEqualToAnchor:footer.trailingAnchor constant:-14],
        [footerStack.centerXAnchor constraintEqualToAnchor:footer.centerXAnchor],
        [footerStack.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor]
    ]];
    for (NSView *view in content.arrangedSubviews) {
        if (view != self.quotaStack) [view.widthAnchor constraintEqualToAnchor:content.widthAnchor].active = YES;
    }
}

- (void)reconcileQuotaWindows:(NSArray<CQRateLimitWindow *> *)windows hasSnapshot:(BOOL)hasSnapshot {
    if (windows.count == 0) {
        for (CQQuotaRowView *row in self.quotaRows.allValues) {
            row.stackWidthConstraint.active = NO;
            row.stackWidthConstraint = nil;
            if ([self.quotaStack.arrangedSubviews containsObject:row]) {
                [self.quotaStack removeArrangedSubview:row];
            }
            if (row.superview) [row removeFromSuperview];
        }
        [self.quotaRows removeAllObjects];
        if (!self.emptyQuotaLabel) {
            self.emptyQuotaLabel = CQLabel(@"", [NSFont systemFontOfSize:12], CQTheme.overlay);
            [self.quotaStack addArrangedSubview:self.emptyQuotaLabel];
        }
        self.emptyQuotaLabel.stringValue = hasSnapshot ? @"服务未返回额度窗口" : @"等待额度数据…";
        return;
    }

    if (self.emptyQuotaLabel) {
        if ([self.quotaStack.arrangedSubviews containsObject:self.emptyQuotaLabel]) {
            [self.quotaStack removeArrangedSubview:self.emptyQuotaLabel];
        }
        if (self.emptyQuotaLabel.superview) [self.emptyQuotaLabel removeFromSuperview];
        self.emptyQuotaLabel = nil;
    }

    NSMutableArray<CQQuotaRowView *> *desiredRows = [NSMutableArray arrayWithCapacity:windows.count];
    NSMutableSet<NSString *> *desiredKeys = [NSMutableSet setWithCapacity:windows.count];
    for (CQRateLimitWindow *window in windows) {
        NSString *key = window.limitID;
        [desiredKeys addObject:key];
        CQQuotaRowView *row = self.quotaRows[key];
        if (row) {
            [row updateWithWindow:window animated:YES];
        } else {
            row = [[CQQuotaRowView alloc] initWithWindow:window];
            self.quotaRows[key] = row;
        }
        [desiredRows addObject:row];
    }

    for (NSString *key in self.quotaRows.allKeys.copy) {
        if ([desiredKeys containsObject:key]) continue;
        CQQuotaRowView *row = self.quotaRows[key];
        row.stackWidthConstraint.active = NO;
        row.stackWidthConstraint = nil;
        if ([self.quotaStack.arrangedSubviews containsObject:row]) {
            [self.quotaStack removeArrangedSubview:row];
        }
        if (row.superview) [row removeFromSuperview];
        [self.quotaRows removeObjectForKey:key];
    }

    if (![self.quotaStack.arrangedSubviews isEqualToArray:desiredRows]) {
        for (NSView *view in self.quotaStack.arrangedSubviews.copy) {
            if ([view isKindOfClass:CQQuotaRowView.class]) {
                CQQuotaRowView *row = (CQQuotaRowView *)view;
                row.stackWidthConstraint.active = NO;
                row.stackWidthConstraint = nil;
            }
            [self.quotaStack removeArrangedSubview:view];
            [view removeFromSuperview];
        }
        for (CQQuotaRowView *row in desiredRows) {
            [self.quotaStack addArrangedSubview:row];
            row.stackWidthConstraint = [row.widthAnchor constraintEqualToAnchor:self.quotaStack.widthAnchor];
            row.stackWidthConstraint.active = YES;
        }
    }
}

- (void)renderSnapshot:(CQQuotaSnapshot *)snapshot
                status:(NSString *)status
                detail:(NSString *)detail
                 error:(NSString *)error
            refreshing:(BOOL)refreshing
             signedOut:(BOOL)signedOut
         launchAtLogin:(BOOL)launchAtLogin {
    self.statusLabel.stringValue = status;
    self.statusLabel.textColor = [status isEqualToString:@"已连接"] ? CQTheme.accent
        : ([status isEqualToString:@"需要登录"] || [status isEqualToString:@"已断开"] ? CQTheme.red : CQTheme.yellow);
    self.detailLabel.stringValue = detail;
    self.planLabel.stringValue = snapshot.planType.uppercaseString ?: @"";
    self.refreshButton.enabled = !refreshing;
    self.refreshButton.title = refreshing ? @"刷新中…" : @"立即刷新";
    self.loginButton.hidden = !signedOut;
    self.launchCheckbox.state = launchAtLogin ? NSControlStateValueOn : NSControlStateValueOff;

    [self reconcileQuotaWindows:snapshot.windows ?: @[] hasSnapshot:snapshot != nil];

    self.resetValueLabel.stringValue = snapshot.resetCreditsAvailable
        ? [NSString stringWithFormat:@"%@ 次", snapshot.resetCreditsAvailable] : @"不可用";
    self.workspaceRow.hidden = !snapshot.hasWorkspaceCredits;
    if (snapshot.hasWorkspaceCredits) {
        self.workspaceValueLabel.stringValue = snapshot.workspaceUnlimited
            ? @"无限" : (snapshot.workspaceBalance ?: @"不可用");
    }
    self.errorLabel.hidden = error.length == 0;
    self.errorLabel.stringValue = error ?: @"";
    self.updatedLabel.stringValue = snapshot
        ? [NSString stringWithFormat:@"最后更新：%@", CQAbsoluteDateString(snapshot.updatedAt)]
        : @"尚未更新";

    [self.view layoutSubtreeIfNeeded];
    CGFloat contentHeight = self.contentStack.fittingSize.height;
    CGFloat desiredHeight = MIN(500, MAX(340, ceil(contentHeight + 32 + 76)));
    self.preferredContentSize = NSMakeSize(360, desiredHeight);
}

- (void)refresh:(id)sender { if (self.refreshHandler) self.refreshHandler(); }
- (void)login:(id)sender { if (self.loginHandler) self.loginHandler(); }
- (void)chooseCodex:(id)sender { if (self.chooseCodexHandler) self.chooseCodexHandler(); }
- (void)toggleLaunchAtLogin:(NSButton *)sender {
    if (self.launchAtLoginHandler) self.launchAtLoginHandler(sender.state == NSControlStateValueOn);
}
- (void)quit:(id)sender { if (self.quitHandler) self.quitHandler(); }

@end
