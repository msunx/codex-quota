#import "CQTheme.h"
#import <QuartzCore/QuartzCore.h>

static NSColor *CQHex(NSUInteger rgb) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xff) / 255.0
                              green:((rgb >> 8) & 0xff) / 255.0
                               blue:(rgb & 0xff) / 255.0
                              alpha:1.0];
}

@implementation CQTheme
+ (NSColor *)base { return CQHex(0xF2F2F0); }
+ (NSColor *)mantle { return CQHex(0xFAFAF8); }
+ (NSColor *)surface { return CQHex(0xE8E8EA); }
+ (NSColor *)panel { return CQHex(0xFFFFFF); }
+ (NSColor *)overlay { return CQHex(0x92939A); }
+ (NSColor *)text { return CQHex(0x18181A); }
+ (NSColor *)subtext { return CQHex(0x66676D); }
+ (NSColor *)lavender { return CQHex(0x7C3AED); }
+ (NSColor *)accent { return CQHex(0x2F7DF6); }
+ (NSColor *)green { return CQHex(0x34A853); }
+ (NSColor *)yellow { return CQHex(0xD97706); }
+ (NSColor *)red { return CQHex(0xE11D48); }
+ (NSColor *)colorForRemaining:(double)remaining {
    if (remaining <= 20.0) return self.red;
    if (remaining <= 50.0) return self.yellow;
    return self.accent;
}
@end

static CAMediaTimingFunction *CQEaseOutTimingFunction(void) {
    return [CAMediaTimingFunction functionWithControlPoints:0.23 :1.0 :0.32 :1.0];
}

@interface CQLiquidGlassView : NSVisualEffectView
@property(nonatomic) CGFloat preferredCornerRadius;
@property(nonatomic) BOOL configuresHostingWindow;
@property(nonatomic, strong) CAGradientLayer *sheenLayer;
@end

@implementation CQLiquidGlassView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) return nil;
    self.wantsLayer = YES;
    _sheenLayer = [CAGradientLayer layer];
    _sheenLayer.startPoint = CGPointMake(0.04, 0.0);
    _sheenLayer.endPoint = CGPointMake(0.96, 1.0);
    _sheenLayer.colors = @[
        (id)[NSColor.whiteColor colorWithAlphaComponent:0.46].CGColor,
        (id)[NSColor.whiteColor colorWithAlphaComponent:0.08].CGColor,
        (id)[CQTheme.accent colorWithAlphaComponent:0.07].CGColor
    ];
    _sheenLayer.locations = @[@0.0, @0.52, @1.0];
    [self.layer addSublayer:_sheenLayer];
    return self;
}

- (void)layout {
    [super layout];
    CGFloat radius = MIN(self.preferredCornerRadius, NSHeight(self.bounds) / 2.0);
    self.layer.cornerRadius = radius;
    self.sheenLayer.frame = self.bounds;
    self.sheenLayer.cornerRadius = radius;
}

- (void)viewWillMoveToWindow:(NSWindow *)newWindow {
    [super viewWillMoveToWindow:newWindow];
    if (self.configuresHostingWindow && newWindow) {
        newWindow.opaque = NO;
        newWindow.backgroundColor = NSColor.clearColor;
    }
}

@end

@interface CQGlassUnderlayView : CQLiquidGlassView
@end

@implementation CQGlassUnderlayView
- (NSView *)hitTest:(NSPoint)point { return nil; }
@end

@interface CQPressButton : NSButton
@property(nonatomic) BOOL usesGlassHover;
@property(nonatomic, strong) NSColor *restingTintColor;
@property(nonatomic, strong) NSColor *hoverTintColor;
@property(nonatomic, strong) CQGlassUnderlayView *hoverGlass;
@property(nonatomic, strong) NSTrackingArea *hoverTrackingArea;
- (void)enableGlassHoverWithRestingTint:(NSColor *)restingTint hoverTint:(NSColor *)hoverTint;
@end

@implementation CQPressButton

