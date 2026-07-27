#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CQRateLimitWindow : NSObject
@property(nonatomic, copy) NSString *limitID;
@property(nonatomic, copy) NSString *name;
@property(nonatomic) double usedPercent;
@property(nonatomic) NSInteger durationMinutes;
@property(nonatomic, strong, nullable) NSDate *resetsAt;
@property(nonatomic, readonly) double remainingPercent;
@end

@interface CQQuotaSnapshot : NSObject
@property(nonatomic, copy) NSArray<CQRateLimitWindow *> *windows;
@property(nonatomic, copy) NSString *planType;
@property(nonatomic, strong, nullable) NSNumber *resetCreditsAvailable;
@property(nonatomic) BOOL hasWorkspaceCredits;
@property(nonatomic) BOOL workspaceUnlimited;
@property(nonatomic, copy, nullable) NSString *workspaceBalance;
@property(nonatomic, strong) NSDate *updatedAt;

+ (instancetype)snapshotFromRateLimitsResult:(NSDictionary *)result;
- (double)minimumRemainingPercent;
@end

FOUNDATION_EXPORT NSString *CQDurationLabel(NSInteger minutes);
FOUNDATION_EXPORT NSString *CQAbsoluteDateString(NSDate *date);
FOUNDATION_EXPORT NSString *CQRelativeDateString(NSDate *date);

NS_ASSUME_NONNULL_END
