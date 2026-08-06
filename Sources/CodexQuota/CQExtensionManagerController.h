#import <Cocoa/Cocoa.h>
#import "CQExtensions.h"

NS_ASSUME_NONNULL_BEGIN

@interface CQExtensionManagerController : NSViewController
@property(nonatomic, copy, nullable) void (^backHandler)(void);
- (instancetype)initWithManager:(CQExtensionManager *)manager;
@end

NS_ASSUME_NONNULL_END
