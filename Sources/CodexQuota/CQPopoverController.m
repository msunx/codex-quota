#import "CQPopoverController.h"
#import "CQTheme.h"
#import <QuartzCore/QuartzCore.h>

@interface CQProgressView : NSView
@property(nonatomic) double progress;
- (void)setProgress:(double)progress color:(NSColor *)color animated:(BOOL)animated;
@end

@implementation CQProgressView {
    CAShapeLayer *_trackLayer;
    CALayer *_revealLayer;
    CAGradientLayer *_fillLayer;
    CAShapeLayer *_segmentMask;
}
- (BOOL)isFlipped { return YES; }
- (instancetype)init {
    self = [super initWithFrame:NSMakeRect(0, 0, 100, 8)];
    if (self) {
        self.wantsLayer = YES;
        _trackLayer = [CAShapeLayer layer];
        _trackLayer.fillColor = [CQTheme.surface colorWithAlphaComponent:0.88].CGColor;
        [self.layer addSublayer:_trackLayer];

        _revealLayer = [CALayer layer];
        _revealLayer.anchorPoint = CGPointMake(0, 0.5);
        _revealLayer.masksToBounds = YES;
        [self.layer addSublayer:_revealLayer];

        _fillLayer = [CAGradientLayer layer];
        _fillLayer.startPoint = CGPointMake(0, 0.5);
        _fillLayer.endPoint = CGPointMake(1, 0.5);
        [_revealLayer addSublayer:_fillLayer];
        _segmentMask = [CAShapeLayer layer];
        _segmentMask.fillColor = NSColor.whiteColor.CGColor;
        _fillLayer.mask = _segmentMask;
        [self.heightAnchor constraintEqualToConstant:8].active = YES;
    }
    return self;
}

- (CGFloat)revealWidthForProgress:(double)progress {
    static NSInteger const segmentCount = 18;
    static CGFloat const gap = 3.0;
    CGFloat width = self.bounds.size.width;
    if (width <= 0) return 0;
    CGFloat segmentWidth = (width - gap * (segmentCount - 1)) / segmentCount;
    NSInteger filledSegments = (NSInteger)llround(MAX(0, MIN(1, progress)) * segmentCount);
    if (filledSegments <= 0) return 0;
    return filledSegments * segmentWidth + (filledSegments - 1) * gap;
}

- (void)layout {
    [super layout];
    static NSInteger const segmentCount = 18;
    static CGFloat const gap = 3.0;
    CGFloat width = self.bounds.size.width;
    CGFloat height = self.bounds.size.height;
    CGFloat segmentWidth = MAX(1, (width - gap * (segmentCount - 1)) / segmentCount);
    CGMutablePathRef path = CGPathCreateMutable();
    for (NSInteger index = 0; index < segmentCount; index++) {
        CGRect rect = CGRectMake(index * (segmentWidth + gap), 0, segmentWidth, height);
        CGPathAddRoundedRect(path, NULL, rect, 2.75, 2.75);
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _trackLayer.frame = self.bounds;
    _trackLayer.path = path;
    _revealLayer.position = CGPointMake(0, height / 2.0);
    _revealLayer.bounds = CGRectMake(0, 0, [self revealWidthForProgress:self.progress], height);
    _fillLayer.frame = self.bounds;
    _segmentMask.frame = self.bounds;
    _segmentMask.path = path;
    [CATransaction commit];
    CGPathRelease(path);
}
- (void)setProgress:(double)progress color:(NSColor *)color animated:(BOOL)animated {
    progress = MAX(0, MIN(1, progress));
    NSColor *gradientStart = [color blendedColorWithFraction:0.34 ofColor:NSColor.whiteColor];
    NSColor *gradientEnd = [color blendedColorWithFraction:0.12 ofColor:NSColor.blackColor];
    _fillLayer.colors = @[(id)gradientStart.CGColor, (id)color.CGColor, (id)gradientEnd.CGColor];
    _fillLayer.locations = @[@0, @0.58, @1];
    _fillLayer.endPoint = CGPointMake(MAX(progress, 0.01), 0.5);
    [self layoutSubtreeIfNeeded];
    CGFloat width = [self revealWidthForProgress:progress];
    BOOL reduceMotion = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    if (animated && !reduceMotion && self.window) {
        CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"bounds.size.width"];
        CALayer *presentation = (CALayer *)_revealLayer.presentationLayer;
        animation.fromValue = @(presentation ? presentation.bounds.size.width : _revealLayer.bounds.size.width);
        animation.toValue = @(width);
        animation.duration = 0.24;
        animation.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.77 :0 :0.175 :1];
        [_revealLayer addAnimation:animation forKey:@"quota"];
    }
    self.progress = progress;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _revealLayer.bounds = CGRectMake(0, 0, width, self.bounds.size.height);
    [CATransaction commit];
}
@end

