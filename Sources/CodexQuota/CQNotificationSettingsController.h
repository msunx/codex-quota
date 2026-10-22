#import <Cocoa/Cocoa.h>
#import "CQBarkNotificationService.h"

NS_ASSUME_NONNULL_BEGIN

@interface CQNotificationSettingsController : NSViewController
@property(nonatomic, copy, nullable) void (^backHandler)(void);
- (instancetype)initWithBarkService:(nullable CQBarkNotificationService *)service;
@end

NS_ASSUME_NONNULL_END
