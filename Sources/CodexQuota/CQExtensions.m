#import "CQExtensions.h"
#import "CQCodexClient.h"

static NSString * const CQExtensionsLastCheckKey = @"CQExtensionsLastCheck";
static NSString * const CQExtensionErrorDomain = @"com.muyang.codexquota.extensions";
static NSTimeInterval const CQExtensionCheckInterval = 6 * 60 * 60;

static NSString *CQExtensionString(id value) {
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSNumber.class]) return [value stringValue];
    return nil;
}

static NSDictionary *CQExtensionDictionary(id value) {
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static NSArray *CQExtensionArray(id value) {
    return [value isKindOfClass:NSArray.class] ? value : @[];
}

static NSString *CQTrimmedYAMLValue(NSString *value) {
    NSString *trimmed = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length >= 2) {
        unichar first = [trimmed characterAtIndex:0];
        unichar last = [trimmed characterAtIndex:trimmed.length - 1];
        if ((first == '"' && last == '"') || (first == '\'' && last == '\'')) {
            trimmed = [trimmed substringWithRange:NSMakeRange(1, trimmed.length - 2)];
        }
    }
    return trimmed;
}

static NSString *CQSkillFrontmatterValue(NSData *data, NSString *key) {
    if (data.length == 0) return nil;
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text.length == 0 || ![text hasPrefix:@"---"]) return nil;
    NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    BOOL inside = NO;
    for (NSUInteger index = 0; index < MIN(lines.count, 120); index++) {
        NSString *line = lines[index];
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([trimmed isEqualToString:@"---"]) {
            if (inside) break;
            inside = YES;
            continue;
        }
        if (!inside) continue;
        NSRange separator = [trimmed rangeOfString:@":"];
        if (separator.location == NSNotFound) continue;
        NSString *candidate = [trimmed substringToIndex:separator.location];
        if (![candidate isEqualToString:key]) continue;
        NSString *value = CQTrimmedYAMLValue([trimmed substringFromIndex:separator.location + 1]);
        if (![value hasPrefix:@">"] && ![value hasPrefix:@"|"]) return value;
        NSMutableArray<NSString *> *blockLines = [NSMutableArray array];
        for (NSUInteger blockIndex = index + 1; blockIndex < MIN(lines.count, 120); blockIndex++) {
            NSString *blockLine = lines[blockIndex];
            NSString *blockTrimmed = [blockLine stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if ([blockTrimmed isEqualToString:@"---"]) break;
            BOOL indented = blockLine.length > 0
                && [NSCharacterSet.whitespaceCharacterSet characterIsMember:[blockLine characterAtIndex:0]];
            if (!indented && blockTrimmed.length > 0) break;
            if (blockTrimmed.length > 0) [blockLines addObject:blockTrimmed];
        }
        return [blockLines componentsJoinedByString:[value hasPrefix:@"|"] ? @"\n" : @" "];
    }
    return nil;
}

static NSData *CQDataAtPath(NSString *path) {
    if (path.length == 0) return nil;
    return [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
}

static BOOL CQPathIsPluginOrSystemSkill(NSString *path, NSString *scope) {
    NSString *normalized = path.stringByStandardizingPath;
    if ([scope isEqualToString:@"system"]) return YES;
    NSArray<NSString *> *excludedFragments = @[
        @"/.codex/skills/.system/",
        @"/.codex/plugins/",
        @"/.codex/.tmp/plugins/",
        @"/.codex/.tmp/bundled-marketplaces/",
        @"/.cache/codex-runtimes/"
    ];
    for (NSString *fragment in excludedFragments) {
        if ([normalized containsString:fragment]) return YES;
    }
    return NO;
}

static NSString *CQSkillInstallDirectory(NSString *skillPath) {
    NSString *normalized = skillPath.stringByStandardizingPath;
    if ([normalized.lastPathComponent caseInsensitiveCompare:@"SKILL.md"] != NSOrderedSame) return nil;
    if (CQPathIsPluginOrSystemSkill(normalized, @"user")) return nil;
    NSString *directory = normalized.stringByDeletingLastPathComponent;
    if (directory.lastPathComponent.length == 0 || [directory.lastPathComponent hasPrefix:@"."]) return nil;
    NSString *parent = directory.stringByDeletingLastPathComponent;
    for (NSString *root in @[
        [NSHomeDirectory() stringByAppendingPathComponent:@".agents/skills"],
        [NSHomeDirectory() stringByAppendingPathComponent:@".codex/skills"]
    ]) {
        if ([parent isEqualToString:root.stringByStandardizingPath]) return directory;
    }
    return nil;
}

static NSError *CQExtensionError(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:CQExtensionErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description ?: @"扩展操作失败"}];
}

static BOOL CQFileItemExists(NSFileManager *fileManager, NSString *path) {
    if ([fileManager fileExistsAtPath:path]) return YES;
    return [fileManager destinationOfSymbolicLinkAtPath:path error:nil] != nil;
}

static BOOL CQMarketplaceIsSystem(NSString *name, NSString *path) {
    NSString *normalizedPath = path.stringByStandardizingPath;
    return [name isEqualToString:@"openai-bundled"]
        || [name isEqualToString:@"openai-primary-runtime"]
        || [normalizedPath containsString:@"/openai-bundled/"]
        || [normalizedPath containsString:@"/openai-primary-runtime/"];
}

