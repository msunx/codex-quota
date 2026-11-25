#import "CQModels.h"

@implementation CQRateLimitWindow
- (double)remainingPercent {
    return MAX(0.0, MIN(100.0, 100.0 - self.usedPercent));
}
@end

static NSNumber *CQNumber(id value) {
    if ([value isKindOfClass:NSNumber.class]) return value;
    if ([value isKindOfClass:NSString.class]) {
        NSNumberFormatter *formatter = [NSNumberFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        return [formatter numberFromString:value];
    }
    return nil;
}

static NSString *CQString(id value) {
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSNumber.class]) return [value stringValue];
    return nil;
}

static NSDate *CQDateFromValue(id value) {
    NSNumber *number = CQNumber(value);
    if (number) {
        NSTimeInterval seconds = number.doubleValue;
        if (seconds > 100000000000.0) seconds /= 1000.0;
        return [NSDate dateWithTimeIntervalSince1970:seconds];
    }
    if ([value isKindOfClass:NSString.class]) {
        NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
        return [formatter dateFromString:value];
    }
    return nil;
}

static void CQCollectBucket(NSDictionary *bucket,
                            NSString *fallbackID,
                            NSMutableArray<CQRateLimitWindow *> *output) {
    if (![bucket isKindOfClass:NSDictionary.class]) return;
    NSString *limitID = CQString(bucket[@"limitId"]) ?: fallbackID ?: @"default";
    NSString *limitName = CQString(bucket[@"limitName"]) ?: CQString(bucket[@"name"]) ?: @"Codex";
    NSArray<NSArray *> *pairs = @[
        @[@"primary", bucket[@"primary"] ?: NSNull.null],
        @[@"secondary", bucket[@"secondary"] ?: NSNull.null]
    ];
    for (NSArray *pair in pairs) {
        NSString *kind = pair[0];
        id rawWindow = pair[1];
        if (![rawWindow isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *window = rawWindow;
        NSNumber *used = CQNumber(window[@"usedPercent"]);
        NSNumber *duration = CQNumber(window[@"windowDurationMins"]);
        if (!used || !duration) continue;

        CQRateLimitWindow *model = [CQRateLimitWindow new];
        model.limitID = [NSString stringWithFormat:@"%@-%@", limitID, kind];
        model.usedPercent = MAX(0.0, MIN(100.0, used.doubleValue));
        model.durationMinutes = MAX(0, duration.integerValue);
        model.resetsAt = CQDateFromValue(window[@"resetsAt"]);
        NSString *durationText = CQDurationLabel(model.durationMinutes);
        model.name = limitName.length > 0
            ? [NSString stringWithFormat:@"%@ · %@", limitName, durationText]
            : durationText;
        [output addObject:model];
    }
}

static NSDictionary *CQCreditsDictionary(NSDictionary *result) {
    id credits = result[@"credits"];
    if ([credits isKindOfClass:NSDictionary.class]) return credits;
    NSDictionary *rateLimits = [result[@"rateLimits"] isKindOfClass:NSDictionary.class] ? result[@"rateLimits"] : nil;
    credits = rateLimits[@"credits"];
    return [credits isKindOfClass:NSDictionary.class] ? credits : nil;
}

@implementation CQQuotaSnapshot

+ (instancetype)snapshotFromRateLimitsResult:(NSDictionary *)result {
    CQQuotaSnapshot *snapshot = [CQQuotaSnapshot new];
    snapshot.updatedAt = NSDate.date;
    NSMutableArray<CQRateLimitWindow *> *windows = [NSMutableArray array];

    id primary = result[@"rateLimits"];
    if ([primary isKindOfClass:NSDictionary.class]) {
        CQCollectBucket(primary, @"default", windows);
    } else if ([primary isKindOfClass:NSArray.class]) {
        for (id value in primary) {
            if ([value isKindOfClass:NSDictionary.class]) CQCollectBucket(value, @"default", windows);
        }
    }

    id byID = result[@"rateLimitsByLimitId"];
    if ([byID isKindOfClass:NSDictionary.class]) {
        [(NSDictionary *)byID enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            (void)stop;
            if ([value isKindOfClass:NSDictionary.class]) {
                CQCollectBucket(value, CQString(key) ?: @"limit", windows);
            }
        }];
    }

    NSMutableDictionary<NSString *, CQRateLimitWindow *> *deduplicated = [NSMutableDictionary dictionary];
    for (CQRateLimitWindow *window in windows) {
        long long resetKey = (long long)window.resetsAt.timeIntervalSince1970;
        NSString *key = [NSString stringWithFormat:@"%@-%ld-%lld",
                         window.limitID, (long)window.durationMinutes, resetKey];
        deduplicated[key] = window;
    }
    snapshot.windows = [deduplicated.allValues sortedArrayUsingComparator:^NSComparisonResult(CQRateLimitWindow *a, CQRateLimitWindow *b) {
        if (a.durationMinutes < b.durationMinutes) return NSOrderedAscending;
        if (a.durationMinutes > b.durationMinutes) return NSOrderedDescending;
        return [a.name compare:b.name];
    }];

    NSDictionary *rateLimits = [primary isKindOfClass:NSDictionary.class] ? primary : nil;
    snapshot.planType = CQString(result[@"planType"])
        ?: CQString(rateLimits[@"planType"])
        ?: @"";

    NSDictionary *resetCredits = [result[@"rateLimitResetCredits"] isKindOfClass:NSDictionary.class]
        ? result[@"rateLimitResetCredits"]
        : ([result[@"resetCredits"] isKindOfClass:NSDictionary.class] ? result[@"resetCredits"] : nil);
    snapshot.resetCreditsAvailable = CQNumber(resetCredits[@"availableCount"])
        ?: CQNumber(result[@"availableCount"])
        ?: CQNumber(rateLimits[@"availableCount"]);

    NSDictionary *credits = CQCreditsDictionary(result);
    if (credits) {
        snapshot.hasWorkspaceCredits = YES;
        NSNumber *hasCredits = CQNumber(credits[@"hasCredits"]);
        NSNumber *unlimited = CQNumber(credits[@"unlimited"]);
        snapshot.workspaceUnlimited = unlimited.boolValue;
        if (hasCredits && !hasCredits.boolValue && !snapshot.workspaceUnlimited) {
            snapshot.workspaceBalance = @"0";
        } else {
            snapshot.workspaceBalance = CQString(credits[@"balance"])
                ?: CQString(credits[@"availableBalance"]);
        }
    }
    return snapshot;
}

- (double)minimumRemainingPercent {
    if (self.windows.count == 0) return NAN;
    double minimum = 100.0;
    for (CQRateLimitWindow *window in self.windows) {
        minimum = MIN(minimum, window.remainingPercent);
    }
    return minimum;
}

@end

NSString *CQDurationLabel(NSInteger minutes) {
    if (minutes <= 0) return @"额度窗口";
    if (minutes % (60 * 24) == 0) {
        return [NSString stringWithFormat:@"%ld 天", (long)(minutes / (60 * 24))];
    }
    if (minutes % 60 == 0) {
        return [NSString stringWithFormat:@"%ld 小时", (long)(minutes / 60)];
    }
    return [NSString stringWithFormat:@"%ld 分钟", (long)minutes];
}

NSString *CQAbsoluteDateString(NSDate *date) {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    formatter.dateFormat = @"M月d日 HH:mm";
    return [formatter stringFromDate:date];
}

NSString *CQRelativeDateString(NSDate *date) {
    NSTimeInterval interval = [date timeIntervalSinceNow];
    if (interval <= 0) return @"即将重置";
    NSInteger minutes = (NSInteger)ceil(interval / 60.0);
    if (minutes < 60) return [NSString stringWithFormat:@"%ld 分钟后", (long)minutes];
    NSInteger hours = minutes / 60;
    if (hours < 24) return [NSString stringWithFormat:@"%ld 小时后", (long)hours];
    NSInteger days = hours / 24;
    return [NSString stringWithFormat:@"%ld 天后", (long)days];
}
