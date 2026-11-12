#import "CQMenuBarStatusView.h"
#import "CQTheme.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>

static CGFloat const CQMenuBarIconWidth = 24.0;
static CGFloat const CQMenuBarIconHeight = 22.0;
static CGFloat const CQMenuBarMetricGap = 6.0;
static CGFloat const CQMenuBarTaskIndicatorSize = 12.0;
static CGFloat const CQMenuBarTaskIndicatorGap = 1.0;
static NSString * const CQMenuBarRotationAnimationKey = @"CQMenuBarRunningRotation";

@interface CQMenuBarIconView : NSView
@property(nonatomic) double remainingPercent;
@end

@implementation CQMenuBarIconView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _remainingPercent = NAN;
        self.accessibilityElement = NO;
        self.wantsLayer = YES;
    }
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)setRemainingPercent:(double)remainingPercent {
    if (_remainingPercent == remainingPercent || (isnan(_remainingPercent) && isnan(remainingPercent))) return;
    _remainingPercent = remainingPercent;
    self.needsDisplay = YES;
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSBezierPath *brackets = [NSBezierPath bezierPath];
    [brackets moveToPoint:NSMakePoint(5.2, 5.5)];
    [brackets lineToPoint:NSMakePoint(1.5, 11.0)];
    [brackets lineToPoint:NSMakePoint(5.2, 16.5)];
    [brackets moveToPoint:NSMakePoint(18.8, 5.5)];
    [brackets lineToPoint:NSMakePoint(22.5, 11.0)];
    [brackets lineToPoint:NSMakePoint(18.8, 16.5)];
    brackets.lineWidth = 1.9;
    brackets.lineCapStyle = NSLineCapStyleRound;
    brackets.lineJoinStyle = NSLineJoinStyleRound;
    [CQTheme.menuBarText setStroke];
    [brackets stroke];

    CGFloat tops[] = {12.0, 8.5, 5.0};
    for (NSUInteger index = 0; index < 3; index++) {
        CGFloat x = 9.0 + index * 3.0;
        NSBezierPath *track = [NSBezierPath bezierPath];
        [track moveToPoint:NSMakePoint(x, 17.0)];
        [track lineToPoint:NSMakePoint(x, tops[index])];
        track.lineWidth = 1.9;
        track.lineCapStyle = NSLineCapStyleRound;
        [CQTheme.menuBarTrack setStroke];
        [track stroke];
        if (!isfinite(self.remainingPercent)) continue;

        NSColor *color = [CQTheme menuBarColorForRemaining:self.remainingPercent];
        if (self.remainingPercent <= 0.0) {
            [color setFill];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x - 1.0, 16.0, 2.0, 2.0)] fill];
        } else {
            NSBezierPath *progress = [NSBezierPath bezierPath];
            [progress moveToPoint:NSMakePoint(x, 17.0)];
            [progress lineToPoint:NSMakePoint(x, 17.0 - (17.0 - tops[index]) * self.remainingPercent / 100.0)];
            progress.lineWidth = 2.0;
            progress.lineCapStyle = NSLineCapStyleRound;
            [color setStroke];
            [progress stroke];
        }
    }
}

@end

@interface CQMenuBarTaskView : NSView
@property(nonatomic, copy) NSAttributedString *title;
@property(nonatomic) BOOL showsRunningIndicator;
@property(nonatomic, readonly) CGFloat preferredWidth;
@property(nonatomic, strong) CAShapeLayer *ringTrackLayer;
@property(nonatomic, strong) CAShapeLayer *ringArcLayer;
@end