static NSString *CQSkillFolderFromPath(NSString *skillPath) {
    NSString *folder = [skillPath stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    if ([folder.lowercaseString hasSuffix:@"/skill.md"]) {
        folder = [folder substringToIndex:folder.length - [@"/SKILL.md" length]];
    } else if ([folder.lowercaseString isEqualToString:@"skill.md"]) {
        folder = @"";
    }
    return folder;
}

static BOOL CQParseSemanticVersion(NSString *version,
                                   NSArray<NSNumber *> **numbers,
                                   NSString **prerelease) {
    if (version.length == 0) return NO;
    NSString *normalized = ([version hasPrefix:@"v"] || [version hasPrefix:@"V"])
        ? [version substringFromIndex:1] : version;
    normalized = [normalized componentsSeparatedByString:@"+"].firstObject;
    NSArray<NSString *> *releaseParts = [normalized componentsSeparatedByString:@"-"];
    NSString *core = releaseParts.firstObject;
    NSArray<NSString *> *components = [core componentsSeparatedByString:@"."];
    if (components.count == 0 || components.count > 4) return NO;
    NSMutableArray<NSNumber *> *parsed = [NSMutableArray array];
    NSCharacterSet *nonDigits = NSCharacterSet.decimalDigitCharacterSet.invertedSet;
    for (NSString *component in components) {
        if (component.length == 0 || [component rangeOfCharacterFromSet:nonDigits].location != NSNotFound) return NO;
        [parsed addObject:@(component.integerValue)];
    }
    if (numbers) *numbers = parsed;
    if (prerelease) {
        *prerelease = releaseParts.count > 1
            ? [[releaseParts subarrayWithRange:NSMakeRange(1, releaseParts.count - 1)] componentsJoinedByString:@"-"] : nil;
    }
    return YES;
}

static NSComparisonResult CQCompareVersions(NSString *left, NSString *right) {
    NSArray<NSNumber *> *leftNumbers = nil;
    NSArray<NSNumber *> *rightNumbers = nil;
    NSString *leftPrerelease = nil;
    NSString *rightPrerelease = nil;
    BOOL leftSemantic = CQParseSemanticVersion(left, &leftNumbers, &leftPrerelease);
    BOOL rightSemantic = CQParseSemanticVersion(right, &rightNumbers, &rightPrerelease);
    if (!leftSemantic || !rightSemantic) {
        return [left compare:right options:NSNumericSearch | NSCaseInsensitiveSearch];
    }
    NSUInteger count = MAX(leftNumbers.count, rightNumbers.count);
    for (NSUInteger index = 0; index < count; index++) {
        NSInteger leftValue = index < leftNumbers.count ? leftNumbers[index].integerValue : 0;
        NSInteger rightValue = index < rightNumbers.count ? rightNumbers[index].integerValue : 0;
        if (leftValue < rightValue) return NSOrderedAscending;
        if (leftValue > rightValue) return NSOrderedDescending;
    }
    if (leftPrerelease.length == 0 && rightPrerelease.length > 0) return NSOrderedDescending;
    if (leftPrerelease.length > 0 && rightPrerelease.length == 0) return NSOrderedAscending;
    return [leftPrerelease ?: @"" compare:rightPrerelease ?: @""
                                     options:NSNumericSearch | NSCaseInsensitiveSearch];
}

static BOOL CQVersionsAreSemantic(NSString *left, NSString *right) {
    return CQParseSemanticVersion(left, nil, nil) && CQParseSemanticVersion(right, nil, nil);
}

static NSString *CQURLPathSegment(NSString *value) {
    NSMutableCharacterSet *allowed = [NSCharacterSet.URLPathAllowedCharacterSet mutableCopy];
    [allowed removeCharactersInString:@"/?#"];
    return [value stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: value;
}

static BOOL CQSourceUsesHost(NSString *source, NSString *expectedHost) {
    if (source.length == 0) return NO;
    NSString *urlString = ([source hasPrefix:@"https://"] || [source hasPrefix:@"http://"])
        ? source : [@"https://" stringByAppendingString:source];
    NSString *host = [NSURLComponents componentsWithString:urlString].host.lowercaseString;
    return [host isEqualToString:expectedHost.lowercaseString];
}

@implementation CQExtensionItem

- (BOOL)updateAvailable {
    return self.updateState == CQExtensionUpdateStateUpdateAvailable;
}

@end

@interface CQExtensionManager ()
@property(nonatomic, copy, readwrite) NSArray<CQExtensionItem *> *items;
@property(nonatomic, readwrite, getter=isChecking) BOOL checking;
@property(nonatomic, readwrite, getter=isUpdating) BOOL updating;
@property(nonatomic, readwrite, getter=isUninstalling) BOOL uninstalling;
@property(nonatomic, strong, readwrite, nullable) NSDate *updatedAt;
@property(nonatomic, copy, readwrite, nullable) NSString *lastError;
@property(nonatomic, strong, nullable) NSURL *codexURL;
@property(nonatomic, strong, nullable) CQCodexClient *client;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong, nullable) NSTimer *checkTimer;
@property(nonatomic, strong) NSMutableSet<NSTask *> *updateTasks;
@property(nonatomic) dispatch_queue_t uninstallQueue;
@property(nonatomic) BOOL periodicChecksEnabled;
@property(nonatomic) BOOL pendingUpdateCheck;
- (void)checkWhenIdle;
- (void)fetchWellKnownSkillDataForItem:(CQExtensionItem *)item
                            candidates:(NSArray<NSURL *> *)candidates
                                 index:(NSUInteger)index
                            completion:(void (^)(NSData * _Nullable data, NSError * _Nullable error))completion;
- (void)fetchGitHubDefaultBranchOwner:(NSString *)owner
                            repository:(NSString *)repository
                            completion:(void (^)(NSString * _Nullable branch))completion;
- (NSArray<CQExtensionItem *> *)groupFeishuSkillsInItems:(NSArray<CQExtensionItem *> *)items
                                                checking:(BOOL)checking;
- (void)checkLarkCLIItem:(CQExtensionItem *)item
              completion:(void (^)(void))completion;
- (void)updateLarkCLIItem:(CQExtensionItem *)item;
- (NSString * _Nullable)larkCLIPath;
- (void)finishUpdatingAndRefresh:(BOOL)refresh;
- (NSError * _Nullable)removeSkillDirectories:(NSArray<NSString *> *)paths
                                   skillNames:(NSArray<NSString *> *)skillNames;
@end

@implementation CQExtensionManager

- (instancetype)initWithCodexURL:(NSURL *)codexURL {
    self = [super init];
    if (!self) return nil;
    _codexURL = codexURL;
    _items = @[];
    _updateTasks = [NSMutableSet set];
    _uninstallQueue = dispatch_queue_create("com.muyang.codexquota.extensions.uninstall", DISPATCH_QUEUE_SERIAL);
    _updatedAt = [NSUserDefaults.standardUserDefaults objectForKey:CQExtensionsLastCheckKey];
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = 20;
    configuration.timeoutIntervalForResource = 45;
    configuration.HTTPMaximumConnectionsPerHost = 4;
    _session = [NSURLSession sessionWithConfiguration:configuration];
    return self;
}

- (void)setCodexURL:(NSURL *)codexURL {
    _codexURL = codexURL;
}

- (void)notifyChanged {
    if (self.changeHandler) self.changeHandler();
}

- (void)loadInstalledExtensions {
    if (self.uninstalling) return;
    [self refreshCheckingUpdates:NO];
}

- (void)checkForUpdates {
    if (self.checking || self.updating || self.uninstalling) {
        self.pendingUpdateCheck = YES;
        return;
    }
    [self refreshCheckingUpdates:YES];
}

- (void)startPeriodicChecks {
    self.periodicChecksEnabled = YES;
    [self.checkTimer invalidate];
    self.checkTimer = [NSTimer scheduledTimerWithTimeInterval:CQExtensionCheckInterval
                                                      target:self
                                                    selector:@selector(periodicCheck:)
                                                    userInfo:nil
                                                     repeats:YES];
    BOOL overdue = !self.updatedAt || -self.updatedAt.timeIntervalSinceNow >= CQExtensionCheckInterval;
    if (overdue) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [self checkWhenIdle];
        });
    }
}

- (void)checkWhenIdle {
    if (!self.periodicChecksEnabled) return;
    if (self.checking || self.updating || self.uninstalling) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [self checkWhenIdle];
        });
        return;
    }
    [self checkForUpdates];
}

- (void)periodicCheck:(NSTimer *)timer {
    (void)timer;
    if (!self.checking && !self.updating && !self.uninstalling) [self checkForUpdates];
}

- (void)stop {
    self.periodicChecksEnabled = NO;
    [self.checkTimer invalidate];
    self.checkTimer = nil;
    [self.client stop];
    self.client = nil;
    [self.session invalidateAndCancel];
}