static NSView *CQDivider(void) {
    NSView *view = [NSView new];
    view.wantsLayer = YES;
    view.layer.backgroundColor = [CQTheme.overlay colorWithAlphaComponent:0.20].CGColor;
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
@property(nonatomic, strong) NSView *colorDot;
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
    self.spacing = 3;
    self.edgeInsets = NSEdgeInsetsZero;
    self.wantsLayer = YES;

    NSStackView *line = CQHorizontal();
    self.colorDot = [NSView new];
    self.colorDot.wantsLayer = YES;
    self.colorDot.layer.cornerRadius = 3;
    [self.colorDot.widthAnchor constraintEqualToConstant:6].active = YES;
    [self.colorDot.heightAnchor constraintEqualToConstant:6].active = YES;
    [line addArrangedSubview:self.colorDot];
    self.nameLabel = CQLabel(@"", [NSFont systemFontOfSize:11.5 weight:NSFontWeightSemibold], CQTheme.text);
    [self.nameLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                             forOrientation:NSLayoutConstraintOrientationHorizontal];
    [line addArrangedSubview:self.nameLabel];
    NSView *spacer = [NSView new];
    [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow
                       forOrientation:NSLayoutConstraintOrientationHorizontal];
    [line addArrangedSubview:spacer];
    self.percentLabel = CQLabel(@"", [NSFont monospacedDigitSystemFontOfSize:15
                                                                     weight:NSFontWeightSemibold], CQTheme.accent);
    self.percentLabel.alignment = NSTextAlignmentRight;
    [self.percentLabel setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                                forOrientation:NSLayoutConstraintOrientationHorizontal];
    [line addArrangedSubview:self.percentLabel];
    [self addArrangedSubview:line];

    self.progressView = [CQProgressView new];
    [self addArrangedSubview:self.progressView];
    self.resetLabel = CQLabel(@"", [NSFont systemFontOfSize:9.5 weight:NSFontWeightMedium], CQTheme.overlay);
    [self addArrangedSubview:self.resetLabel];
    [line.widthAnchor constraintEqualToAnchor:self.widthAnchor].active = YES;
    [self.progressView.widthAnchor constraintEqualToAnchor:self.widthAnchor].active = YES;
    [self updateWithWindow:window animated:NO];
    return self;
}

