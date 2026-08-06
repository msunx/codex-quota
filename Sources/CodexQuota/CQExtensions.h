#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CQExtensionKind) {
    CQExtensionKindSkill,
    CQExtensionKindPlugin
};

typedef NS_ENUM(NSInteger, CQExtensionUpdateState) {
    CQExtensionUpdateStateUnknown,
    CQExtensionUpdateStateChecking,
    CQExtensionUpdateStateUpToDate,
    CQExtensionUpdateStateUpdateAvailable,
    CQExtensionUpdateStateUntracked,
    CQExtensionUpdateStateUpdating,
    CQExtensionUpdateStateFailed
};

@interface CQExtensionItem : NSObject
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic) CQExtensionKind kind;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *displayName;
@property(nonatomic, copy) NSString *sourceName;
@property(nonatomic, copy) NSString *scopeDetail;
@property(nonatomic, copy) NSString *summaryText;
@property(nonatomic, copy, nullable) NSString *installedVersion;
@property(nonatomic, copy, nullable) NSString *availableVersion;
@property(nonatomic, copy) NSArray<NSString *> *paths;
@property(nonatomic) CQExtensionUpdateState updateState;
@property(nonatomic, copy, nullable) NSString *errorMessage;

@property(nonatomic, copy, nullable) NSString *skillSourceType;
@property(nonatomic, copy, nullable) NSString *skillSource;
@property(nonatomic, copy, nullable) NSString *skillSourceURL;
@property(nonatomic, copy, nullable) NSString *skillPath;
@property(nonatomic, copy, nullable) NSString *skillFolderHash;
@property(nonatomic, copy) NSArray<NSString *> *skillNames;
@property(nonatomic) BOOL larkCLIManaged;
@property(nonatomic) NSUInteger groupedSkillCount;

@property(nonatomic, copy, nullable) NSString *marketplacePath;
@property(nonatomic, copy, nullable) NSString *remoteMarketplaceName;

@property(nonatomic, readonly) BOOL updateAvailable;
@end

@interface CQExtensionManager : NSObject
@property(nonatomic, copy, readonly) NSArray<CQExtensionItem *> *items;
@property(nonatomic, readonly, getter=isChecking) BOOL checking;
@property(nonatomic, readonly, getter=isUpdating) BOOL updating;
@property(nonatomic, readonly, getter=isUninstalling) BOOL uninstalling;
@property(nonatomic, strong, readonly, nullable) NSDate *updatedAt;
@property(nonatomic, copy, readonly, nullable) NSString *lastError;
@property(nonatomic, copy, nullable) void (^changeHandler)(void);

- (instancetype)initWithCodexURL:(NSURL * _Nullable)codexURL;
- (void)setCodexURL:(NSURL * _Nullable)codexURL;
- (void)loadInstalledExtensions;
- (void)checkForUpdates;
- (void)updateItem:(CQExtensionItem *)item;
- (void)uninstallItem:(CQExtensionItem *)item completion:(void (^)(NSError * _Nullable error))completion;
- (void)startPeriodicChecks;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