- (void)ensureClient:(void (^)(CQCodexClient * _Nullable client, NSError * _Nullable error))completion {
    if (self.client.running) {
        completion(self.client, nil);
        return;
    }
    if (!self.codexURL) {
        NSError *error = [NSError errorWithDomain:@"com.muyang.codexquota.extensions"
                                             code:-1
                                         userInfo:@{NSLocalizedDescriptionKey: @"未找到 Codex，暂时无法读取插件"}];
        completion(nil, error);
        return;
    }
    CQCodexClient *client = [CQCodexClient new];
    self.client = client;
    __weak typeof(self) weakSelf = self;
    __weak CQCodexClient *weakClient = client;
    client.processDidExit = ^(NSError *error) {
        typeof(self) self = weakSelf;
        if (!self || self.client != weakClient) return;
        self.client = nil;
        if (self.checking) {
            self.checking = NO;
            self.lastError = error.localizedDescription;
            [self notifyChanged];
        }
    };
    [client startAtURL:self.codexURL completion:^(NSError *error) {
        typeof(self) self = weakSelf;
        if (!self || self.client != weakClient) return;
        completion(error ? nil : client, error);
    }];
}

- (void)refreshCheckingUpdates:(BOOL)checkingUpdates {
    if (self.checking) return;
    self.checking = YES;
    self.lastError = nil;
    for (CQExtensionItem *item in self.items) {
        if (item.updateState != CQExtensionUpdateStateUpdating
            && item.updateState != CQExtensionUpdateStateUntracked) {
            item.updateState = CQExtensionUpdateStateChecking;
        }
    }
    [self notifyChanged];

    __weak typeof(self) weakSelf = self;
    [self ensureClient:^(CQCodexClient *client, NSError *clientError) {
        typeof(self) self = weakSelf;
        if (!self) return;
        if (!client) {
            self.items = [self fallbackSkillItems];
            self.checking = NO;
            self.pendingUpdateCheck = NO;
            self.lastError = clientError.localizedDescription;
            [self notifyChanged];
            return;
        }

        dispatch_group_t group = dispatch_group_create();
        __block NSDictionary *skillsResult = nil;
        __block NSDictionary *pluginsResult = nil;
        __block NSError *skillsError = nil;
        __block NSError *pluginsError = nil;
        NSString *workingDirectory = NSHomeDirectory();

        dispatch_group_enter(group);
        [client listSkillsAtWorkingDirectory:workingDirectory forceReload:YES completion:^(NSDictionary *result, NSError *error) {
            skillsResult = result;
            skillsError = error;
            dispatch_group_leave(group);
        }];

        dispatch_group_enter(group);
        [client listPluginsAtWorkingDirectory:workingDirectory forceRefetch:checkingUpdates completion:^(NSDictionary *result, NSError *error) {
            pluginsResult = result;
            pluginsError = error;
            dispatch_group_leave(group);
        }];

        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self) return;
            NSMutableArray<CQExtensionItem *> *combined = [NSMutableArray array];
            if (skillsResult) [combined addObjectsFromArray:[self skillItemsFromResult:skillsResult checking:checkingUpdates]];
            else {
                NSArray<CQExtensionItem *> *existingSkills = [self.items filteredArrayUsingPredicate:
                    [NSPredicate predicateWithBlock:^BOOL(CQExtensionItem *item, NSDictionary *bindings) {
                        (void)bindings;
                        return item.kind == CQExtensionKindSkill;
                    }]];
                [combined addObjectsFromArray:existingSkills.count > 0 ? existingSkills : [self fallbackSkillItems]];
            }
            if (pluginsResult) [combined addObjectsFromArray:[self pluginItemsFromResult:pluginsResult]];
            else {
                for (CQExtensionItem *item in self.items) {
                    if (item.kind != CQExtensionKindPlugin) continue;
                    item.updateState = CQExtensionUpdateStateFailed;
                    item.errorMessage = pluginsError.localizedDescription ?: @"暂时无法读取插件版本";
                    [combined addObject:item];
                }
            }
            self.items = [self sortedItems:combined];

            NSMutableArray<NSString *> *errors = [NSMutableArray array];
            if (skillsError.localizedDescription.length > 0) [errors addObject:skillsError.localizedDescription];
            if (pluginsError.localizedDescription.length > 0) [errors addObject:pluginsError.localizedDescription];
            self.lastError = errors.count > 0 ? [errors componentsJoinedByString:@"；"] : nil;
            [self.client stop];
            self.client = nil;

            if (checkingUpdates) {
                [self checkSkillSourcesAndFinish];
            } else {
                self.checking = NO;
                [self notifyChanged];
                if (self.pendingUpdateCheck) {
                    self.pendingUpdateCheck = NO;
                    [self checkForUpdates];
                }
            }
        });
    }];
}

- (NSDictionary *)skillLock {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@".agents/.skill-lock.json"];
    NSData *data = CQDataAtPath(path);
    if (!data) return @{};
    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return CQExtensionDictionary(root[@"skills"]) ?: @{};
}

- (NSArray<CQExtensionItem *> *)skillItemsFromResult:(NSDictionary *)result checking:(BOOL)checking {
    NSDictionary *lock = [self skillLock];
    NSMutableDictionary<NSString *, CQExtensionItem *> *itemsByName = [NSMutableDictionary dictionary];
    for (NSDictionary *entry in CQExtensionArray(result[@"data"])) {
        for (NSDictionary *skill in CQExtensionArray(entry[@"skills"])) {
            NSString *name = CQExtensionString(skill[@"name"]);
            NSString *path = CQExtensionString(skill[@"path"]);
            NSString *scope = CQExtensionString(skill[@"scope"]) ?: @"user";
            if (name.length == 0 || path.length == 0 || CQPathIsPluginOrSystemSkill(path, scope)) continue;

            CQExtensionItem *item = itemsByName[name];
            if (item) {
                if (![item.paths containsObject:path]) item.paths = [item.paths arrayByAddingObject:path];
                continue;
            }
            item = [CQExtensionItem new];
            item.identifier = [@"skill:" stringByAppendingString:name];
            item.kind = CQExtensionKindSkill;
            item.name = name;
            item.skillNames = @[name];
            NSDictionary *interface = CQExtensionDictionary(skill[@"interface"]);
            item.displayName = CQExtensionString(interface[@"displayName"]) ?: name;
            item.paths = @[path];
            item.scopeDetail = [scope isEqualToString:@"repo"] ? @"项目级" : @"用户级";
            NSData *skillData = CQDataAtPath(path);
            item.installedVersion = CQSkillFrontmatterValue(skillData, @"version");
            item.summaryText = CQExtensionString(skill[@"description"])
                ?: CQExtensionString(interface[@"shortDescription"])
                ?: CQSkillFrontmatterValue(skillData, @"description")
                ?: @"未提供用途说明";

            NSDictionary *locked = CQExtensionDictionary(lock[name]);
            if (locked) {
                item.skillSourceType = CQExtensionString(locked[@"sourceType"]);
                item.skillSource = CQExtensionString(locked[@"source"]);
                item.skillSourceURL = CQExtensionString(locked[@"sourceUrl"]);
                item.skillPath = CQExtensionString(locked[@"skillPath"]);
                item.skillFolderHash = CQExtensionString(locked[@"skillFolderHash"]);
                if (item.installedVersion.length == 0 && item.skillFolderHash.length > 0) {
                    item.installedVersion = [item.skillFolderHash substringToIndex:MIN((NSUInteger)8, item.skillFolderHash.length)];
                }
                item.sourceName = item.skillSource.length > 0 ? item.skillSource : @"已追踪来源";
                BOOL github = [item.skillSourceType isEqualToString:@"github"]
                    && item.skillPath.length > 0 && item.skillFolderHash.length > 0;
                BOOL wellKnown = [item.skillSourceType isEqualToString:@"well-known"]
                    && (item.skillSourceURL.length > 0 || item.skillSource.length > 0);
                item.updateState = (github || wellKnown)
                    ? (checking ? CQExtensionUpdateStateChecking : CQExtensionUpdateStateUnknown)
                    : CQExtensionUpdateStateUntracked;
            } else {
                item.sourceName = @"本地维护";
                item.updateState = CQExtensionUpdateStateUntracked;
            }
            itemsByName[name] = item;
        }
    }
    for (CQExtensionItem *item in itemsByName.allValues) {
        if (item.paths.count > 1) {
            item.scopeDetail = [NSString stringWithFormat:@"%@ · %lu 个安装位置",
                item.scopeDetail, (unsigned long)item.paths.count];
        }
    }
    return [self groupFeishuSkillsInItems:itemsByName.allValues checking:checking];
}

