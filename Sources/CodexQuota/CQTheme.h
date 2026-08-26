#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface CQTheme : NSObject
+ (NSColor *)base;
+ (NSColor *)mantle;
+ (NSColor *)surface;
+ (NSColor *)panel;
+ (NSColor *)overlay;
+ (NSColor *)text;
+ (NSColor *)subtext;
+ (NSColor *)lavender;
+ (NSColor *)accent;
+ (NSColor *)green;
+ (NSColor *)yellow;
+ (NSColor *)red;
+ (NSColor *)colorForRemaining:(double)remaining;
@end

FOUNDATION_EXPORT NSTextField *CQLabel(NSString *text, NSFont *font, NSColor *color);
FOUNDATION_EXPORT NSButton *CQButton(NSString *title, NSString *symbolName, id target, SEL action);
FOUNDATION_EXPORT NSButton *CQQuietButton(NSString *title, NSString *symbolName, id target, SEL action);
FOUNDATION_EXPORT NSButton *CQPrimaryButton(NSString *title, NSString *symbolName, id target, SEL action);
FOUNDATION_EXPORT NSView *CQSurface(CGFloat cornerRadius);
FOUNDATION_EXPORT NSView *CQDashboardGlassSurface(CGFloat cornerRadius);
FOUNDATION_EXPORT NSVisualEffectView *CQGlassView(NSVisualEffectMaterial material, CGFloat cornerRadius);
FOUNDATION_EXPORT NSView *CQWindowGlassView(void);

NS_ASSUME_NONNULL_END