- (void)enableGlassHoverWithRestingTint:(NSColor *)restingTint hoverTint:(NSColor *)hoverTint {
    self.usesGlassHover = YES;
    self.restingTintColor = restingTint;
    self.hoverTintColor = hoverTint;
    self.contentTintColor = restingTint;
    [self installHoverGlassIfNeeded];
}

- (void)installHoverGlassIfNeeded {
    if (!self.usesGlassHover || !self.superview || self.hoverGlass.superview == self.superview) return;
    [self.hoverGlass removeFromSuperview];
    CQGlassUnderlayView *glass = [CQGlassUnderlayView new];
    glass.translatesAutoresizingMaskIntoConstraints = NO;
    glass.material = NSVisualEffectMaterialMenu;
    glass.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    glass.state = NSVisualEffectStateFollowsWindowActiveState;
    glass.preferredCornerRadius = 10;
    glass.alphaValue = 0.0;
    BOOL reduceTransparency = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceTransparency;
    glass.layer.backgroundColor = reduceTransparency
        ? [NSColor.whiteColor colorWithAlphaComponent:0.94].CGColor
        : [CQTheme.accent colorWithAlphaComponent:0.09].CGColor;
    glass.layer.borderWidth = 0.7;
    glass.layer.borderColor = [NSColor.whiteColor colorWithAlphaComponent:reduceTransparency ? 0.86 : 0.78].CGColor;
    glass.layer.shadowColor = NSColor.blackColor.CGColor;
    glass.layer.shadowOpacity = 0.10;
    glass.layer.shadowRadius = 7;
    glass.layer.shadowOffset = CGSizeMake(0, -2);
    [self.superview addSubview:glass positioned:NSWindowBelow relativeTo:self];
    [NSLayoutConstraint activateConstraints:@[
        [glass.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:-6],
        [glass.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:6],
        [glass.topAnchor constraintEqualToAnchor:self.topAnchor constant:-3],
        [glass.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:3]
    ]];
    self.hoverGlass = glass;
}

- (void)viewDidMoveToSuperview {
    [super viewDidMoveToSuperview];
    [self installHoverGlassIfNeeded];
}

- (void)viewWillMoveToSuperview:(NSView *)newSuperview {
    if (self.superview && newSuperview != self.superview) [self.hoverGlass removeFromSuperview];
    [super viewWillMoveToSuperview:newSuperview];
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

- (void)setHoverGlassVisible:(BOOL)visible {
    if (!self.usesGlassHover) return;
    [self installHoverGlassIfNeeded];
    BOOL active = visible && self.enabled;
    self.contentTintColor = active ? self.hoverTintColor : self.restingTintColor;
    CGFloat alpha = active ? 1.0 : 0.0;
    if (NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) {
        self.hoverGlass.alphaValue = alpha;
        return;
    }
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = visible ? 0.14 : 0.10;
        context.timingFunction = CQEaseOutTimingFunction();
        self.hoverGlass.animator.alphaValue = alpha;
    } completionHandler:nil];
}

- (void)mouseEntered:(NSEvent *)event {
    [super mouseEntered:event];
    [self setHoverGlassVisible:YES];
}

- (void)mouseExited:(NSEvent *)event {
    [super mouseExited:event];
    [self setHoverGlassVisible:NO];
}

- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    if (!enabled) [self setHoverGlassVisible:NO];
}

- (void)animateToScale:(CGFloat)scale {
    if (NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion || !self.layer) return;
    CALayer *presentation = self.layer.presentationLayer;
    CATransform3D from = presentation ? presentation.transform : self.layer.transform;
    CATransform3D target = CATransform3DMakeScale(scale, scale, 1.0);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.layer.transform = target;
    [CATransaction commit];
    CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"transform"];
    animation.fromValue = [NSValue valueWithCATransform3D:from];
    animation.toValue = [NSValue valueWithCATransform3D:target];
    animation.duration = 0.12;
    animation.timingFunction = CQEaseOutTimingFunction();
    [self.layer addAnimation:animation forKey:@"cq.press"];
}