- (NSArray<CQExtensionItem *> *)groupFeishuSkillsInItems:(NSArray<CQExtensionItem *> *)items
                                                checking:(BOOL)checking {
    NSMutableArray<CQExtensionItem *> *regularItems = [NSMutableArray array];
    NSMutableArray<CQExtensionItem *> *feishuItems = [NSMutableArray array];
    for (CQExtensionItem *item in items) {
        BOOL officialSource = [item.skillSourceType isEqualToString:@"well-known"]
            && (CQSourceUsesHost(item.skillSource, @"open.feishu.cn")
                || CQSourceUsesHost(item.skillSourceURL, @"open.feishu.cn"));
        if (officialSource && [item.name hasPrefix:@"lark-"]) [feishuItems addObject:item];
        else [regularItems addObject:item];
    }
    if (feishuItems.count == 0) return regularItems;

    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (CQExtensionItem *item in feishuItems) {
        for (NSString *path in item.paths) if (![paths containsObject:path]) [paths addObject:path];
    }
    CQExtensionItem *bundle = [CQExtensionItem new];
    bundle.identifier = @"skill-bundle:lark-cli";
    bundle.kind = CQExtensionKindSkill;
    bundle.name = @"lark-cli";
    bundle.displayName = @"飞书 CLI Skills";
    bundle.sourceName = @"飞书官方 CLI";
    bundle.scopeDetail = [NSString stringWithFormat:@"用户级 · %lu 个 Skill",
        (unsigned long)feishuItems.count];
    bundle.summaryText = @"让 AI 直接操作飞书，统一覆盖消息、文档、云盘、表格、多维表格、日历、会议、邮件、任务和知识库。";
    bundle.paths = paths;
    bundle.skillSourceType = @"lark-cli";
    bundle.skillSource = @"https://www.feishu.cn/feishu-cli";
    bundle.skillNames = [feishuItems valueForKey:@"name"];
    bundle.larkCLIManaged = YES;
    bundle.groupedSkillCount = feishuItems.count;
    bundle.updateState = checking ? CQExtensionUpdateStateChecking : CQExtensionUpdateStateUnknown;
    [regularItems addObject:bundle];
    return regularItems;
}

- (NSArray<CQExtensionItem *> *)fallbackSkillItems {
    NSMutableArray *skills = [NSMutableArray array];
    for (NSString *root in @[
        [NSHomeDirectory() stringByAppendingPathComponent:@".agents/skills"],
        [NSHomeDirectory() stringByAppendingPathComponent:@".codex/skills"]
    ]) {
        NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil];
        for (NSString *name in names) {
            if ([name hasPrefix:@"."]) continue;
            NSString *path = [[root stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"SKILL.md"];
            if (![NSFileManager.defaultManager fileExistsAtPath:path]) continue;
            [skills addObject:@{
                @"name": name,
                @"path": path,
                @"scope": @"user",
                @"interface": @{}
            }];
        }
    }
    return [self skillItemsFromResult:@{@"data": @[@{@"skills": skills}]} checking:NO];
}

- (NSArray<CQExtensionItem *> *)pluginItemsFromResult:(NSDictionary *)result {
    NSMutableArray<CQExtensionItem *> *items = [NSMutableArray array];
    for (NSDictionary *marketplace in CQExtensionArray(result[@"marketplaces"])) {
        NSString *marketplaceName = CQExtensionString(marketplace[@"name"]) ?: @"marketplace";
        NSString *marketplacePath = CQExtensionString(marketplace[@"path"]);
        if (CQMarketplaceIsSystem(marketplaceName, marketplacePath)) continue;
        NSDictionary *marketplaceInterface = CQExtensionDictionary(marketplace[@"interface"]);
        NSString *marketplaceDisplay = CQExtensionString(marketplaceInterface[@"displayName"]) ?: marketplaceName;
        for (NSDictionary *plugin in CQExtensionArray(marketplace[@"plugins"])) {
            if (![plugin[@"installed"] boolValue]) continue;
            NSString *name = CQExtensionString(plugin[@"name"]);
            if (name.length == 0) continue;
            CQExtensionItem *item = [CQExtensionItem new];
            item.identifier = CQExtensionString(plugin[@"id"])
                ?: [NSString stringWithFormat:@"plugin:%@@%@", name, marketplaceName];
            item.kind = CQExtensionKindPlugin;
            item.name = name;
            NSDictionary *interface = CQExtensionDictionary(plugin[@"interface"]);
            item.displayName = CQExtensionString(interface[@"displayName"]) ?: name;
            item.sourceName = marketplaceDisplay;
            item.scopeDetail = @"已安装插件";
            item.marketplacePath = marketplacePath;
            item.remoteMarketplaceName = marketplacePath.length == 0 ? marketplaceName : nil;
            item.installedVersion = CQExtensionString(plugin[@"localVersion"]);
            item.availableVersion = CQExtensionString(plugin[@"version"]);
            if (!item.installedVersion) item.installedVersion = item.availableVersion;
            item.paths = @[];

            NSString *localVersion = CQExtensionString(plugin[@"localVersion"]);
            NSString *remoteVersion = CQExtensionString(plugin[@"version"]);
            NSDictionary *source = CQExtensionDictionary(plugin[@"source"]);
            BOOL localSource = [CQExtensionString(source[@"type"]) isEqualToString:@"local"];
            if (localSource) {
                item.updateState = CQExtensionUpdateStateUntracked;
            } else if (localVersion.length > 0 && remoteVersion.length > 0) {
                if ([localVersion isEqualToString:remoteVersion]) {
                    item.updateState = CQExtensionUpdateStateUpToDate;
                } else if (CQVersionsAreSemantic(remoteVersion, localVersion)) {
                    item.updateState = CQCompareVersions(remoteVersion, localVersion) == NSOrderedDescending
                        ? CQExtensionUpdateStateUpdateAvailable : CQExtensionUpdateStateUpToDate;
                } else {
                    item.updateState = CQExtensionUpdateStateUpdateAvailable;
                }
            } else {
                item.updateState = CQExtensionUpdateStateUnknown;
            }
            [items addObject:item];
        }
    }
    return items;
}

- (NSArray<CQExtensionItem *> *)sortedItems:(NSArray<CQExtensionItem *> *)items {
    return [items sortedArrayUsingComparator:^NSComparisonResult(CQExtensionItem *left, CQExtensionItem *right) {
        if (left.kind != right.kind) return left.kind < right.kind ? NSOrderedAscending : NSOrderedDescending;
        if (left.updateAvailable != right.updateAvailable) return left.updateAvailable ? NSOrderedAscending : NSOrderedDescending;
        return [left.displayName localizedCaseInsensitiveCompare:right.displayName];
    }];
}

