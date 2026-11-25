#import "CQPopoverController.h"
#import "CQTheme.h"
#import <QuartzCore/QuartzCore.h>

static CGFloat const CQMainPanelMinimumHeight = 340.0;

@interface CQProgressView : NSView
@property(nonatomic) double progress;
- (void)setProgress:(double)progress color:(NSColor *)color animated:(BOOL)animated;
@end

@implementation CQProgressView {
    CALayer *_fillLayer;
}

- (instancetype)init {
    self = [super initWithFrame:NSMakeRect(0, 0, 100, 4)];
    if (self) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = CQTheme.surface.CGColor;
        self.layer.cornerRadius = 2;
        self.layer.masksToBounds = YES;
        _fillLayer = [CALayer layer];
        _fillLayer.anchorPoint = CGPointMake(0, 0.5);
        _fillLayer.cornerRadius = 2;
        [self.layer addSublayer:_fillLayer];
        [self.heightAnchor constraintEqualToConstant:4].active = YES;
        self.accessibilityElement = YES;
        self.accessibilityRole = NSAccessibilityProgressIndicatorRole;
    }
    return self;
}

- (void)layout {
    [super layout];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _fillLayer.position = CGPointMake(0, NSHeight(self.bounds) / 2);
    _fillLayer.bounds = CGRectMake(0, 0, NSWidth(self.bounds) * self.progress, NSHeight(self.bounds));
    [CATransaction commit];
}

- (void)setProgress:(double)progress color:(NSColor *)color animated:(BOOL)animated {
    progress = MAX(0, MIN(1, progress));
    CGFloat previousWidth = (_fillLayer.presentationLayer ?: _fillLayer).bounds.size.width;
    BOOL changed = fabs(self.progress - progress) > 0.0001;
    self.progress = progress;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _fillLayer.backgroundColor = color.CGColor;
    [CATransaction commit];
    [self setNeedsLayout:YES];
    [self layoutSubtreeIfNeeded];
    if (changed && animated && self.window && !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) {
        CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"bounds.size.width"];
        animation.fromValue = @(previousWidth);
        animation.toValue = @(NSWidth(self.bounds) * progress);
        animation.duration = 0.24;
        animation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [_fillLayer addAnimation:animation forKey:@"quota"];
    }
}
@end

static NSView *CQDivider(void) {
    NSView *view = [NSView new];
    view.wantsLayer = YES;
    view.layer.backgroundColor = (NSWorkspace.sharedWorkspace.accessibilityDisplayShouldIncreaseContrast ? CQTheme.overlay : CQTheme.surface).CGColor;
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
- (void)animateEntranceWithDelay:(NSTimeInterval)delay;
@end

@implementation CQQuotaRowView

- (instancetype)initWithWindow:(CQRateLimitWindow *)window {
    self = [super init];
    if (!self) return nil;

    self.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.alignment = NSLayoutAttributeLeading;
    self.spacing = 4;
    self.edgeInsets = NSEdgeInsetsZero;
    self.wantsLayer = YES;

    NSStackView *line = CQHorizontal();
    self.nameLabel = CQLabel(@"", [NSFont systemFontOfSize:12 weight:NSFontWeightMedium], CQTheme.text);
    [self.nameLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                             forOrientation:NSLayoutConstraintOrientationHorizontal];
    [line addArrangedSubview:self.nameLabel];
    NSView *spacer = [NSView new];
    [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow
                       forOrientation:NSLayoutConstraintOrientationHorizontal];
    [line addArrangedSubview:spacer];
    self.percentLabel = CQLabel(@"", [NSFont monospacedDigitSystemFontOfSize:18
                                                                     weight:NSFontWeightSemibold], CQTheme.accent);
    self.percentLabel.alignment = NSTextAlignmentRight;
    [self.percentLabel setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                                forOrientation:NSLayoutConstraintOrientationHorizontal];
    [line addArrangedSubview:self.percentLabel];
    [self addArrangedSubview:line];

    self.progressView = [CQProgressView new];
    [self addArrangedSubview:self.progressView];
    self.resetLabel = CQLabel(@"", [NSFont systemFontOfSize:10.5], CQTheme.subtext);
    [self addArrangedSubview:self.resetLabel];
    [line.widthAnchor constraintEqualToAnchor:self.widthAnchor].active = YES;
    [self.progressView.widthAnchor constraintEqualToAnchor:self.widthAnchor].active = YES;
    [self.resetLabel.widthAnchor constraintEqualToAnchor:self.widthAnchor].active = YES;
    [self updateWithWindow:window animated:NO];
    return self;
}

- (void)updateWithWindow:(CQRateLimitWindow *)window animated:(BOOL)animated {
    NSColor *color = [CQTheme colorForRemaining:window.remainingPercent];
    NSString *duration = CQDurationLabel(window.durationMinutes);
    NSString *suffix = [@" · " stringByAppendingString:duration];
    self.nameLabel.stringValue = [window.name hasSuffix:suffix] ? [window.name substringToIndex:window.name.length - suffix.length] : window.name;
    self.nameLabel.toolTip = window.name;
    self.percentLabel.stringValue = [NSString stringWithFormat:@"%.0f%%", window.remainingPercent];
    self.percentLabel.textColor = window.remainingPercent <= 50 ? color : CQTheme.text;
    NSString *reset = window.resetsAt ? CQRelativeDateString(window.resetsAt) : @"重置时间不可用";
    if (window.resetsAt && [window.resetsAt timeIntervalSinceNow] > 0) reset = [reset stringByAppendingString:@"重置"];
    self.resetLabel.stringValue = [NSString stringWithFormat:@"%@窗口 · %@", duration, reset];
    self.resetLabel.toolTip = window.resetsAt ? [@"重置于 " stringByAppendingString:CQAbsoluteDateString(window.resetsAt)] : reset;
    self.percentLabel.accessibilityLabel = [NSString stringWithFormat:@"%@，剩余 %@", window.name, self.percentLabel.stringValue];
    self.progressView.accessibilityLabel = [NSString stringWithFormat:@"%@剩余额度", window.name];
    self.progressView.accessibilityValue = [NSString stringWithFormat:@"%.0f%%", window.remainingPercent];
    [self.progressView setProgress:window.remainingPercent / 100.0 color:color animated:animated];
}

- (void)animateEntranceWithDelay:(NSTimeInterval)delay {
    BOOL reduceMotion = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    CABasicAnimation *opacity = [CABasicAnimation animationWithKeyPath:@"opacity"];
    opacity.fromValue = @0;
    opacity.toValue = @1;
    CAAnimationGroup *group = [CAAnimationGroup animation];
    if (reduceMotion) {
        group.animations = @[opacity];
        group.duration = 0.16;
    } else {
        CABasicAnimation *position = [CABasicAnimation animationWithKeyPath:@"transform"];
        position.fromValue = [NSValue valueWithCATransform3D:CATransform3DMakeTranslation(0, 6, 0)];
        position.toValue = [NSValue valueWithCATransform3D:CATransform3DIdentity];
        group.animations = @[opacity, position];
        group.duration = 0.20;
    }
    group.beginTime = [self.layer convertTime:CACurrentMediaTime() fromLayer:nil] + delay;
    group.fillMode = kCAFillModeBackwards;
    group.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.23 :1 :0.32 :1];
    [self.layer addAnimation:group forKey:@"cq.entrance"];
}