- (void)mouseDown:(NSEvent *)event {
    if (self.enabled) [self animateToScale:0.97];
    [super mouseDown:event];
    if (self.enabled) [self animateToScale:1.0];
}

@end

NSTextField *CQLabel(NSString *text, NSFont *font, NSColor *color) {
    NSTextField *label = [NSTextField labelWithString:text ?: @""];
    label.font = font;
    label.textColor = color;
    label.drawsBackground = NO;
    label.bordered = NO;
    label.editable = NO;
    label.selectable = NO;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

NSButton *CQButton(NSString *title, NSString *symbolName, id target, SEL action) {
    CQPressButton *button = [CQPressButton buttonWithTitle:title target:target action:action];
    button.wantsLayer = YES;
    button.bordered = NO;
    button.bezelStyle = NSBezelStyleToolbar;
    button.controlSize = NSControlSizeSmall;
    button.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    [button enableGlassHoverWithRestingTint:CQTheme.text hoverTint:CQTheme.accent];
    if (@available(macOS 11.0, *)) {
        NSImage *image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:title];
        button.image = image;
        button.imagePosition = NSImageLeading;
    }
    return button;
}

NSButton *CQQuietButton(NSString *title, NSString *symbolName, id target, SEL action) {
    CQPressButton *button = [CQPressButton buttonWithTitle:title target:target action:action];
    button.wantsLayer = YES;
    button.bordered = NO;
    button.bezelStyle = NSBezelStyleToolbar;
    button.controlSize = NSControlSizeSmall;
    button.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium];
    [button enableGlassHoverWithRestingTint:CQTheme.subtext hoverTint:CQTheme.accent];
    if (@available(macOS 11.0, *)) {
        NSImage *image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:title];
        button.image = image;
        button.imagePosition = NSImageLeading;
    }
    return button;
}

NSButton *CQPrimaryButton(NSString *title, NSString *symbolName, id target, SEL action) {
    CQPressButton *button = [CQPressButton buttonWithTitle:title target:target action:action];
    button.wantsLayer = YES;
    button.bezelStyle = NSBezelStylePush;
    button.controlSize = NSControlSizeSmall;
    button.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightSemibold];
    button.contentTintColor = CQTheme.panel;
    button.bezelColor = CQTheme.text;
    if (@available(macOS 11.0, *)) {
        NSImage *image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:title];
        button.image = image;
        button.imagePosition = NSImageLeading;
    }
    return button;
}

NSView *CQSurface(CGFloat cornerRadius) {
    NSView *view = [NSView new];
    view.wantsLayer = YES;
    view.layer.backgroundColor = [CQTheme.panel colorWithAlphaComponent:0.98].CGColor;
    view.layer.cornerRadius = cornerRadius;
    view.layer.cornerCurve = kCACornerCurveContinuous;
    view.layer.borderWidth = 0.5;
    view.layer.borderColor = [NSColor.blackColor colorWithAlphaComponent:0.07].CGColor;
    view.layer.shadowColor = NSColor.blackColor.CGColor;
    view.layer.shadowOpacity = 0.08;
    view.layer.shadowRadius = 10;
    view.layer.shadowOffset = CGSizeMake(0, -3);
    return view;
}

