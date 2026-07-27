#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface CQTheme : NSObject
+ (NSColor *)base;
+ (NSColor *)mantle;
+ (NSColor *)surface;
+ (NSColor *)overlay;
+ (NSColor *)text;
+ (NSColor *)subtext;
+ (NSColor *)lavender;
+ (NSColor *)accent;
+ (NSColor *)yellow;
+ (NSColor *)red;
+ (NSColor *)colorForRemaining:(double)remaining;
@end

FOUNDATION_EXPORT NSTextField *CQLabel(NSString *text, NSFont *font, NSColor *color);
FOUNDATION_EXPORT NSButton *CQButton(NSString *title, NSString *symbolName, id target, SEL action);

NS_ASSUME_NONNULL_END
