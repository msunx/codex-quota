#import <Cocoa/Cocoa.h>
#import "CQModels.h"
#import "CQTaskMonitor.h"

NS_ASSUME_NONNULL_BEGIN

@interface CQPopoverController : NSViewController
@property(nonatomic, copy, nullable) void (^refreshHandler)(void);
@property(nonatomic, copy, nullable) void (^loginHandler)(void);
@property(nonatomic, copy, nullable) void (^chooseCodexHandler)(void);
@property(nonatomic, copy, nullable) void (^extensionManagerHandler)(void);
@property(nonatomic, copy, nullable) void (^notificationSettingsHandler)(void);
@property(nonatomic, copy, nullable) void (^launchAtLoginHandler)(BOOL enabled);
@property(nonatomic, copy, nullable) void (^taskSelectedHandler)(CQCodexTask *task);
@property(nonatomic, copy, nullable) void (^markAllTasksViewedHandler)(void);
@property(nonatomic, copy, nullable) void (^quitHandler)(void);

- (void)renderSnapshot:(CQQuotaSnapshot * _Nullable)snapshot
          taskSnapshot:(CQTaskSnapshot * _Nullable)taskSnapshot
                status:(NSString *)status
                detail:(NSString *)detail
                 error:(NSString * _Nullable)error
             refreshing:(BOOL)refreshing
              signedOut:(BOOL)signedOut
          launchAtLogin:(BOOL)launchAtLogin;
@end

NS_ASSUME_NONNULL_END