- (void)checkSkillSourcesAndFinish {
    NSMutableDictionary<NSString *, NSMutableArray<CQExtensionItem *> *> *githubGroups = [NSMutableDictionary dictionary];
    NSMutableArray<CQExtensionItem *> *wellKnown = [NSMutableArray array];
    NSMutableArray<CQExtensionItem *> *larkCLIItems = [NSMutableArray array];
    for (CQExtensionItem *item in self.items) {
        if (item.kind != CQExtensionKindSkill) continue;
        if (item.larkCLIManaged) {
            [larkCLIItems addObject:item];
        } else if ([item.skillSourceType isEqualToString:@"github"]
            && item.skillSource.length > 0 && item.skillFolderHash.length > 0 && item.skillPath.length > 0) {
            NSMutableArray *group = githubGroups[item.skillSource];
            if (!group) githubGroups[item.skillSource] = group = [NSMutableArray array];
            [group addObject:item];
        } else if ([item.skillSourceType isEqualToString:@"well-known"]
                   && (item.skillSourceURL.length > 0 || item.skillSource.length > 0)) {
            [wellKnown addObject:item];
        } else if (item.updateState == CQExtensionUpdateStateChecking) {
            item.updateState = CQExtensionUpdateStateUntracked;
        }
    }

    dispatch_group_t group = dispatch_group_create();
    __weak typeof(self) weakSelf = self;
    for (CQExtensionItem *item in larkCLIItems) {
        dispatch_group_enter(group);
        [self checkLarkCLIItem:item completion:^{ dispatch_group_leave(group); }];
    }
    [githubGroups enumerateKeysAndObjectsUsingBlock:^(NSString *source, NSArray<CQExtensionItem *> *sourceItems, BOOL *stop) {
        (void)stop;
        dispatch_group_enter(group);
        [self fetchGitHubTreeForSource:source completion:^(NSDictionary *tree, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                for (CQExtensionItem *item in sourceItems) {
                    if (error || !tree) {
                        item.updateState = CQExtensionUpdateStateFailed;
                        item.errorMessage = error.localizedDescription ?: @"无法读取 GitHub 版本";
                        continue;
                    }
                    NSString *folder = CQSkillFolderFromPath(item.skillPath);
                    NSString *remoteHash = folder.length == 0 ? CQExtensionString(tree[@"sha"]) : nil;
                    if (folder.length > 0) {
                        for (NSDictionary *entry in CQExtensionArray(tree[@"tree"])) {
                            if ([CQExtensionString(entry[@"type"]) isEqualToString:@"tree"]
                                && [CQExtensionString(entry[@"path"]) isEqualToString:folder]) {
                                remoteHash = CQExtensionString(entry[@"sha"]);
                                break;
                            }
                        }
                    }
                    if (remoteHash.length == 0) {
                        item.updateState = CQExtensionUpdateStateFailed;
                        item.errorMessage = @"上游已找不到这个 Skill";
                    } else {
                        item.availableVersion = [remoteHash substringToIndex:MIN((NSUInteger)8, remoteHash.length)];
                        item.updateState = [remoteHash isEqualToString:item.skillFolderHash]
                            ? CQExtensionUpdateStateUpToDate : CQExtensionUpdateStateUpdateAvailable;
                    }
                }
                dispatch_group_leave(group);
            });
        }];
    }];

    for (CQExtensionItem *item in wellKnown) {
        dispatch_group_enter(group);
        NSMutableArray<NSURL *> *candidates = [NSMutableArray array];
        if (item.skillSourceURL.length > 0) {
            NSURL *explicitURL = [NSURL URLWithString:item.skillSourceURL];
            if (explicitURL) [candidates addObject:explicitURL];
        } else {
            NSString *base = item.skillSource;
            if (![base hasPrefix:@"https://"] && ![base hasPrefix:@"http://"]) {
                base = [@"https://" stringByAppendingString:base];
            }
            while ([base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];
            for (NSString *wellKnownPath in @[@"agent-skills", @"skills"]) {
                NSString *urlString = [NSString stringWithFormat:@"%@/.well-known/%@/%@/SKILL.md",
                    base, wellKnownPath, item.name];
                NSURL *url = [NSURL URLWithString:urlString];
                if (url) [candidates addObject:url];
            }
        }
        if (candidates.count == 0) {
            item.updateState = CQExtensionUpdateStateFailed;
            item.errorMessage = @"更新地址无效";
            dispatch_group_leave(group);
            continue;
        }
        [self fetchWellKnownSkillDataForItem:item candidates:candidates index:0 completion:^(NSData *data, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (error || data.length == 0) {
                    item.updateState = CQExtensionUpdateStateFailed;
                    item.errorMessage = error.localizedDescription ?: @"无法读取上游 Skill";
                } else {
                    NSString *remoteVersion = CQSkillFrontmatterValue(data, @"version");
                    NSData *localData = CQDataAtPath(item.paths.firstObject);
                    if (remoteVersion.length > 0 && item.installedVersion.length > 0) {
                        item.availableVersion = remoteVersion;
                        item.updateState = CQCompareVersions(remoteVersion, item.installedVersion) == NSOrderedDescending
                            ? CQExtensionUpdateStateUpdateAvailable : CQExtensionUpdateStateUpToDate;
                    } else {
                        item.updateState = [data isEqualToData:localData]
                            ? CQExtensionUpdateStateUpToDate : CQExtensionUpdateStateUpdateAvailable;
                    }
                }
                dispatch_group_leave(group);
            });
        }];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (!self) return;
        self.items = [self sortedItems:self.items];
        self.checking = NO;
        self.updatedAt = NSDate.date;
        [NSUserDefaults.standardUserDefaults setObject:self.updatedAt forKey:CQExtensionsLastCheckKey];
        [self notifyChanged];
        self.pendingUpdateCheck = NO;
    });
}

- (NSString *)larkCLIPath {
    NSMutableArray<NSString *> *candidates = [NSMutableArray arrayWithArray:@[
        @"/opt/homebrew/bin/lark-cli",
        @"/usr/local/bin/lark-cli",
        [NSHomeDirectory() stringByAppendingPathComponent:@".local/bin/lark-cli"]
    ]];
    NSString *environmentPath = NSProcessInfo.processInfo.environment[@"PATH"];
    for (NSString *directory in [environmentPath componentsSeparatedByString:@":"]) {
        if (directory.length > 0) [candidates addObject:[directory stringByAppendingPathComponent:@"lark-cli"]];
    }
    for (NSString *path in candidates) {
        if ([NSFileManager.defaultManager isExecutableFileAtPath:path]) return path;
    }
    return nil;
}