- (void)updateWithWindow:(CQRateLimitWindow *)window animated:(BOOL)animated {
    NSColor *color = [CQTheme colorForRemaining:window.remainingPercent];
    self.colorDot.layer.backgroundColor = color.CGColor;
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

@interface CQPopoverController ()
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSView *statusDot;
@property(nonatomic, strong) NSStackView *statusPill;
@property(nonatomic, strong) NSTextField *detailLabel;
@property(nonatomic, strong) NSTextField *planLabel;
@property(nonatomic, strong) NSStackView *contentStack;
@property(nonatomic, strong) NSSegmentedControl *providerControl;
@property(nonatomic, strong) NSView *deepSeekPanel;
@property(nonatomic, strong) NSStackView *deepSeekSettings;
@property(nonatomic, strong) NSPopUpButton *modelPopup;
@property(nonatomic, strong) NSTextField *deepSeekBalanceLabel;
@property(nonatomic, strong) NSTextField *quotaTitleLabel;
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
    NSView *root = CQWindowGlassView();
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
    content.spacing = 11;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [document addSubview:content];
    self.contentStack = content;
    self.quotaRows = [NSMutableDictionary dictionary];

    NSStackView *header = CQHorizontal();
    NSTextField *title = CQLabel(@"Codex Quota", [NSFont systemFontOfSize:20 weight:NSFontWeightSemibold], CQTheme.text);
    [header addArrangedSubview:title];
    NSView *spacer = [NSView new];
    [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [header addArrangedSubview:spacer];
    NSButton *extensions = CQButton(@"扩展", @"puzzlepiece.extension", self, @selector(showExtensions:));
    extensions.toolTip = @"管理第三方与自建 Skill / 插件";
    [header addArrangedSubview:extensions];

    self.statusPill = CQHorizontal();
    self.statusPill.spacing = 6;
    self.statusPill.edgeInsets = NSEdgeInsetsMake(4, 8, 4, 8);
    self.statusPill.wantsLayer = YES;
    self.statusPill.layer.backgroundColor = [CQTheme.yellow colorWithAlphaComponent:0.10].CGColor;
    self.statusPill.layer.borderColor = [CQTheme.yellow colorWithAlphaComponent:0.26].CGColor;
    self.statusPill.layer.borderWidth = 0.5;
    self.statusPill.layer.cornerRadius = 11;
    self.statusPill.layer.cornerCurve = kCACornerCurveContinuous;
    self.statusDot = [NSView new];
    self.statusDot.wantsLayer = YES;
    self.statusDot.layer.backgroundColor = CQTheme.yellow.CGColor;
    self.statusDot.layer.cornerRadius = 3;
    [self.statusDot.widthAnchor constraintEqualToConstant:6].active = YES;
    [self.statusDot.heightAnchor constraintEqualToConstant:6].active = YES;
    [self.statusPill addArrangedSubview:self.statusDot];
    self.statusLabel = CQLabel(@"连接中", [NSFont systemFontOfSize:10.5 weight:NSFontWeightSemibold], CQTheme.yellow);
    self.statusLabel.alignment = NSTextAlignmentRight;
    [self.statusPill addArrangedSubview:self.statusLabel];
    [header addArrangedSubview:self.statusPill];
    [content addArrangedSubview:header];

    NSStackView *subheader = CQHorizontal();
    self.detailLabel = CQLabel(@"正在查找 Codex…", [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium], CQTheme.subtext);
    self.planLabel = CQLabel(@"", [NSFont systemFontOfSize:10 weight:NSFontWeightBold], CQTheme.lavender);
    [subheader addArrangedSubview:self.detailLabel];
    NSView *subSpacer = [NSView new];
    [subSpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [subheader addArrangedSubview:subSpacer];
    [subheader addArrangedSubview:self.planLabel];
    [content addArrangedSubview:subheader];

    self.providerControl = [NSSegmentedControl segmentedControlWithLabels:@[@"Codex 订阅", @"DeepSeek"]
                                                             trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                   target:self
                                                                   action:@selector(providerChanged:)];
    self.providerControl.segmentStyle = NSSegmentStyleCapsule;
    self.providerControl.controlSize = NSControlSizeRegular;
    self.providerControl.selectedSegment = 0;
    self.providerControl.accessibilityLabel = @"模型来源";
    [content addArrangedSubview:self.providerControl];

    self.deepSeekPanel = CQDashboardGlassSurface(16);
    self.deepSeekSettings = [NSStackView new];
    self.deepSeekSettings.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.deepSeekSettings.alignment = NSLayoutAttributeLeading;
    self.deepSeekSettings.spacing = 11;
    self.deepSeekSettings.translatesAutoresizingMaskIntoConstraints = NO;
    [self.deepSeekPanel addSubview:self.deepSeekSettings];

    NSStackView *modelRow = CQHorizontal();
    [modelRow addArrangedSubview:CQLabel(@"具体模型", [NSFont systemFontOfSize:12 weight:NSFontWeightMedium], CQTheme.subtext)];
    NSView *modelSpacer = [NSView new];
    [modelSpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [modelRow addArrangedSubview:modelSpacer];
    self.modelPopup = [NSPopUpButton new];
    self.modelPopup.autoenablesItems = NO;
    [self.modelPopup addItemWithTitle:CQDeepSeekFlashModel];
    [self.modelPopup addItemWithTitle:CQDeepSeekProModel];
    self.modelPopup.target = self;
    self.modelPopup.action = @selector(modelChanged:);
    self.modelPopup.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightMedium];
    [modelRow addArrangedSubview:self.modelPopup];
    [self.deepSeekSettings addArrangedSubview:modelRow];

    NSStackView *balanceRow = CQHorizontal();
    [balanceRow addArrangedSubview:CQLabel(@"剩余金额", [NSFont systemFontOfSize:12 weight:NSFontWeightMedium], CQTheme.subtext)];
    NSView *balanceSpacer = [NSView new];
    [balanceSpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [balanceRow addArrangedSubview:balanceSpacer];
    self.deepSeekBalanceLabel = CQLabel(@"等待余额数据…",
        [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightSemibold], CQTheme.text);
    self.deepSeekBalanceLabel.alignment = NSTextAlignmentRight;
    [balanceRow addArrangedSubview:self.deepSeekBalanceLabel];
    [self.deepSeekSettings addArrangedSubview:balanceRow];

    NSStackView *keyRow = CQHorizontal();
    [keyRow addArrangedSubview:CQLabel(@"API Key 已配置，可随时更换",
        [NSFont systemFontOfSize:10], CQTheme.overlay)];
    NSView *keySpacer = [NSView new];
    [keySpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [keyRow addArrangedSubview:keySpacer];
    [keyRow addArrangedSubview:CQButton(@"更换 API Key", @"key", self, @selector(changeAPIKey:))];
    [self.deepSeekSettings addArrangedSubview:keyRow];
    [modelRow.widthAnchor constraintEqualToAnchor:self.deepSeekSettings.widthAnchor].active = YES;
    [balanceRow.widthAnchor constraintEqualToAnchor:self.deepSeekSettings.widthAnchor].active = YES;
    [keyRow.widthAnchor constraintEqualToAnchor:self.deepSeekSettings.widthAnchor].active = YES;
    [NSLayoutConstraint activateConstraints:@[
        [self.deepSeekSettings.leadingAnchor constraintEqualToAnchor:self.deepSeekPanel.leadingAnchor constant:14],
        [self.deepSeekSettings.trailingAnchor constraintEqualToAnchor:self.deepSeekPanel.trailingAnchor constant:-14],
        [self.deepSeekSettings.topAnchor constraintEqualToAnchor:self.deepSeekPanel.topAnchor constant:14],
        [self.deepSeekSettings.bottomAnchor constraintEqualToAnchor:self.deepSeekPanel.bottomAnchor constant:-14]
    ]];
    self.deepSeekPanel.hidden = YES;
    [content addArrangedSubview:self.deepSeekPanel];

    self.quotaPanel = CQDashboardGlassSurface(14);
    NSStackView *quotaContent = [NSStackView new];
    quotaContent.orientation = NSUserInterfaceLayoutOrientationVertical;
    quotaContent.alignment = NSLayoutAttributeLeading;
    quotaContent.spacing = 7;
    quotaContent.translatesAutoresizingMaskIntoConstraints = NO;
    [self.quotaPanel addSubview:quotaContent];
    NSStackView *quotaHeader = CQHorizontal();
    self.quotaTitleLabel = CQLabel(@"可用额度", [NSFont systemFontOfSize:11.5 weight:NSFontWeightSemibold], CQTheme.subtext);
    [quotaHeader addArrangedSubview:self.quotaTitleLabel];
    NSView *quotaHeaderSpacer = [NSView new];
    [quotaHeaderSpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [quotaHeader addArrangedSubview:quotaHeaderSpacer];
    [quotaHeader addArrangedSubview:CQLabel(@"剩余", [NSFont systemFontOfSize:9.5 weight:NSFontWeightSemibold], CQTheme.overlay)];
    [quotaContent addArrangedSubview:quotaHeader];
    self.quotaStack = [NSStackView new];
    self.quotaStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.quotaStack.alignment = NSLayoutAttributeLeading;
    self.quotaStack.spacing = 7;
    [quotaContent addArrangedSubview:self.quotaStack];

    self.quotaDetailsDivider = CQDivider();
    [quotaContent addArrangedSubview:self.quotaDetailsDivider];
    self.resetRow = CQHorizontal();
    [self.resetRow addArrangedSubview:CQLabel(@"剩余重置次数", [NSFont systemFontOfSize:11], CQTheme.subtext)];
    NSView *resetSpacer = [NSView new];
    [resetSpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.resetRow addArrangedSubview:resetSpacer];
    self.resetValueLabel = CQLabel(@"不可用", [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightSemibold], CQTheme.text);
    [self.resetRow addArrangedSubview:self.resetValueLabel];
    [quotaContent addArrangedSubview:self.resetRow];

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
        [quotaContent.leadingAnchor constraintEqualToAnchor:self.quotaPanel.leadingAnchor constant:11],
        [quotaContent.trailingAnchor constraintEqualToAnchor:self.quotaPanel.trailingAnchor constant:-11],
        [quotaContent.topAnchor constraintEqualToAnchor:self.quotaPanel.topAnchor constant:8],
        [quotaContent.bottomAnchor constraintEqualToAnchor:self.quotaPanel.bottomAnchor constant:-8],
        [quotaHeader.widthAnchor constraintEqualToAnchor:quotaContent.widthAnchor],
        [self.quotaStack.widthAnchor constraintEqualToAnchor:quotaContent.widthAnchor],
        [self.quotaDetailsDivider.widthAnchor constraintEqualToAnchor:quotaContent.widthAnchor],
        [self.resetRow.widthAnchor constraintEqualToAnchor:quotaContent.widthAnchor],
        [self.workspaceRow.widthAnchor constraintEqualToAnchor:quotaContent.widthAnchor]
    ]];
    [content addArrangedSubview:self.quotaPanel];

    self.errorLabel = CQLabel(@"", [NSFont systemFontOfSize:11], CQTheme.red);
    self.errorLabel.maximumNumberOfLines = 3;
    self.errorLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.errorLabel.hidden = YES;
    [content addArrangedSubview:self.errorLabel];

    NSView *footer = CQDashboardGlassSurface(16);
    footer.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:footer];

    NSStackView *footerStack = [NSStackView new];
    footerStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    footerStack.alignment = NSLayoutAttributeCenterX;
    footerStack.spacing = 5;
    footerStack.translatesAutoresizingMaskIntoConstraints = NO;
    [footer addSubview:footerStack];

    NSStackView *primaryRow = CQHorizontal();
    self.updatedLabel = CQLabel(@"尚未更新", [NSFont systemFontOfSize:10 weight:NSFontWeightMedium], CQTheme.overlay);
    [primaryRow addArrangedSubview:self.updatedLabel];
    NSView *primarySpacer = [NSView new];
    [primarySpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [primaryRow addArrangedSubview:primarySpacer];
    self.refreshButton = CQPrimaryButton(@"刷新", @"arrow.clockwise", self, @selector(refresh:));
    [self.refreshButton.widthAnchor constraintGreaterThanOrEqualToConstant:72].active = YES;
    [primaryRow addArrangedSubview:self.refreshButton];
    [footerStack addArrangedSubview:primaryRow];

    NSStackView *actions = CQHorizontal();
    actions.spacing = 10;
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
    self.launchCheckbox.contentTintColor = CQTheme.accent;
    [actions addArrangedSubview:self.launchCheckbox];
    [footerStack addArrangedSubview:actions];

    [NSLayoutConstraint activateConstraints:@[
        [footer.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:10],
        [footer.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-10],
        [footer.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-10],
        [footer.heightAnchor constraintEqualToConstant:82],
        [scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:root.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:footer.topAnchor constant:-4],
        [document.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
        [document.trailingAnchor constraintEqualToAnchor:scroll.contentView.trailingAnchor],
        [document.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
        [document.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
        [content.leadingAnchor constraintEqualToAnchor:document.leadingAnchor constant:16],
        [content.trailingAnchor constraintEqualToAnchor:document.trailingAnchor constant:-16],
        [content.topAnchor constraintEqualToAnchor:document.topAnchor constant:10],
        [content.bottomAnchor constraintEqualToAnchor:document.bottomAnchor constant:-10],
        [header.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [subheader.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [self.providerControl.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [self.deepSeekPanel.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [self.quotaPanel.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [self.errorLabel.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [footerStack.leadingAnchor constraintGreaterThanOrEqualToAnchor:footer.leadingAnchor constant:14],
        [footerStack.trailingAnchor constraintLessThanOrEqualToAnchor:footer.trailingAnchor constant:-14],
        [footerStack.centerXAnchor constraintEqualToAnchor:footer.centerXAnchor],
        [footerStack.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor],
        [primaryRow.widthAnchor constraintEqualToAnchor:footerStack.widthAnchor],
        [actions.widthAnchor constraintEqualToAnchor:footerStack.widthAnchor]
    ]];
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
       deepSeekBalance:(CQDeepSeekBalance *)deepSeekBalance
          providerMode:(CQProviderMode)providerMode
                 model:(NSString *)model
                status:(NSString *)status
                detail:(NSString *)detail
                 error:(NSString *)error
            refreshing:(BOOL)refreshing
             signedOut:(BOOL)signedOut
         launchAtLogin:(BOOL)launchAtLogin {
    BOOL deepSeek = providerMode == CQProviderModeDeepSeek;
    self.statusLabel.stringValue = status;
    NSColor *statusColor = [status isEqualToString:@"已连接"] ? CQTheme.accent
        : ([status isEqualToString:@"需要登录"]
           || [status isEqualToString:@"需要 API Key"]
           || [status isEqualToString:@"已断开"] ? CQTheme.red : CQTheme.yellow);
    self.statusLabel.textColor = statusColor;
    self.statusDot.layer.backgroundColor = statusColor.CGColor;
    self.statusPill.layer.backgroundColor = [statusColor colorWithAlphaComponent:0.10].CGColor;
    self.statusPill.layer.borderColor = [statusColor colorWithAlphaComponent:0.28].CGColor;
    self.detailLabel.stringValue = detail;
    self.planLabel.stringValue = deepSeek ? @"DEEPSEEK" : (snapshot.planType.uppercaseString ?: @"");
    self.providerControl.selectedSegment = deepSeek ? 1 : 0;
    self.deepSeekPanel.hidden = !deepSeek;
    [self.modelPopup selectItemWithTitle:model ?: CQDeepSeekFlashModel];
    self.deepSeekBalanceLabel.stringValue = deepSeekBalance ? deepSeekBalance.displayValue : @"等待余额数据…";
    self.deepSeekBalanceLabel.textColor = deepSeekBalance.available ? CQTheme.accent : CQTheme.yellow;

    self.quotaPanel.hidden = deepSeek;
    self.refreshButton.enabled = !refreshing;
    self.refreshButton.title = refreshing ? @"刷新中…" : @"刷新";
    self.loginButton.hidden = deepSeek || !signedOut;
    self.launchCheckbox.state = launchAtLogin ? NSControlStateValueOn : NSControlStateValueOff;

    if (!deepSeek) [self reconcileQuotaWindows:snapshot.windows ?: @[] hasSnapshot:snapshot != nil];

    self.resetValueLabel.stringValue = snapshot.resetCreditsAvailable
        ? [NSString stringWithFormat:@"%@ 次", snapshot.resetCreditsAvailable] : @"不可用";
    self.workspaceRow.hidden = deepSeek || !snapshot.hasWorkspaceCredits;
    if (!deepSeek && snapshot.hasWorkspaceCredits) {
        self.workspaceValueLabel.stringValue = snapshot.workspaceUnlimited
            ? @"无限" : (snapshot.workspaceBalance ?: @"不可用");
    }
    self.errorLabel.hidden = error.length == 0;
    self.errorLabel.stringValue = error ?: @"";
    NSDate *updatedAt = deepSeek ? deepSeekBalance.updatedAt : snapshot.updatedAt;
    self.updatedLabel.stringValue = updatedAt
        ? [NSString stringWithFormat:@"最后更新：%@", CQAbsoluteDateString(updatedAt)]
        : @"尚未更新";

    [self.view layoutSubtreeIfNeeded];
    CGFloat contentHeight = self.contentStack.fittingSize.height;
    CGFloat desiredHeight = MIN(500, MAX(390, ceil(contentHeight + 36 + 100)));
    self.preferredContentSize = NSMakeSize(360, desiredHeight);
}

- (void)refresh:(id)sender { if (self.refreshHandler) self.refreshHandler(); }
- (void)login:(id)sender { if (self.loginHandler) self.loginHandler(); }
- (void)chooseCodex:(id)sender { if (self.chooseCodexHandler) self.chooseCodexHandler(); }
- (void)providerChanged:(NSSegmentedControl *)sender {
    if (self.providerChangeHandler) {
        self.providerChangeHandler(sender.selectedSegment == 1 ? CQProviderModeDeepSeek : CQProviderModeCodex);
    }
}
- (void)modelChanged:(NSPopUpButton *)sender {
    if (self.modelChangeHandler) self.modelChangeHandler(sender.selectedItem.title);
}
- (void)changeAPIKey:(id)sender { if (self.changeAPIKeyHandler) self.changeAPIKeyHandler(); }
- (void)showExtensions:(id)sender { if (self.extensionManagerHandler) self.extensionManagerHandler(); }
- (void)toggleLaunchAtLogin:(NSButton *)sender {
    if (self.launchAtLoginHandler) self.launchAtLoginHandler(sender.state == NSControlStateValueOn);
}
- (void)quit:(id)sender { if (self.quitHandler) self.quitHandler(); }

@end