@end

static NSColor *CQTaskColor(CQTaskState state) {
    switch (state) {
        case CQTaskStateWaitingForApproval: return CQTheme.yellow;
        case CQTaskStateCompletedUnread: return CQTheme.green;
        case CQTaskStateRunning: return CQTheme.accent;
    }
}

static NSString *CQTaskStateLabel(CQTaskState state) {
    switch (state) {
        case CQTaskStateWaitingForApproval: return @"待审核";
        case CQTaskStateCompletedUnread: return @"已完成";
        case CQTaskStateRunning: return @"运行中";
    }
}

static NSString *CQTaskSymbolName(CQTaskState state) {
    switch (state) {
        case CQTaskStateWaitingForApproval: return @"exclamationmark.circle.fill";
        case CQTaskStateCompletedUnread: return @"checkmark.circle.fill";
        case CQTaskStateRunning: return @"circle.fill";
    }
}

static NSString *CQTaskTimeLabel(CQCodexTask *task) {
    NSDate *referenceDate = task.state == CQTaskStateCompletedUnread ? task.completedAt : task.startedAt;
    if (!referenceDate) return @"";
    NSTimeInterval seconds = MAX(0, -referenceDate.timeIntervalSinceNow);
    if (seconds < 60) return task.state == CQTaskStateCompletedUnread ? @"刚刚完成" : @"刚刚开始";
    NSInteger minutes = MAX(1, (NSInteger)floor(seconds / 60));
    if (minutes < 60) {
        return task.state == CQTaskStateCompletedUnread
            ? [NSString stringWithFormat:@"%ld 分钟前", (long)minutes]
            : [NSString stringWithFormat:@"已运行 %ld 分钟", (long)minutes];
    }
    NSInteger hours = (NSInteger)floor(minutes / 60.0);
    if (hours < 24) {
        return task.state == CQTaskStateCompletedUnread
            ? [NSString stringWithFormat:@"%ld 小时前", (long)hours]
            : [NSString stringWithFormat:@"已运行 %ld 小时", (long)hours];
    }
    NSInteger days = (NSInteger)floor(hours / 24.0);
    return task.state == CQTaskStateCompletedUnread
        ? [NSString stringWithFormat:@"%ld 天前", (long)days]
        : [NSString stringWithFormat:@"已运行 %ld 天", (long)days];
}