- (void)checkLarkCLIItem:(CQExtensionItem *)item
              completion:(void (^)(void))completion {
    NSString *larkCLI = [self larkCLIPath];
    if (!larkCLI) {
        item.updateState = CQExtensionUpdateStateFailed;
        item.errorMessage = @"未找到 lark-cli；请参考 www.feishu.cn/feishu-cli 完成安装";
        completion();
        return;
    }

    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:larkCLI];
    task.arguments = @[@"update", @"--check", @"--json"];
    task.currentDirectoryURL = [NSURL fileURLWithPath:NSHomeDirectory() isDirectory:YES];
    NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    NSString *path = environment[@"PATH"] ?: @"/usr/bin:/bin";
    environment[@"PATH"] = [NSString stringWithFormat:@"/opt/homebrew/bin:/usr/local/bin:%@", path];
    environment[@"NO_COLOR"] = @"1";
    environment[@"CI"] = @"1";
    task.environment = environment;
    NSPipe *outputPipe = [NSPipe pipe];
    NSPipe *errorPipe = [NSPipe pipe];
    task.standardOutput = outputPipe;
    task.standardError = errorPipe;
    [self.updateTasks addObject:task];

    __weak typeof(self) weakSelf = self;
    __weak NSTask *weakTask = task;
    task.terminationHandler = ^(NSTask *finished) {
        NSData *outputData = [outputPipe.fileHandleForReading readDataToEndOfFile];
        NSData *errorData = [errorPipe.fileHandleForReading readDataToEndOfFile];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self) return;
            [self.updateTasks removeObject:weakTask];
            NSDictionary *result = outputData.length > 0
                ? CQExtensionDictionary([NSJSONSerialization JSONObjectWithData:outputData options:0 error:nil]) : nil;
            BOOL ok = [result[@"ok"] boolValue] && finished.terminationStatus == 0;
            if (!ok) {
                NSDictionary *error = CQExtensionDictionary(result[@"error"]);
                NSString *stderrText = [[[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding]
                    stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                item.updateState = CQExtensionUpdateStateFailed;
                item.errorMessage = CQExtensionString(error[@"message"]);
                if (item.errorMessage.length == 0) item.errorMessage = stderrText.length > 0
                    ? stderrText : @"飞书 CLI 更新检查失败";
            } else {
                item.installedVersion = CQExtensionString(result[@"current_version"]);
                item.availableVersion = CQExtensionString(result[@"latest_version"]);
                NSDictionary *skillsStatus = CQExtensionDictionary(result[@"skills_status"]);
                NSUInteger officialCount = [skillsStatus[@"official"] unsignedIntegerValue];
                if (officialCount > 0) {
                    item.groupedSkillCount = officialCount;
                    item.scopeDetail = [NSString stringWithFormat:@"用户级 · %lu 个 Skill",
                        (unsigned long)officialCount];
                }
                item.updateState = [CQExtensionString(result[@"action"]) isEqualToString:@"update_available"]
                    ? CQExtensionUpdateStateUpdateAvailable : CQExtensionUpdateStateUpToDate;
                item.errorMessage = nil;
            }
            completion();
        });
    };
    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        [self.updateTasks removeObject:task];
        item.updateState = CQExtensionUpdateStateFailed;
        item.errorMessage = launchError.localizedDescription ?: @"无法启动飞书 CLI 更新检查";
        completion();
    }
}

- (void)fetchWellKnownSkillDataForItem:(CQExtensionItem *)item
                            candidates:(NSArray<NSURL *> *)candidates
                                 index:(NSUInteger)index
                            completion:(void (^)(NSData * _Nullable data, NSError * _Nullable error))completion {
    if (index >= candidates.count) {
        NSError *error = [NSError errorWithDomain:@"com.muyang.codexquota.extensions"
                                             code:-4
                                         userInfo:@{NSLocalizedDescriptionKey: @"无法读取 Well-known Skill 上游"}];
        completion(nil, error);
        return;
    }
    NSURL *url = candidates[index];
    __weak typeof(self) weakSelf = self;
    [[self.session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (id)response : nil;
        NSString *remoteSkillName = CQSkillFrontmatterValue(data, @"name");
        if (!error && data.length > 0 && http.statusCode < 400 && remoteSkillName.length > 0) {
            item.skillSourceURL = url.absoluteString;
            completion(data, nil);
            return;
        }
        [weakSelf fetchWellKnownSkillDataForItem:item
                                      candidates:candidates
                                           index:index + 1
                                      completion:completion];
    }] resume];
}

- (void)fetchGitHubTreeForSource:(NSString *)source
                      completion:(void (^)(NSDictionary * _Nullable tree, NSError * _Nullable error))completion {
    NSArray<NSString *> *parts = [source componentsSeparatedByString:@"/"];
    if (parts.count < 2) {
        NSError *error = [NSError errorWithDomain:@"com.muyang.codexquota.extensions"
                                             code:-2
                                         userInfo:@{NSLocalizedDescriptionKey: @"GitHub 来源格式无效"}];
        completion(nil, error);
        return;
    }
    NSString *owner = parts[0];
    NSString *repository = [parts[1] stringByDeletingPathExtension];
    [self fetchGitHubDefaultBranchOwner:owner repository:repository completion:^(NSString *defaultBranch) {
        NSMutableArray<NSString *> *branches = [NSMutableArray array];
        for (NSString *branch in @[defaultBranch ?: @"", @"HEAD", @"main", @"master"]) {
            if (branch.length > 0 && ![branches containsObject:branch]) [branches addObject:branch];
        }
        [self fetchGitHubTreeOwner:owner
                        repository:repository
                          branches:branches
                             index:0
                        completion:completion];
    }];
}

- (void)fetchGitHubDefaultBranchOwner:(NSString *)owner
                            repository:(NSString *)repository
                            completion:(void (^)(NSString * _Nullable branch))completion {
    NSString *urlString = [NSString stringWithFormat:@"https://api.github.com/repos/%@/%@",
        CQURLPathSegment(owner), CQURLPathSegment(repository)];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Codex-Quota" forHTTPHeaderField:@"User-Agent"];
    [[self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (id)response : nil;
        NSDictionary *repositoryInfo = data.length > 0
            ? CQExtensionDictionary([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]) : nil;
        NSString *branch = !error && http.statusCode < 400
            ? CQExtensionString(repositoryInfo[@"default_branch"]) : nil;
        completion(branch);
    }] resume];
}

- (void)fetchGitHubTreeOwner:(NSString *)owner
                  repository:(NSString *)repository
                    branches:(NSArray<NSString *> *)branches
                       index:(NSUInteger)index
                  completion:(void (^)(NSDictionary * _Nullable tree, NSError * _Nullable error))completion {
    if (index >= branches.count) {
        NSError *error = [NSError errorWithDomain:@"com.muyang.codexquota.extensions"
                                             code:-3
                                         userInfo:@{NSLocalizedDescriptionKey: @"无法读取 GitHub 上游版本"}];
        completion(nil, error);
        return;
    }
    NSString *branch = branches[index];
    NSString *urlString = [NSString stringWithFormat:@"https://api.github.com/repos/%@/%@/git/trees/%@?recursive=1",
        CQURLPathSegment(owner), CQURLPathSegment(repository), CQURLPathSegment(branch)];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Codex-Quota" forHTTPHeaderField:@"User-Agent"];
    __weak typeof(self) weakSelf = self;
    [[self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (id)response : nil;
        NSDictionary *tree = data.length > 0
            ? CQExtensionDictionary([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]) : nil;
        if (!error && http.statusCode < 400 && tree[@"tree"]) {
            completion(tree, nil);
            return;
        }
        [weakSelf fetchGitHubTreeOwner:owner
                            repository:repository
                              branches:branches
                                 index:index + 1
                            completion:completion];
    }] resume];
}

