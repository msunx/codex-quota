#import "CQTheme.h"

static NSColor *CQHex(NSUInteger rgb) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xff) / 255.0
                              green:((rgb >> 8) & 0xff) / 255.0
                               blue:(rgb & 0xff) / 255.0
                              alpha:1.0];
}

@implementation CQTheme
+ (NSColor *)base { return CQHex(0x24273A); }
+ (NSColor *)mantle { return CQHex(0x1E2030); }
+ (NSColor *)surface { return CQHex(0x363A4F); }
+ (NSColor *)overlay { return CQHex(0x6E738D); }
+ (NSColor *)text { return CQHex(0xCAD3F5); }
+ (NSColor *)subtext { return CQHex(0xA5ADCB); }
+ (NSColor *)lavender { return CQHex(0xB7BDF8); }
+ (NSColor *)accent { return CQHex(0xC59FF7); }
+ (NSColor *)yellow { return CQHex(0xEED49F); }
+ (NSColor *)red { return CQHex(0xED8796); }
+ (NSColor *)colorForRemaining:(double)remaining {
    if (remaining <= 20.0) return self.red;
    if (remaining <= 50.0) return self.yellow;
    return self.accent;
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
    NSButton *button = [NSButton buttonWithTitle:title target:target action:action];
    button.bezelStyle = NSBezelStyleRecessed;
    button.controlSize = NSControlSizeSmall;
    button.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    button.contentTintColor = CQTheme.lavender;
    if (@available(macOS 11.0, *)) {
        NSImage *image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:title];
        button.image = image;
        button.imagePosition = NSImageLeading;
    }
    return button;
}