@implementation CQMenuBarTaskView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _title = [[NSAttributedString alloc] initWithString:@""];
        self.accessibilityElement = NO;
        self.wantsLayer = YES;
        _ringTrackLayer = [CAShapeLayer layer];
        _ringArcLayer = [CAShapeLayer layer];
        CGPathRef circle = CGPathCreateWithEllipseInRect(CGRectMake(1, 1, 10, 10), NULL);
        for (CAShapeLayer *ringLayer in @[_ringTrackLayer, _ringArcLayer]) {
            ringLayer.path = circle;
            ringLayer.fillColor = NSColor.clearColor.CGColor;
            ringLayer.hidden = YES;
            [self.layer addSublayer:ringLayer];
        }
        CGPathRelease(circle);
        _ringTrackLayer.lineWidth = 1.7;
        _ringTrackLayer.opacity = 0.23;
        _ringArcLayer.lineWidth = 1.9;
        _ringArcLayer.lineCap = kCALineCapRound;
        _ringArcLayer.strokeEnd = 1.0 / M_PI;
        [self layoutIndicator];
        [self updateIndicatorAppearance];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)setTitle:(NSAttributedString *)title {
    if ([_title isEqualToAttributedString:title]) return;
    _title = [title copy];
    self.needsDisplay = YES;
    [self updateIndicatorAppearance];
}

- (CGFloat)preferredWidth {
    return (self.showsRunningIndicator ? CQMenuBarTaskIndicatorSize + CQMenuBarTaskIndicatorGap : 0) + ceil(self.title.size.width);
}

- (void)setShowsRunningIndicator:(BOOL)showsRunningIndicator {
    if (_showsRunningIndicator == showsRunningIndicator) return;
    _showsRunningIndicator = showsRunningIndicator;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.ringTrackLayer.hidden = !showsRunningIndicator;
    self.ringArcLayer.hidden = !showsRunningIndicator;
    [CATransaction commit];
    self.needsDisplay = YES;
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self layoutIndicator];
}

- (void)layoutIndicator {
    if (!self.ringArcLayer) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (CAShapeLayer *ringLayer in @[self.ringTrackLayer, self.ringArcLayer]) {
        ringLayer.bounds = CGRectMake(0, 0, CQMenuBarTaskIndicatorSize, CQMenuBarTaskIndicatorSize);
        ringLayer.position = CGPointMake(CQMenuBarTaskIndicatorSize / 2.0, floor((NSHeight(self.bounds) - CQMenuBarTaskIndicatorSize) / 2.0) + CQMenuBarTaskIndicatorSize / 2.0);
    }
    [CATransaction commit];
}

- (void)updateIndicatorAppearance {
    if (!self.ringArcLayer) return;
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        NSColor *color = self.title.length > 0 ? [self.title attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL] : CQTheme.menuBarAccent;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        for (CAShapeLayer *ringLayer in @[self.ringTrackLayer, self.ringArcLayer]) {
            ringLayer.strokeColor = color.CGColor;
            ringLayer.contentsScale = self.window.backingScaleFactor ?: 2.0;
        }
        [CATransaction commit];
    }];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self updateIndicatorAppearance];
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    [self updateIndicatorAppearance];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self updateIndicatorAppearance];
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGFloat titleY = floor((NSHeight(self.bounds) - self.title.size.height) / 2.0);
    CGFloat titleX = self.showsRunningIndicator ? CQMenuBarTaskIndicatorSize + CQMenuBarTaskIndicatorGap : 0;
    [self.title drawAtPoint:NSMakePoint(titleX, titleY)];
}

@end

@interface CQMenuBarStatusView ()
@property(nonatomic, copy) NSAttributedString *statusTitle;
@property(nonatomic, strong) CQMenuBarIconView *iconView;
@property(nonatomic, strong) CQMenuBarTaskView *taskView;
@end

@implementation CQMenuBarStatusView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.accessibilityElement = NO;
        self.iconView = [[CQMenuBarIconView alloc] initWithFrame:NSMakeRect(0, floor((NSHeight(self.bounds) - CQMenuBarIconHeight) / 2.0), CQMenuBarIconWidth, CQMenuBarIconHeight)];
        [self addSubview:self.iconView];
        self.taskView = [[CQMenuBarTaskView alloc] initWithFrame:NSZeroRect];
        [self addSubview:self.taskView];
        [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(accessibilityDisplayOptionsDidChange:)
            name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification object:nil];
        [self updateMetric:@"…" remainingPercent:NAN taskSuffix:@"" taskColor:nil];
    }
    return self;
}

- (void)dealloc {
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
}

- (BOOL)isFlipped { return YES; }

- (NSView *)hitTest:(NSPoint)point {
    (void)point;
    // The native status bar button retains all mouse and keyboard behavior.
    return nil;
}