- (void)finishUpdatingAndRefresh:(BOOL)refresh {
    self.updating = NO;
    BOOL shouldRefresh = refresh || self.pendingUpdateCheck;
    self.pendingUpdateCheck = NO;
    if (shouldRefresh) [self checkForUpdates];
    else [self notifyChanged];
}

- (NSError *)removeSkillDirectories:(NSArray<NSString *> *)paths
                          skillNames:(NSArray<NSString *> *)skillNames {
    NSMutableOrderedSet<NSString *> *targets = [NSMutableOrderedSet orderedSet];
    for (NSString *path in paths) {
        NSString *target = CQSkillInstallDirectory(path);
        if (target.length == 0) {
            return CQExtensionError(20, [NSString stringWithFormat:@"拒绝卸载不受信任的 Skill 路径：%@", path]);
        }
        [targets addObject:target];
    }
    if (targets.count == 0) return CQExtensionError(21, @"未找到这个 Skill 的安装位置");

    NSFileManager *fileManager = [NSFileManager new];
    NSString *stagingPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"CodexQuota-Uninstall-%@", NSUUID.UUID.UUIDString]];
    NSError *fileError = nil;
    if (![fileManager createDirectoryAtPath:stagingPath
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:&fileError]) {
        return CQExtensionError(22, [NSString stringWithFormat:@"无法准备安全卸载目录：%@",
            fileError.localizedDescription ?: @"未知错误"]);
    }

    NSMutableArray<NSString *> *originals = [NSMutableArray array];
    NSMutableArray<NSString *> *staged = [NSMutableArray array];
    NSError * (^restoreMovedItems)(void) = ^NSError *{
        NSMutableArray<NSString *> *failures = [NSMutableArray array];
        for (NSInteger index = (NSInteger)staged.count - 1; index >= 0; index--) {
            NSString *source = staged[(NSUInteger)index];
            NSString *destination = originals[(NSUInteger)index];
            if (CQFileItemExists(fileManager, source) && !CQFileItemExists(fileManager, destination)) {
                NSError *restoreError = nil;
                if (![fileManager moveItemAtPath:source toPath:destination error:&restoreError]) {
                    [failures addObject:[NSString stringWithFormat:@"%@（%@）", destination,
                        restoreError.localizedDescription ?: @"恢复失败"]];
                }
            } else if (CQFileItemExists(fileManager, source)) {
                [failures addObject:[NSString stringWithFormat:@"%@（原位置已被占用）", destination]];
            }
        }
        if (failures.count == 0) return nil;
        return CQExtensionError(28, [NSString stringWithFormat:
            @"安全回滚未完成，暂存数据保留在 %@；请勿手动覆盖原目录。未恢复：%@",
            stagingPath, [failures componentsJoinedByString:@"；"]]);
    };

    NSUInteger index = 0;
    for (NSString *target in targets) {
        if (!CQFileItemExists(fileManager, target)) continue;
        NSString *destination = [stagingPath stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%lu-%@", (unsigned long)index++, target.lastPathComponent]];
        if (![fileManager moveItemAtPath:target toPath:destination error:&fileError]) {
            NSError *restoreError = restoreMovedItems();
            if (restoreError) return restoreError;
            [fileManager removeItemAtPath:stagingPath error:nil];
            return CQExtensionError(23, [NSString stringWithFormat:@"无法移除 %@：%@",
                target.lastPathComponent, fileError.localizedDescription ?: @"请检查目录权限"]);
        }
        [originals addObject:target];
        [staged addObject:destination];
    }

    NSString *lockPath = [NSHomeDirectory() stringByAppendingPathComponent:@".agents/.skill-lock.json"];
    NSData *lockData = CQDataAtPath(lockPath);
    if (lockData.length > 0) {
        NSError *jsonError = nil;
        NSDictionary *lockRoot = CQExtensionDictionary(
            [NSJSONSerialization JSONObjectWithData:lockData options:0 error:&jsonError]);
        NSDictionary *lockedSkills = CQExtensionDictionary(lockRoot[@"skills"]);
        if (!lockRoot || !lockedSkills) {
            NSError *restoreError = restoreMovedItems();
            if (restoreError) return restoreError;
            [fileManager removeItemAtPath:stagingPath error:nil];
            return CQExtensionError(24, [NSString stringWithFormat:@"无法读取 Skill 安装记录：%@",
                jsonError.localizedDescription ?: @"记录格式无效"]);
        }
        NSMutableDictionary *updatedRoot = [lockRoot mutableCopy];
        NSMutableDictionary *updatedSkills = [lockedSkills mutableCopy];
        BOOL changed = NO;
        for (NSString *name in skillNames) {
            if (updatedSkills[name]) {
                [updatedSkills removeObjectForKey:name];
                changed = YES;
            }
        }
        if (changed) {
            updatedRoot[@"skills"] = updatedSkills;
            NSData *updatedData = [NSJSONSerialization dataWithJSONObject:updatedRoot
                                                                  options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                                    error:&jsonError];
            if (!updatedData || ![updatedData writeToFile:lockPath options:NSDataWritingAtomic error:&fileError]) {
                NSError *restoreError = restoreMovedItems();
                if (restoreError) return restoreError;
                [fileManager removeItemAtPath:stagingPath error:nil];
                NSString *reason = jsonError.localizedDescription ?: fileError.localizedDescription ?: @"请检查文件权限";
                return CQExtensionError(25, [NSString stringWithFormat:@"无法清理 Skill 安装记录：%@", reason]);
            }
        }
    }

    if (![fileManager removeItemAtPath:stagingPath error:&fileError]
        || CQFileItemExists(fileManager, stagingPath)) {
        return CQExtensionError(26, [NSString stringWithFormat:@"Skill 已移出安装目录，但临时文件清理失败：%@",
            fileError.localizedDescription ?: @"请稍后重试"]);
    }
    for (NSString *target in targets) {
        if (CQFileItemExists(fileManager, target)) {
            return CQExtensionError(27, [NSString stringWithFormat:@"卸载校验失败，仍检测到：%@", target]);
        }
    }
    return nil;
}

- (void)uninstallItem:(CQExtensionItem *)item completion:(void (^)(NSError *error))completion {
    NSError *validationError = nil;
    if (!item || item.kind != CQExtensionKindSkill) {
        validationError = CQExtensionError(10, @"当前仅支持卸载 Skill");
    } else if (self.checking || self.updating || self.uninstalling) {
        validationError = CQExtensionError(11, @"扩展管理正在执行其他操作，请稍后再试");
    }
    if (validationError) {
        if (completion) completion(validationError);
        return;
    }

    self.uninstalling = YES;
    self.lastError = nil;
    [self notifyChanged];
    NSArray<NSString *> *skillNames = item.skillNames.count > 0 ? item.skillNames : @[item.name];
    NSArray<NSString *> *paths = [item.paths copy];
    dispatch_async(self.uninstallQueue, ^{
        NSError *error = [self removeSkillDirectories:paths skillNames:skillNames];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.uninstalling = NO;
            BOOL completedWithWarning = [error.domain isEqualToString:CQExtensionErrorDomain]
                && (error.code == 26 || error.code == 27);
            if (error && !completedWithWarning) {
                self.lastError = error.localizedDescription;
                [self notifyChanged];
                if (completion) completion(error);
                return;
            }
            self.items = [self.items filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:
                ^BOOL(CQExtensionItem *candidate, NSDictionary *bindings) {
                    (void)bindings;
                    return ![candidate.identifier isEqualToString:item.identifier];
                }]];
            self.lastError = error.localizedDescription;
            [self notifyChanged];
            [self loadInstalledExtensions];
            if (completion) completion(error);
        });
    });
}