@interface CQTaskRowButton : NSButton
@property(nonatomic, strong) CQCodexTask *task;
@property(nonatomic, strong) NSImageView *stateImageView;
@property(nonatomic, strong) NSTextField *taskTitleLabel;
@property(nonatomic, strong) NSTextField *projectLabel;
@property(nonatomic, strong) NSTextField *stateLabel;
@property(nonatomic, strong) NSTextField *timeLabel;
@property(nonatomic, strong) NSTrackingArea *hoverTrackingArea;
- (instancetype)initWithTask:(CQCodexTask *)task target:(id)target action:(SEL)action;
- (void)updateWithTask:(CQCodexTask *)task;
- (void)animateEntranceWithDelay:(NSTimeInterval)delay;
@end

@implementation CQTaskRowButton

- (instancetype)initWithTask:(CQCodexTask *)task target:(id)target action:(SEL)action {
    self = [super initWithFrame:NSZeroRect];
    if (!self) return nil;
    self.target = target;
    self.action = action;
    self.title = @"";
    self.bordered = NO;
    self.wantsLayer = YES;
    self.layer.cornerRadius = 9;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    [self.heightAnchor constraintEqualToConstant:48].active = YES;

    self.stateImageView = [NSImageView new];
    self.taskTitleLabel = CQLabel(@"", [NSFont systemFontOfSize:12 weight:NSFontWeightMedium], CQTheme.text);
    self.projectLabel = CQLabel(@"", [NSFont systemFontOfSize:10.5], CQTheme.subtext);
    self.stateLabel = CQLabel(@"", [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium], CQTheme.accent);
    self.timeLabel = CQLabel(@"", [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightRegular], CQTheme.subtext);
    for (NSView *view in @[self.stateImageView, self.taskTitleLabel, self.projectLabel, self.stateLabel, self.timeLabel]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:view];
    }
    [self.taskTitleLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.projectLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.stateLabel setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.timeLabel setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [NSLayoutConstraint activateConstraints:@[
        [self.stateImageView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:2],
        [self.stateImageView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.stateImageView.widthAnchor constraintEqualToConstant:13],
        [self.stateImageView.heightAnchor constraintEqualToConstant:13],
        [self.taskTitleLabel.leadingAnchor constraintEqualToAnchor:self.stateImageView.trailingAnchor constant:9],
        [self.taskTitleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:7],
        [self.taskTitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.stateLabel.leadingAnchor constant:-8],
        [self.stateLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-2],
        [self.stateLabel.firstBaselineAnchor constraintEqualToAnchor:self.taskTitleLabel.firstBaselineAnchor],
        [self.projectLabel.leadingAnchor constraintEqualToAnchor:self.taskTitleLabel.leadingAnchor],
        [self.projectLabel.topAnchor constraintEqualToAnchor:self.taskTitleLabel.bottomAnchor constant:4],
        [self.projectLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.timeLabel.leadingAnchor constant:-8],
        [self.timeLabel.trailingAnchor constraintEqualToAnchor:self.stateLabel.trailingAnchor],
        [self.timeLabel.firstBaselineAnchor constraintEqualToAnchor:self.projectLabel.firstBaselineAnchor]
    ]];
    [self updateWithTask:task];
    return self;
}

- (NSView *)hitTest:(NSPoint)point {
    return [super hitTest:point] ? self : nil;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.hoverTrackingArea) [self removeTrackingArea:self.hoverTrackingArea];
    self.hoverTrackingArea = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInActiveApp | NSTrackingInVisibleRect
               owner:self
            userInfo:nil];
    [self addTrackingArea:self.hoverTrackingArea];
}

- (void)setHovered:(BOOL)hovered {
    NSColor *color = hovered ? [CQTheme.accent colorWithAlphaComponent:0.07] : NSColor.clearColor;
    if (NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) {
        self.layer.backgroundColor = color.CGColor;
        return;
    }
    CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"backgroundColor"];
    animation.fromValue = (id)(self.layer.presentationLayer ?: self.layer).backgroundColor;
    animation.toValue = (id)color.CGColor;
    animation.duration = 0.14;
    [self.layer addAnimation:animation forKey:@"cq.task.hover"];
    self.layer.backgroundColor = color.CGColor;
}

- (void)mouseEntered:(NSEvent *)event {
    [super mouseEntered:event];
    [self setHovered:YES];
}

- (void)mouseExited:(NSEvent *)event {
    [super mouseExited:event];
    [self setHovered:NO];
}

- (void)updateWithTask:(CQCodexTask *)task {
    self.task = task;
    NSColor *color = CQTaskColor(task.state);
    NSImage *image = [NSImage imageWithSystemSymbolName:CQTaskSymbolName(task.state)
                               accessibilityDescription:CQTaskStateLabel(task.state)];
    image.template = YES;
    self.stateImageView.image = image;
    self.stateImageView.contentTintColor = color;
    self.taskTitleLabel.stringValue = task.title.length > 0 ? task.title : @"未命名任务";
    self.projectLabel.stringValue = task.projectName.length > 0 ? task.projectName : @"本机任务";
    self.stateLabel.stringValue = CQTaskStateLabel(task.state);
    self.stateLabel.textColor = color;
    self.timeLabel.stringValue = CQTaskTimeLabel(task);
    self.toolTip = [NSString stringWithFormat:@"%@ · %@", self.taskTitleLabel.stringValue, self.projectLabel.stringValue];
    self.accessibilityLabel = self.taskTitleLabel.stringValue;
    self.accessibilityValue = [NSString stringWithFormat:@"%@，%@，%@",
        self.projectLabel.stringValue,
        self.stateLabel.stringValue,
        self.timeLabel.stringValue];
}