- (CGFloat)preferredWidth {
    return ceil(CQMenuBarIconWidth + CQMenuBarMetricGap + self.statusTitle.size.width) + self.taskView.preferredWidth;
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    self.iconView.frame = NSMakeRect(0, floor((newSize.height - CQMenuBarIconHeight) / 2.0), CQMenuBarIconWidth, CQMenuBarIconHeight);
    [self layoutTaskSummary];
}

- (void)layoutTaskSummary {
    CGFloat taskX = ceil(CQMenuBarIconWidth + CQMenuBarMetricGap + self.statusTitle.size.width);
    self.taskView.frame = NSMakeRect(taskX, 0, self.taskView.preferredWidth, NSHeight(self.bounds));
}

- (void)setRunning:(BOOL)running {
    if (_running == running) return;
    _running = running;
    [self updateRunningAnimation];
}

- (void)updateRunningAnimation {
    CALayer *arcLayer = self.taskView.ringArcLayer;
    BOOL shouldRotate = self.isRunning && self.taskView.showsRunningIndicator && self.window && !self.isHiddenOrHasHiddenAncestor && !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    if (!shouldRotate) {
        [arcLayer removeAnimationForKey:CQMenuBarRotationAnimationKey];
        return;
    }
    if ([arcLayer animationForKey:CQMenuBarRotationAnimationKey]) return;
    CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    animation.fromValue = @0.0;
    animation.toValue = @(2.0 * M_PI);
    animation.duration = 1.8;
    animation.repeatCount = HUGE_VALF;
    animation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
    animation.beginTime = [arcLayer convertTime:CACurrentMediaTime() fromLayer:nil];
    [arcLayer addAnimation:animation forKey:CQMenuBarRotationAnimationKey];
}

- (void)accessibilityDisplayOptionsDidChange:(NSNotification *)notification {
    (void)notification;
    [self updateRunningAnimation];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self updateRunningAnimation];
}

- (void)viewDidHide {
    [super viewDidHide];
    [self updateRunningAnimation];
}

- (void)viewDidUnhide {
    [super viewDidUnhide];
    [self updateRunningAnimation];
}

- (void)updateMetric:(NSString *)metric remainingPercent:(double)remainingPercent taskSuffix:(NSString *)taskSuffix taskColor:(NSColor *)taskColor {
    self.iconView.remainingPercent = isfinite(remainingPercent) ? fmin(100.0, fmax(0.0, remainingPercent)) : NAN;
    NSString *value = metric.length > 0 ? metric : @"—";
    NSMutableAttributedString *title = [[NSMutableAttributedString alloc] initWithString:value attributes:@{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: CQTheme.menuBarText
    }];
    if ([value hasSuffix:@"%"]) {
        [title addAttribute:NSFontAttributeName value:[NSFont systemFontOfSize:9 weight:NSFontWeightMedium] range:NSMakeRange(value.length - 1, 1)];
        if (value.length > 1) [title addAttribute:NSKernAttributeName value:@1 range:NSMakeRange(value.length - 2, 1)];
    }
    NSString *taskText = [taskSuffix stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" ·"]];
    if (taskText.length > 0) {
        [title appendAttributedString:[[NSAttributedString alloc] initWithString:@" · " attributes:@{
            NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: CQTheme.menuBarTrack
        }]];
    }
    self.statusTitle = title;
    self.taskView.showsRunningIndicator = [taskText hasPrefix:@"●"] && taskText.length > 1;
    if (self.taskView.showsRunningIndicator) taskText = [taskText substringFromIndex:1];
    self.taskView.title = [[NSAttributedString alloc] initWithString:taskText attributes:@{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: taskColor ?: CQTheme.menuBarText
    }];
    [self layoutTaskSummary];
    [self updateRunningAnimation];
    [self invalidateIntrinsicContentSize];
    self.needsDisplay = YES;
}

- (NSSize)intrinsicContentSize { return NSMakeSize(self.preferredWidth, CQMenuBarIconHeight); }

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGFloat titleY = floor((NSHeight(self.bounds) - self.statusTitle.size.height) / 2.0);
    [self.statusTitle drawAtPoint:NSMakePoint(CQMenuBarIconWidth + CQMenuBarMetricGap, titleY)];
}

@end