NSView *CQDashboardGlassSurface(CGFloat cornerRadius) {
    NSView *container = [NSView new];
    container.wantsLayer = YES;
    container.layer.backgroundColor = NSColor.clearColor.CGColor;
    CQLiquidGlassView *backdrop = [CQLiquidGlassView new];
    backdrop.translatesAutoresizingMaskIntoConstraints = NO;
    backdrop.material = NSVisualEffectMaterialHeaderView;
    backdrop.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    backdrop.state = NSVisualEffectStateActive;
    backdrop.preferredCornerRadius = cornerRadius;
    BOOL reduceTransparency = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceTransparency;
    backdrop.alphaValue = 1.0;
    backdrop.layer.backgroundColor = [CQTheme.panel colorWithAlphaComponent:reduceTransparency ? 0.98 : 0.88].CGColor;
    backdrop.layer.borderWidth = 0.7;
    backdrop.layer.borderColor = [NSColor.whiteColor colorWithAlphaComponent:reduceTransparency ? 0.84 : 0.38].CGColor;
    backdrop.layer.shadowColor = NSColor.blackColor.CGColor;
    backdrop.layer.shadowOpacity = 0.08;
    backdrop.layer.shadowRadius = 10;
    backdrop.layer.shadowOffset = CGSizeMake(0, -3);
    backdrop.sheenLayer.colors = @[
        (id)[NSColor.whiteColor colorWithAlphaComponent:0.08].CGColor,
        (id)[NSColor.whiteColor colorWithAlphaComponent:0.01].CGColor,
        (id)[CQTheme.accent colorWithAlphaComponent:0.012].CGColor
    ];
    [container addSubview:backdrop];
    [NSLayoutConstraint activateConstraints:@[
        [backdrop.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [backdrop.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [backdrop.topAnchor constraintEqualToAnchor:container.topAnchor],
        [backdrop.bottomAnchor constraintEqualToAnchor:container.bottomAnchor]
    ]];
    return container;
}

NSVisualEffectView *CQGlassView(NSVisualEffectMaterial material, CGFloat cornerRadius) {
    CQLiquidGlassView *view = [CQLiquidGlassView new];
    view.material = material;
    view.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    view.state = NSVisualEffectStateFollowsWindowActiveState;
    view.wantsLayer = YES;
    view.preferredCornerRadius = cornerRadius;
    BOOL reduceTransparency = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceTransparency;
    view.layer.backgroundColor = [CQTheme.mantle colorWithAlphaComponent:reduceTransparency ? 0.98 : 0.90].CGColor;
    view.layer.cornerRadius = cornerRadius;
    view.layer.cornerCurve = kCACornerCurveContinuous;
    view.layer.borderWidth = 0.7;
    view.layer.borderColor = [NSColor.whiteColor colorWithAlphaComponent:reduceTransparency ? 0.82 : 0.38].CGColor;
    return view;
}

NSView *CQWindowGlassView(void) {
    NSView *container = [NSView new];
    container.wantsLayer = YES;
    container.layer.backgroundColor = NSColor.clearColor.CGColor;
    container.layer.cornerRadius = 18;
    container.layer.cornerCurve = kCACornerCurveContinuous;
    container.layer.masksToBounds = YES;
    CQLiquidGlassView *backdrop = [CQLiquidGlassView new];
    backdrop.translatesAutoresizingMaskIntoConstraints = NO;
    backdrop.material = NSVisualEffectMaterialPopover;
    backdrop.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    backdrop.state = NSVisualEffectStateActive;
    backdrop.preferredCornerRadius = 18;
    backdrop.configuresHostingWindow = YES;
    BOOL reduceTransparency = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceTransparency;
    backdrop.alphaValue = 1.0;
    backdrop.layer.backgroundColor = reduceTransparency
        ? [CQTheme.base colorWithAlphaComponent:0.96].CGColor
        : [CQTheme.base colorWithAlphaComponent:0.82].CGColor;
    backdrop.layer.borderWidth = 0;
    backdrop.sheenLayer.colors = @[
        (id)[NSColor.whiteColor colorWithAlphaComponent:reduceTransparency ? 0.10 : 0.06].CGColor,
        (id)[NSColor.whiteColor colorWithAlphaComponent:0.01].CGColor,
        (id)[CQTheme.accent colorWithAlphaComponent:reduceTransparency ? 0.0 : 0.02].CGColor
    ];
    [container addSubview:backdrop];
    [NSLayoutConstraint activateConstraints:@[
        [backdrop.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [backdrop.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [backdrop.topAnchor constraintEqualToAnchor:container.topAnchor],
        [backdrop.bottomAnchor constraintEqualToAnchor:container.bottomAnchor]
    ]];
    return container;
}
