#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CQProviderMode) {
    CQProviderModeCodex,
    CQProviderModeDeepSeek
};

FOUNDATION_EXPORT NSString * const CQDeepSeekFlashModel;
FOUNDATION_EXPORT NSString * const CQDeepSeekProModel;

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

@interface CQDeepSeekBalanceInfo : NSObject
@property(nonatomic, copy) NSString *currency;
@property(nonatomic, copy) NSString *totalBalance;
@property(nonatomic, copy) NSString *grantedBalance;
@property(nonatomic, copy) NSString *toppedUpBalance;
@property(nonatomic, readonly) NSString *displayValue;
@end

@interface CQDeepSeekBalance : NSObject
@property(nonatomic) BOOL available;
@property(nonatomic, copy) NSArray<CQDeepSeekBalanceInfo *> *balanceInfos;
@property(nonatomic, strong) NSDate *updatedAt;

+ (instancetype)balanceFromResponse:(NSDictionary *)response;
- (nullable CQDeepSeekBalanceInfo *)preferredBalanceInfo;
- (NSString *)displayValue;
@end

FOUNDATION_EXPORT NSString *CQDurationLabel(NSInteger minutes);
FOUNDATION_EXPORT NSString *CQAbsoluteDateString(NSDate *date);
FOUNDATION_EXPORT NSString *CQRelativeDateString(NSDate *date);

NS_ASSUME_NONNULL_END
