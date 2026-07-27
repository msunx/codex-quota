#import <Cocoa/Cocoa.h>
#import "CQModels.h"

NS_ASSUME_NONNULL_BEGIN

@interface CQPopoverController : NSViewController
@property(nonatomic, copy, nullable) void (^refreshHandler)(void);
@property(nonatomic, copy, nullable) void (^loginHandler)(void);
@property(nonatomic, copy, nullable) void (^chooseCodexHandler)(void);
@property(nonatomic, copy, nullable) void (^launchAtLoginHandler)(BOOL enabled);
@property(nonatomic, copy, nullable) void (^quitHandler)(void);

- (void)renderSnapshot:(CQQuotaSnapshot * _Nullable)snapshot
                status:(NSString *)status
                detail:(NSString *)detail
                 error:(NSString * _Nullable)error
             refreshing:(BOOL)refreshing
              signedOut:(BOOL)signedOut
          launchAtLogin:(BOOL)launchAtLogin;
@end

NS_ASSUME_NONNULL_END