- (void)updateItem:(CQExtensionItem *)item {
    if (!item || self.checking || self.updating || self.uninstalling
        || item.updateState != CQExtensionUpdateStateUpdateAvailable) return;
    self.updating = YES;
    item.updateState = CQExtensionUpdateStateUpdating;
    item.errorMessage = nil;
    [self notifyChanged];
    if (item.kind == CQExtensionKindPlugin) [self updatePluginItem:item];
    else if (item.larkCLIManaged) [self updateLarkCLIItem:item];
    else [self updateSkillItem:item];
}

- (void)updatePluginItem:(CQExtensionItem *)item {
    __weak typeof(self) weakSelf = self;
    [self ensureClient:^(CQCodexClient *client, NSError *clientError) {
        typeof(self) self = weakSelf;
        if (!self) return;
        if (!client) {
            item.updateState = CQExtensionUpdateStateFailed;
            item.errorMessage = clientError.localizedDescription;
            [self finishUpdatingAndRefresh:NO];
            return;
        }
        [client installPluginNamed:item.name
                   marketplacePath:item.marketplacePath
              remoteMarketplaceName:item.remoteMarketplaceName
                         completion:^(NSDictionary *result, NSError *error) {
            (void)result;
            if (error) {
                item.updateState = CQExtensionUpdateStateFailed;
                item.errorMessage = error.localizedDescription ?: @"插件更新失败";
                [self.client stop];
                self.client = nil;
                [self finishUpdatingAndRefresh:NO];
                return;
            }
            [self.client stop];
            self.client = nil;
            [self finishUpdatingAndRefresh:YES];
        }];
    }];
}

- (void)updateLarkCLIItem:(CQExtensionItem *)item {
    NSString *larkCLI = [self larkCLIPath];
    if (!larkCLI) {
        item.updateState = CQExtensionUpdateStateFailed;
        item.errorMessage = @"未找到 lark-cli；请参考 www.feishu.cn/feishu-cli 完成安装";
        [self finishUpdatingAndRefresh:NO];
        return;
    }
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:larkCLI];
    task.arguments = @[@"update", @"--json"];
    task.currentDirectoryURL = [NSURL fileURLWithPath:NSHomeDirectory() isDirectory:YES];
    NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    NSString *path = environment[@"PATH"] ?: @"/usr/bin:/bin";
    environment[@"PATH"] = [NSString stringWithFormat:@"/opt/homebrew/bin:/usr/local/bin:%@", path];
    environment[@"NO_COLOR"] = @"1";
    environment[@"CI"] = @"1";
    task.environment = environment;
    NSPipe *outputPipe = [NSPipe pipe];
    NSPipe *errorPipe = [NSPipe pipe];
    task.standardOutput = outputPipe;
    task.standardError = errorPipe;
    [self.updateTasks addObject:task];
    __weak typeof(self) weakSelf = self;
    __weak NSTask *weakTask = task;
    task.terminationHandler = ^(NSTask *finished) {
        NSData *outputData = [outputPipe.fileHandleForReading readDataToEndOfFile];
        NSData *errorData = [errorPipe.fileHandleForReading readDataToEndOfFile];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self) return;
            [self.updateTasks removeObject:weakTask];
            NSDictionary *result = outputData.length > 0
                ? CQExtensionDictionary([NSJSONSerialization JSONObjectWithData:outputData options:0 error:nil]) : nil;
            if (finished.terminationStatus == 0 && [result[@"ok"] boolValue]) {
                [self finishUpdatingAndRefresh:YES];
                return;
            }
            NSDictionary *error = CQExtensionDictionary(result[@"error"]);
            NSString *stderrText = [[[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            item.updateState = CQExtensionUpdateStateFailed;
            item.errorMessage = CQExtensionString(error[@"message"]);
            if (item.errorMessage.length == 0) item.errorMessage = stderrText.length > 0
                ? stderrText : @"飞书 CLI 更新失败，请检查网络后重试";
            [self finishUpdatingAndRefresh:NO];
        });
    };
    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        [self.updateTasks removeObject:task];
        item.updateState = CQExtensionUpdateStateFailed;
        item.errorMessage = launchError.localizedDescription ?: @"无法启动 lark-cli update";
        [self finishUpdatingAndRefresh:NO];
    }
}

- (NSString *)npxPath {
    for (NSString *path in @[@"/opt/homebrew/bin/npx", @"/usr/local/bin/npx", @"/usr/bin/npx"]) {
        if ([NSFileManager.defaultManager isExecutableFileAtPath:path]) return path;
    }
    return nil;
}

- (void)updateSkillItem:(CQExtensionItem *)item {
    NSString *npx = [self npxPath];
    if (!npx) {
        item.updateState = CQExtensionUpdateStateFailed;
        item.errorMessage = @"未找到 npx，无法更新独立 Skill";
        [self finishUpdatingAndRefresh:NO];
        return;
    }
    NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithObjects:@"--yes", @"skills", nil];
    if ([item.skillSourceType isEqualToString:@"well-known"]) {
        NSString *source = item.skillSourceURL.length > 0 ? item.skillSourceURL : item.skillSource;
        NSRange marker = [source rangeOfString:@"/.well-known/"];
        if (marker.location != NSNotFound) source = [source substringToIndex:marker.location];
        if (![source hasPrefix:@"https://"] && ![source hasPrefix:@"http://"]) {
            source = [@"https://" stringByAppendingString:source];
        }
        [arguments addObjectsFromArray:@[@"add", source, @"--skill", item.name, @"-g", @"-y"]];
    } else {
        [arguments addObjectsFromArray:@[@"update", item.name, @"-g", @"-y"]];
    }

    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:npx];
    task.arguments = arguments;
    task.currentDirectoryURL = [NSURL fileURLWithPath:NSHomeDirectory() isDirectory:YES];
    NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    NSString *path = environment[@"PATH"] ?: @"/usr/bin:/bin";
    environment[@"PATH"] = [NSString stringWithFormat:@"/opt/homebrew/bin:/usr/local/bin:%@", path];
    environment[@"NO_COLOR"] = @"1";
    environment[@"CI"] = @"1";
    task.environment = environment;
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    [self.updateTasks addObject:task];
    __weak typeof(self) weakSelf = self;
    __weak NSTask *weakTask = task;
    task.terminationHandler = ^(NSTask *finished) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self) return;
            [self.updateTasks removeObject:weakTask];
            if (finished.terminationStatus == 0) {
                [self finishUpdatingAndRefresh:YES];
            } else {
                item.updateState = CQExtensionUpdateStateFailed;
                item.errorMessage = @"Skill 更新失败，请检查网络或来源配置";
                [self finishUpdatingAndRefresh:NO];
            }
        });
    };
    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        [self.updateTasks removeObject:task];
        item.updateState = CQExtensionUpdateStateFailed;
        item.errorMessage = launchError.localizedDescription ?: @"无法启动 Skill 更新工具";
        [self finishUpdatingAndRefresh:NO];
    }
}

@end