- (void)animateEntranceWithDelay:(NSTimeInterval)delay {
    CABasicAnimation *opacity = [CABasicAnimation animationWithKeyPath:@"opacity"];
    opacity.fromValue = @0;
    opacity.toValue = @1;
    CAAnimationGroup *group = [CAAnimationGroup animation];
    if (NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) {
        group.animations = @[opacity];
    } else {
        CABasicAnimation *translation = [CABasicAnimation animationWithKeyPath:@"transform"];
        translation.fromValue = [NSValue valueWithCATransform3D:CATransform3DMakeTranslation(0, 4, 0)];
        translation.toValue = [NSValue valueWithCATransform3D:CATransform3DIdentity];
        group.animations = @[opacity, translation];
    }
    group.beginTime = [self.layer convertTime:CACurrentMediaTime() fromLayer:nil] + delay;
    group.duration = 0.16;
    group.fillMode = kCAFillModeBackwards;
    group.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.23 :1 :0.32 :1];
    [self.layer addAnimation:group forKey:@"cq.task.entrance"];
}

@end

@interface CQPopoverController ()
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSView *statusDot;
@property(nonatomic, strong) NSStackView *statusPill;
@property(nonatomic, strong) NSTextField *detailLabel;
@property(nonatomic, strong) NSTextField *planLabel;
@property(nonatomic, strong) NSStackView *contentStack;
@property(nonatomic, strong) NSView *taskPanel;
@property(nonatomic, strong) NSTextField *taskCountLabel;
@property(nonatomic, strong) NSButton *markAllTasksViewedButton;
@property(nonatomic, strong) NSStackView *taskStack;
@property(nonatomic, strong) NSMutableDictionary<NSString *, CQTaskRowButton *> *taskRows;
@property(nonatomic, copy) NSString *taskSignature;
@property(nonatomic, strong) NSTextField *quotaTitleLabel;
@property(nonatomic, strong) NSTextField *quotaSummaryLabel;
@property(nonatomic, strong) NSView *quotaPanel;
@property(nonatomic, strong) NSView *quotaDetailsDivider;
@property(nonatomic, strong) NSStackView *quotaStack;
@property(nonatomic, strong) NSMutableDictionary<NSString *, CQQuotaRowView *> *quotaRows;
@property(nonatomic, strong, nullable) NSTextField *emptyQuotaLabel;
@property(nonatomic, strong) NSStackView *resetRow;
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
    NSView *root = CQPanelBackground();
    root.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    self.view = root;
    self.preferredContentSize = NSMakeSize(360, 470);

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
    content.spacing = 14;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [document addSubview:content];
    self.contentStack = content;
    self.quotaRows = [NSMutableDictionary dictionary];
    self.taskRows = [NSMutableDictionary dictionary];
    self.taskSignature = @"";

    NSStackView *header = CQHorizontal();
    NSTextField *title = CQLabel(@"Codex Quota", [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold], CQTheme.text);
    NSImageView *brandIcon = [NSImageView new];
    brandIcon.image = [NSImage imageWithSystemSymbolName:@"gauge.with.needle" accessibilityDescription:nil];
    brandIcon.contentTintColor = CQTheme.text;
    [brandIcon.widthAnchor constraintEqualToConstant:18].active = YES;
    [brandIcon.heightAnchor constraintEqualToConstant:18].active = YES;
    [header addArrangedSubview:brandIcon];
    [header addArrangedSubview:title];
    NSView *spacer = [NSView new];
    [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [header addArrangedSubview:spacer];
    NSButton *extensions = CQQuietButton(@"扩展", @"puzzlepiece.extension", self, @selector(showExtensions:));
    extensions.toolTip = @"管理第三方与自建 Skill / 插件";


    self.statusPill = CQHorizontal();
    self.statusPill.spacing = 6;
    self.statusPill.edgeInsets = NSEdgeInsetsZero;
    self.statusDot = [NSView new];
    self.statusDot.wantsLayer = YES;
    self.statusDot.layer.backgroundColor = CQTheme.yellow.CGColor;
    self.statusDot.layer.cornerRadius = 3;
    [self.statusDot.widthAnchor constraintEqualToConstant:6].active = YES;
    [self.statusDot.heightAnchor constraintEqualToConstant:6].active = YES;
    [self.statusPill addArrangedSubview:self.statusDot];
    self.statusLabel = CQLabel(@"连接中", [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium], CQTheme.subtext);
    self.statusLabel.alignment = NSTextAlignmentRight;
    [self.statusPill addArrangedSubview:self.statusLabel];
    [header addArrangedSubview:self.statusPill];
    [content addArrangedSubview:header];
    [content setCustomSpacing:8 afterView:header];

    NSStackView *subheader = CQHorizontal();
    self.detailLabel = CQLabel(@"正在查找 Codex…", [NSFont systemFontOfSize:10.5], CQTheme.subtext);
    self.planLabel = CQLabel(@"", [NSFont systemFontOfSize:10 weight:NSFontWeightMedium], CQTheme.subtext);
    [subheader addArrangedSubview:self.detailLabel];
    NSView *subSpacer = [NSView new];
    [subSpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [subheader addArrangedSubview:subSpacer];
    [subheader addArrangedSubview:self.planLabel];
    [content addArrangedSubview:subheader];

    self.taskPanel = [NSView new];
    NSStackView *taskContent = [NSStackView new];
    taskContent.orientation = NSUserInterfaceLayoutOrientationVertical;
    taskContent.alignment = NSLayoutAttributeLeading;
    taskContent.spacing = 8;
    taskContent.translatesAutoresizingMaskIntoConstraints = NO;
    [self.taskPanel addSubview:taskContent];
    NSStackView *taskHeader = CQHorizontal();
    [taskHeader addArrangedSubview:CQLabel(@"任务动态", [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold], CQTheme.text)];
    NSView *taskHeaderSpacer = [NSView new];
    [taskHeaderSpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [taskHeader addArrangedSubview:taskHeaderSpacer];
    self.taskCountLabel = CQLabel(@"", [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightMedium], CQTheme.subtext);
    self.taskCountLabel.alignment = NSTextAlignmentRight;
    [taskHeader addArrangedSubview:self.taskCountLabel];
    self.markAllTasksViewedButton = CQQuietButton(@"全部已读", @"checkmark", self, @selector(markAllTasksViewed:));
    self.markAllTasksViewedButton.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium];
    self.markAllTasksViewedButton.toolTip = @"移除所有已完成提醒";
    self.markAllTasksViewedButton.hidden = YES;
    [taskHeader addArrangedSubview:self.markAllTasksViewedButton];
    [taskContent addArrangedSubview:taskHeader];
    self.taskStack = [NSStackView new];
    self.taskStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.taskStack.alignment = NSLayoutAttributeLeading;
    self.taskStack.spacing = 0;
    [taskContent addArrangedSubview:self.taskStack];
    [NSLayoutConstraint activateConstraints:@[
        [taskContent.leadingAnchor constraintEqualToAnchor:self.taskPanel.leadingAnchor],
        [taskContent.trailingAnchor constraintEqualToAnchor:self.taskPanel.trailingAnchor],
        [taskContent.topAnchor constraintEqualToAnchor:self.taskPanel.topAnchor],
        [taskContent.bottomAnchor constraintEqualToAnchor:self.taskPanel.bottomAnchor],
        [taskHeader.widthAnchor constraintEqualToAnchor:taskContent.widthAnchor],
        [self.taskStack.widthAnchor constraintEqualToAnchor:taskContent.widthAnchor]
    ]];

    self.quotaPanel = [NSView new];
    NSStackView *quotaContent = [NSStackView new];
    quotaContent.orientation = NSUserInterfaceLayoutOrientationVertical;
    quotaContent.alignment = NSLayoutAttributeLeading;
    quotaContent.spacing = 10;
    quotaContent.translatesAutoresizingMaskIntoConstraints = NO;
    [self.quotaPanel addSubview:quotaContent];
    NSStackView *quotaHeader = CQHorizontal();
    self.quotaTitleLabel = CQLabel(@"可用额度", [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold], CQTheme.text);
    [quotaHeader addArrangedSubview:self.quotaTitleLabel];
    NSView *quotaHeaderSpacer = [NSView new];
    [quotaHeaderSpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [quotaHeader addArrangedSubview:quotaHeaderSpacer];
    self.quotaSummaryLabel = CQLabel(@"剩余", [NSFont systemFontOfSize:10.5], CQTheme.subtext);
    [quotaHeader addArrangedSubview:self.quotaSummaryLabel];
    [quotaContent addArrangedSubview:quotaHeader];
    self.quotaStack = [NSStackView new];
    self.quotaStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.quotaStack.alignment = NSLayoutAttributeLeading;
    self.quotaStack.spacing = 10;
    [quotaContent addArrangedSubview:self.quotaStack];

    self.quotaDetailsDivider = CQDivider();
    [quotaContent addArrangedSubview:self.quotaDetailsDivider];
    self.resetRow = CQHorizontal();
    [self.resetRow addArrangedSubview:CQLabel(@"可用重置", [NSFont systemFontOfSize:11], CQTheme.subtext)];
    NSView *resetSpacer = [NSView new];
    [resetSpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.resetRow addArrangedSubview:resetSpacer];
    self.resetValueLabel = CQLabel(@"不可用", [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightSemibold], CQTheme.text);
    [self.resetRow addArrangedSubview:self.resetValueLabel];
    [quotaContent addArrangedSubview:self.resetRow];
    [quotaContent setCustomSpacing:7 afterView:self.resetRow];

    self.workspaceRow = CQHorizontal();
    [self.workspaceRow addArrangedSubview:CQLabel(@"工作区额度", [NSFont systemFontOfSize:11], CQTheme.subtext)];
    NSView *workspaceSpacer = [NSView new];
    [workspaceSpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.workspaceRow addArrangedSubview:workspaceSpacer];
    self.workspaceValueLabel = CQLabel(@"", [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightSemibold], CQTheme.text);
    [self.workspaceRow addArrangedSubview:self.workspaceValueLabel];
    self.workspaceRow.hidden = YES;
    [quotaContent addArrangedSubview:self.workspaceRow];
    [NSLayoutConstraint activateConstraints:@[
        [quotaContent.leadingAnchor constraintEqualToAnchor:self.quotaPanel.leadingAnchor],
        [quotaContent.trailingAnchor constraintEqualToAnchor:self.quotaPanel.trailingAnchor],
        [quotaContent.topAnchor constraintEqualToAnchor:self.quotaPanel.topAnchor],
        [quotaContent.bottomAnchor constraintEqualToAnchor:self.quotaPanel.bottomAnchor],
        [quotaHeader.widthAnchor constraintEqualToAnchor:quotaContent.widthAnchor],
        [self.quotaStack.widthAnchor constraintEqualToAnchor:quotaContent.widthAnchor],
        [self.quotaDetailsDivider.widthAnchor constraintEqualToAnchor:quotaContent.widthAnchor],
        [self.resetRow.widthAnchor constraintEqualToAnchor:quotaContent.widthAnchor],
        [self.workspaceRow.widthAnchor constraintEqualToAnchor:quotaContent.widthAnchor]
    ]];
    [content addArrangedSubview:self.quotaPanel];
    NSView *taskDivider = CQDivider();
    [content addArrangedSubview:taskDivider];
    [taskDivider.widthAnchor constraintEqualToAnchor:content.widthAnchor].active = YES;
    [content addArrangedSubview:self.taskPanel];

    self.errorLabel = CQLabel(@"", [NSFont systemFontOfSize:11], CQTheme.red);
    self.errorLabel.maximumNumberOfLines = 3;
    self.errorLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.errorLabel.hidden = YES;
    [content addArrangedSubview:self.errorLabel];

    NSView *footer = CQFooterSurface();
    footer.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:footer];

    NSStackView *footerStack = [NSStackView new];
    footerStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    footerStack.alignment = NSLayoutAttributeCenterX;
    footerStack.spacing = 8;
    footerStack.translatesAutoresizingMaskIntoConstraints = NO;
    [footer addSubview:footerStack];

    NSStackView *primaryRow = CQHorizontal();
    self.updatedLabel = CQLabel(@"尚未更新", [NSFont systemFontOfSize:10 weight:NSFontWeightMedium], CQTheme.overlay);
    [primaryRow addArrangedSubview:self.updatedLabel];
    NSView *primarySpacer = [NSView new];
    [primarySpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [primaryRow addArrangedSubview:primarySpacer];
    NSButton *settings = CQQuietButton(@"", @"gearshape", self, @selector(showNotificationSettings:));
    settings.imagePosition = NSImageOnly;
    settings.toolTip = @"通知设置 · Bark 推送到 iPhone";
    settings.accessibilityLabel = @"通知设置";
    [settings.widthAnchor constraintEqualToConstant:26].active = YES;
    [primaryRow addArrangedSubview:settings];
    [primaryRow addArrangedSubview:extensions];
    self.refreshButton = CQQuietButton(@"刷新", @"arrow.clockwise", self, @selector(refresh:));
    [self.refreshButton.widthAnchor constraintGreaterThanOrEqualToConstant:54].active = YES;
    [primaryRow addArrangedSubview:self.refreshButton];
    [footerStack addArrangedSubview:primaryRow];

    NSStackView *actions = CQHorizontal();
    actions.spacing = 8;
    self.loginButton = CQQuietButton(@"登录", @"person.crop.circle", self, @selector(login:));
    NSButton *choose = CQQuietButton(@"选择 Codex", @"terminal", self, @selector(chooseCodex:));
    NSButton *quit = CQQuietButton(@"退出", @"power", self, @selector(quit:));
    [actions addArrangedSubview:self.loginButton];
    [actions addArrangedSubview:choose];
    [actions addArrangedSubview:quit];
    NSView *actionsSpacer = [NSView new];
    [actionsSpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [actions addArrangedSubview:actionsSpacer];
    self.launchCheckbox = [NSButton checkboxWithTitle:@"登录时启动" target:self action:@selector(toggleLaunchAtLogin:)];
    self.launchCheckbox.controlSize = NSControlSizeSmall;
    self.launchCheckbox.attributedTitle = [[NSAttributedString alloc]
        initWithString:@"登录时启动"
            attributes:@{
                NSFontAttributeName: [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium],
                NSForegroundColorAttributeName: CQTheme.text
            }];
    self.launchCheckbox.contentTintColor = CQTheme.text;
    [actions addArrangedSubview:self.launchCheckbox];
    [footerStack addArrangedSubview:actions];

    [NSLayoutConstraint activateConstraints:@[
        [footer.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [footer.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [footer.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [footer.heightAnchor constraintEqualToConstant:68],
        [scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:root.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:footer.topAnchor],
        [document.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
        [document.trailingAnchor constraintEqualToAnchor:scroll.contentView.trailingAnchor],
        [document.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
        [document.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
        [content.leadingAnchor constraintEqualToAnchor:document.leadingAnchor constant:20],
        [content.trailingAnchor constraintEqualToAnchor:document.trailingAnchor constant:-20],
        [content.topAnchor constraintEqualToAnchor:document.topAnchor constant:16],
        [content.bottomAnchor constraintEqualToAnchor:document.bottomAnchor constant:-14],
        [header.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [subheader.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [self.taskPanel.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [self.quotaPanel.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [self.errorLabel.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [footerStack.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor constant:20],
        [footerStack.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor constant:-20],
        [footerStack.centerXAnchor constraintEqualToAnchor:footer.centerXAnchor],
        [footerStack.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor],
        [primaryRow.widthAnchor constraintEqualToAnchor:footerStack.widthAnchor],
        [actions.widthAnchor constraintEqualToAnchor:footerStack.widthAnchor]
    ]];
}

- (NSArray<CQCodexTask *> *)allTasksInSnapshot:(CQTaskSnapshot *)snapshot {
    NSMutableArray<CQCodexTask *> *tasks = [NSMutableArray array];
    [tasks addObjectsFromArray:snapshot.waitingForApprovalTasks ?: @[]];
    [tasks addObjectsFromArray:snapshot.unreadCompletedTasks ?: @[]];
    [tasks addObjectsFromArray:snapshot.runningTasks ?: @[]];
    return tasks;
}

- (void)appendTaskRows:(NSArray<CQCodexTask *> *)tasks {
    for (NSUInteger index = 0; index < tasks.count; index++) {
        CQCodexTask *task = tasks[index];
        CQTaskRowButton *row = [[CQTaskRowButton alloc] initWithTask:task target:self action:@selector(taskSelected:)];
        self.taskRows[task.turnID] = row;
        [self.taskStack addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:self.taskStack.widthAnchor].active = YES;
        [row animateEntranceWithDelay:index * 0.025];
        if (index + 1 < tasks.count) {
            NSView *divider = CQDivider();
            divider.alphaValue = 0.58;
            [self.taskStack addArrangedSubview:divider];
            [divider.widthAnchor constraintEqualToAnchor:self.taskStack.widthAnchor constant:-28].active = YES;
        }
    }
}

- (void)reconcileTaskSnapshot:(CQTaskSnapshot *)snapshot {
    snapshot = snapshot ?: [CQTaskSnapshot emptySnapshot];
    NSString *signature = snapshot.contentSignature;
    self.taskCountLabel.stringValue = snapshot.attentionCount > 0
        ? [NSString stringWithFormat:@"%lu 项", (unsigned long)snapshot.attentionCount]
        : @"";
    self.markAllTasksViewedButton.hidden = snapshot.unreadCompletedTasks.count == 0;
    if ([signature isEqualToString:self.taskSignature] && self.taskStack.arrangedSubviews.count > 0) {
        for (CQCodexTask *task in [self allTasksInSnapshot:snapshot]) {
            [self.taskRows[task.turnID] updateWithTask:task];
        }
        return;
    }

    self.taskSignature = signature;
    for (NSView *view in self.taskStack.arrangedSubviews.copy) {
        [self.taskStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    [self.taskRows removeAllObjects];
    if (snapshot.attentionCount == 0) {
        NSStackView *empty = CQHorizontal();
        empty.spacing = 7;
        NSImageView *icon = [NSImageView new];
        NSImage *image = [NSImage imageWithSystemSymbolName:@"checkmark.circle.fill"
                                   accessibilityDescription:@"无需关注的任务"];
        image.template = YES;
        icon.image = image;
        icon.contentTintColor = CQTheme.green;
        [icon.widthAnchor constraintEqualToConstant:14].active = YES;
        [icon.heightAnchor constraintEqualToConstant:14].active = YES;
        [empty addArrangedSubview:icon];
        [empty addArrangedSubview:CQLabel(@"当前没有需要关注的任务",
            [NSFont systemFontOfSize:11 weight:NSFontWeightMedium], CQTheme.subtext)];
        [empty.heightAnchor constraintEqualToConstant:30].active = YES;
        [self.taskStack addArrangedSubview:empty];
        [empty.widthAnchor constraintEqualToAnchor:self.taskStack.widthAnchor].active = YES;
        return;
    }

    [self appendTaskRows:[self allTasksInSnapshot:snapshot]];
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
    NSMutableArray<CQQuotaRowView *> *newRows = [NSMutableArray array];
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
            [newRows addObject:row];
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
    [self.quotaStack layoutSubtreeIfNeeded];
    [newRows enumerateObjectsUsingBlock:^(CQQuotaRowView *row, NSUInteger index, BOOL *stop) {
        (void)stop;
        [row animateEntranceWithDelay:index * 0.04];
    }];
}

- (void)renderSnapshot:(CQQuotaSnapshot *)snapshot
          taskSnapshot:(CQTaskSnapshot *)taskSnapshot
                status:(NSString *)status
                detail:(NSString *)detail
                 error:(NSString *)error
            refreshing:(BOOL)refreshing
             signedOut:(BOOL)signedOut
         launchAtLogin:(BOOL)launchAtLogin {
    self.statusLabel.stringValue = status;
    NSColor *statusColor = [status isEqualToString:@"已连接"] ? CQTheme.green
        : ([status isEqualToString:@"需要登录"] || [status isEqualToString:@"已断开"] ? CQTheme.red : CQTheme.yellow);
    self.statusLabel.textColor = CQTheme.subtext;
    self.statusDot.layer.backgroundColor = statusColor.CGColor;
    self.detailLabel.stringValue = detail;
    self.planLabel.stringValue = snapshot.planType.capitalizedString ?: @"";
    [self reconcileTaskSnapshot:taskSnapshot ?: [CQTaskSnapshot emptySnapshot]];
    self.refreshButton.enabled = !refreshing;
    self.refreshButton.title = refreshing ? @"刷新中…" : @"刷新";
    self.loginButton.hidden = !signedOut;
    self.launchCheckbox.state = launchAtLogin ? NSControlStateValueOn : NSControlStateValueOff;

    NSArray<CQRateLimitWindow *> *windows = [snapshot.windows sortedArrayUsingComparator:^NSComparisonResult(CQRateLimitWindow *a, CQRateLimitWindow *b) {
        if (a.remainingPercent < b.remainingPercent) return NSOrderedAscending;
        if (a.remainingPercent > b.remainingPercent) return NSOrderedDescending;
        return [a.limitID compare:b.limitID];
    }];
    [self reconcileQuotaWindows:windows ?: @[] hasSnapshot:snapshot != nil];
    NSUInteger lowCount = 0;
    for (CQRateLimitWindow *window in windows) if (window.remainingPercent <= 20) lowCount++;
    self.quotaSummaryLabel.stringValue = lowCount > 0 ? [NSString stringWithFormat:@"剩余 · %lu 项偏低", (unsigned long)lowCount] : @"剩余";
    self.quotaSummaryLabel.textColor = lowCount > 0 ? CQTheme.red : CQTheme.subtext;
    if (self.emptyQuotaLabel && (signedOut || error.length > 0)) {
        self.emptyQuotaLabel.stringValue = signedOut ? @"登录 Codex 后查看订阅额度" : @"暂时无法获取额度，请刷新重试";
    }

    self.resetRow.hidden = !snapshot.resetCreditsAvailable;
    self.quotaDetailsDivider.hidden = !snapshot.resetCreditsAvailable && !snapshot.hasWorkspaceCredits;
    self.resetValueLabel.stringValue = snapshot.resetCreditsAvailable
        ? [NSString stringWithFormat:@"%@ 次", snapshot.resetCreditsAvailable] : @"不可用";
    self.workspaceRow.hidden = !snapshot.hasWorkspaceCredits;
    if (snapshot.hasWorkspaceCredits) {
        self.workspaceValueLabel.stringValue = snapshot.workspaceUnlimited
            ? @"无限" : (snapshot.workspaceBalance ?: @"不可用");
    }
    self.errorLabel.hidden = error.length == 0;
    self.errorLabel.stringValue = error ?: @"";
    self.updatedLabel.stringValue = snapshot.updatedAt
        ? [NSString stringWithFormat:@"更新于 %@", CQAbsoluteDateString(snapshot.updatedAt)] : @"尚未更新";

    [self.view layoutSubtreeIfNeeded];
    CGFloat contentHeight = self.contentStack.fittingSize.height;
    CGFloat desiredHeight = MAX(CQMainPanelMinimumHeight, ceil(contentHeight + 16 + 14 + 68));
    self.preferredContentSize = NSMakeSize(360, desiredHeight);
}

- (void)refresh:(id)sender { if (self.refreshHandler) self.refreshHandler(); }
- (void)login:(id)sender { if (self.loginHandler) self.loginHandler(); }
- (void)chooseCodex:(id)sender { if (self.chooseCodexHandler) self.chooseCodexHandler(); }
- (void)showExtensions:(id)sender { if (self.extensionManagerHandler) self.extensionManagerHandler(); }
- (void)showNotificationSettings:(id)sender { if (self.notificationSettingsHandler) self.notificationSettingsHandler(); }
- (void)taskSelected:(CQTaskRowButton *)sender { if (self.taskSelectedHandler) self.taskSelectedHandler(sender.task); }
- (void)markAllTasksViewed:(id)sender { (void)sender; if (self.markAllTasksViewedHandler) self.markAllTasksViewedHandler(); }
- (void)toggleLaunchAtLogin:(NSButton *)sender {
    if (self.launchAtLoginHandler) self.launchAtLoginHandler(sender.state == NSControlStateValueOn);
}
- (void)quit:(id)sender { if (self.quitHandler) self.quitHandler(); }

@end
