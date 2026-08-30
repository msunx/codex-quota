#import <Foundation/Foundation.h>
#import "CQModels.h"

NS_ASSUME_NONNULL_BEGIN

@interface CQCodexConfigManager : NSObject
@property(nonatomic, readonly) CQProviderMode currentMode;
@property(nonatomic, readonly) NSString *currentDeepSeekModel;
@property(nonatomic, readonly) NSString *currentGLMModel;
@property(nonatomic, readonly, nullable) NSString *savedDeepSeekAPIKey;
@property(nonatomic, readonly, nullable) NSString *savedGLMAPIKey;
@property(nonatomic, readonly) NSURL *codexHomeURL;
@property(nonatomic, readonly) BOOL managedConfigurationNeedsHistoryMigration;

- (BOOL)switchToDeepSeekModel:(NSString *)model
                       apiKey:(NSString *)apiKey
                        error:(NSError **)error;
- (BOOL)switchToGLMModel:(NSString *)model
                  apiKey:(NSString *)apiKey
                   error:(NSError **)error;
- (BOOL)switchToCodexWithError:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
