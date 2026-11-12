#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface CQMenuBarStatusView : NSView
@property(nonatomic, readonly) CGFloat preferredWidth;
@property(nonatomic, getter=isRunning) BOOL running;
- (void)updateMetric:(NSString *)metric remainingPercent:(double)remainingPercent taskSuffix:(NSString *)taskSuffix taskColor:(nullable NSColor *)taskColor;
@end

NS_ASSUME_NONNULL_END
