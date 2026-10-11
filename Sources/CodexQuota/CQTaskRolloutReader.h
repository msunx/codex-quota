#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Used only on the task monitor's serial query queue. Retains lifecycle metadata, never conversation content.
@interface CQTaskRolloutReader : NSObject
- (nullable NSDictionary *)latestTurnForThread:(NSString *)threadID rolloutPath:(NSString *)path;
- (void)retainThreads:(NSSet<NSString *> *)threadIDs;
@end

NS_ASSUME_NONNULL_END
