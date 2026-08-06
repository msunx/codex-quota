#import <Foundation/Foundation.h>
#import "CQModels.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^CQClientReadyBlock)(NSError * _Nullable error);
typedef void (^CQSnapshotBlock)(CQQuotaSnapshot * _Nullable snapshot, NSError * _Nullable error);
typedef void (^CQClientDictionaryBlock)(NSDictionary * _Nullable result, NSError * _Nullable error);

@interface CQCodexClient : NSObject
@property(nonatomic, copy, nullable) void (^snapshotDidUpdate)(CQQuotaSnapshot *snapshot);
@property(nonatomic, copy, nullable) void (^processDidExit)(NSError *error);
@property(nonatomic, readonly, getter=isRunning) BOOL running;

- (void)startAtURL:(NSURL *)url completion:(CQClientReadyBlock)completion;
- (void)stop;
- (void)refresh:(CQSnapshotBlock)completion;
- (void)readAccount:(void (^)(NSDictionary * _Nullable account, NSError * _Nullable error))completion;
- (void)startChatGPTLogin:(void (^)(NSURL * _Nullable url, NSError * _Nullable error))completion;
- (void)listSkillsAtWorkingDirectory:(NSString *)workingDirectory
                         forceReload:(BOOL)forceReload
                          completion:(CQClientDictionaryBlock)completion;
- (void)listPluginsAtWorkingDirectory:(NSString *)workingDirectory
                          forceRefetch:(BOOL)forceRefetch
                            completion:(CQClientDictionaryBlock)completion;
- (void)installPluginNamed:(NSString *)pluginName
           marketplacePath:(NSString * _Nullable)marketplacePath
      remoteMarketplaceName:(NSString * _Nullable)remoteMarketplaceName
                 completion:(CQClientDictionaryBlock)completion;
@end

NS_ASSUME_NONNULL_END
