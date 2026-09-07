#import "CQTheme.h"
#import <QuartzCore/QuartzCore.h>

static NSColor *CQHex(NSUInteger rgb) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xff) / 255.0
                              green:((rgb >> 8) & 0xff) / 255.0
                               blue:(rgb & 0xff) / 255.0
                              alpha:1.0];
}

@implementation CQTheme
+ (NSColor *)base { return CQHex(0xFAFAFB); }
+ (NSColor *)mantle { return CQHex(0xF3F4F6); }
+ (NSColor *)surface { return CQHex(0xE7E9ED); }
+ (NSColor *)panel { return CQHex(0xFFFFFF); }
+ (NSColor *)overlay { return CQHex(0x6B717B); }
+ (NSColor *)text { return CQHex(0x20242C); }
+ (NSColor *)subtext { return CQHex(0x606772); }
+ (NSColor *)lavender { return CQHex(0x606772); }
+ (NSColor *)accent { return CQHex(0x2864D7); }
+ (NSColor *)green { return CQHex(0x237A44); }
+ (NSColor *)yellow { return CQHex(0x9C5F13); }
+ (NSColor *)red { return CQHex(0xC43D4B); }
+ (NSColor *)colorForRemaining:(double)remaining {
    if (remaining <= 20.0) return self.red;
    if (remaining <= 50.0) return self.yellow;
    return self.accent;
}
@end

static CAMediaTimingFunction *CQEaseOutTimingFunction(void) {
    return [CAMediaTimingFunction functionWithControlPoints:0.23 :1.0 :0.32 :1.0];
}

@interface CQPressButton : NSButton
@property(nonatomic, strong) NSTrackingArea *hoverTrackingArea;
@end

@implementation CQPressButton

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.hoverTrackingArea) [self removeTrackingArea:self.hoverTrackingArea];
    self.hoverTrackingArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInActiveApp | NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:self.hoverTrackingArea];
}

- (void)setHovered:(BOOL)hovered {
    self.layer.backgroundColor = (hovered && self.enabled ? CQTheme.surface : NSColor.clearColor).CGColor;
}

- (void)mouseEntered:(NSEvent *)event {
    [super mouseEntered:event];
    [self setHovered:YES];
}

- (void)mouseExited:(NSEvent *)event {
    [super mouseExited:event];
    [self setHovered:NO];
}

- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    if (!enabled) [self setHovered:NO];
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
    button.contentTintColor = CQTheme.text;
    button.layer.cornerRadius = 6;
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
    button.contentTintColor = CQTheme.subtext;
    button.layer.cornerRadius = 6;
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

NSView *CQFooterSurface(void) {
    NSView *view = [NSView new];
    view.wantsLayer = YES;
    view.layer.backgroundColor = CQTheme.mantle.CGColor;
    NSView *divider = [NSView new];
    divider.wantsLayer = YES;
    divider.layer.backgroundColor = (NSWorkspace.sharedWorkspace.accessibilityDisplayShouldIncreaseContrast ? CQTheme.overlay : CQTheme.surface).CGColor;
    divider.translatesAutoresizingMaskIntoConstraints = NO;
    [view addSubview:divider];
    [NSLayoutConstraint activateConstraints:@[
        [divider.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
        [divider.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
        [divider.topAnchor constraintEqualToAnchor:view.topAnchor],
        [divider.heightAnchor constraintEqualToConstant:1]
    ]];
    return view;
}

NSView *CQPanelBackground(void) {
    NSView *view = [NSView new];
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    view.wantsLayer = YES;
    view.layer.backgroundColor = CQTheme.base.CGColor;
    view.layer.cornerRadius = 14;
    view.layer.cornerCurve = kCACornerCurveContinuous;
    view.layer.masksToBounds = YES;
    view.layer.borderWidth = 1;
    view.layer.borderColor = (NSWorkspace.sharedWorkspace.accessibilityDisplayShouldIncreaseContrast ? CQTheme.overlay : CQTheme.surface).CGColor;
    return view;
}
