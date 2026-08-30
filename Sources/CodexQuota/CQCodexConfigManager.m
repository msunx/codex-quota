#import "CQCodexConfigManager.h"
#import <Security/Security.h>

static NSString * const CQConfigErrorDomain = @"com.muyang.codexquota.config";
static NSString * const CQProviderModeDefaultsKey = @"ProviderMode";
static NSString * const CQDeepSeekManagedMarker = @"# Managed by Codex Quota — DeepSeek";
static NSString * const CQGLMManagedMarker = @"# Managed by Codex Quota — GLM";
static NSString * const CQDeepSeekKeychainService = @"com.muyang.codexquota.deepseek";
static NSString * const CQGLMKeychainService = @"com.muyang.codexquota.glm";
static NSString * const CQKeychainAccount = @"api-key";

@interface CQCodexConfigManager ()
@property(nonatomic, readwrite) NSURL *codexHomeURL;
@property(nonatomic, strong) NSFileManager *fileManager;
@end

@implementation CQCodexConfigManager

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _fileManager = NSFileManager.defaultManager;
    NSString *customHome = NSProcessInfo.processInfo.environment[@"CODEX_HOME"];
    NSString *path = customHome.length > 0
        ? customHome.stringByExpandingTildeInPath
        : [@"~/.codex" stringByExpandingTildeInPath];
    _codexHomeURL = [NSURL fileURLWithPath:path isDirectory:YES];
    return self;
}

- (NSURL *)configURL {
    return [self.codexHomeURL URLByAppendingPathComponent:@"config.toml" isDirectory:NO];
}

- (NSURL *)modelsURL {
    return [self.codexHomeURL URLByAppendingPathComponent:@"models.json" isDirectory:NO];
}

- (NSURL *)modelsCacheURL {
    return [self.codexHomeURL URLByAppendingPathComponent:@"models_cache.json" isDirectory:NO];
}

- (NSURL *)backupURL {
    return [self.codexHomeURL URLByAppendingPathComponent:@"codex-quota-backup" isDirectory:YES];
}

- (NSURL *)backupConfigURL {
    return [[self backupURL] URLByAppendingPathComponent:@"config.toml" isDirectory:NO];
}

- (NSURL *)backupModelsURL {
    return [[self backupURL] URLByAppendingPathComponent:@"models.json" isDirectory:NO];
}

- (NSURL *)manifestURL {
    return [[self backupURL] URLByAppendingPathComponent:@"manifest.plist" isDirectory:NO];
}

- (NSError *)errorWithCode:(NSInteger)code description:(NSString *)description {
    return [NSError errorWithDomain:CQConfigErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

- (NSString *)stringAtURL:(NSURL *)url {
    return [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
}

- (CQProviderMode)currentMode {
    NSString *config = [self stringAtURL:self.configURL];
    if ([config containsString:CQDeepSeekManagedMarker]) return CQProviderModeDeepSeek;
    if ([config containsString:CQGLMManagedMarker]) return CQProviderModeGLM;
    return CQProviderModeCodex;
}

- (NSString *)currentModelWithMarker:(NSString *)marker
                       allowedModels:(NSArray<NSString *> *)allowedModels
                            fallback:(NSString *)fallback {
    NSString *config = [self stringAtURL:self.configURL];
    if (![config containsString:marker]) return fallback;
    NSRegularExpression *expression = [NSRegularExpression
        regularExpressionWithPattern:@"(?m)^\\s*model\\s*=\\s*\"([^\"]+)\""
                              options:0
                                error:nil];
    NSTextCheckingResult *match = [expression firstMatchInString:config
                                                       options:0
                                                         range:NSMakeRange(0, config.length)];
    if (match.numberOfRanges >= 2) {
        NSString *model = [config substringWithRange:[match rangeAtIndex:1]];
        if ([allowedModels containsObject:model]) return model;
    }
    return fallback;
}

- (NSString *)currentDeepSeekModel {
    return [self currentModelWithMarker:CQDeepSeekManagedMarker
                          allowedModels:@[CQDeepSeekFlashModel, CQDeepSeekProModel]
                               fallback:CQDeepSeekFlashModel];
}

- (NSString *)currentGLMModel {
    return [self currentModelWithMarker:CQGLMManagedMarker
                          allowedModels:@[CQGLMFlashModel, CQGLMModel]
                               fallback:CQGLMFlashModel];
}

- (BOOL)managedConfigurationNeedsHistoryMigration {
    NSString *current = [self stringAtURL:self.configURL];
    if (![current containsString:CQDeepSeekManagedMarker]
        && ![current containsString:CQGLMManagedMarker]) return NO;
    NSString *original = [self originalConfig];
    NSArray<NSString *> *forcedLines = @[
        @"preferred_auth_method = \"apikey\"",
        @"forced_login_method = \"api\""
    ];
    for (NSString *line in forcedLines) {
        if ([current containsString:line] && ![original containsString:line]) return YES;
    }
    return NO;
}

- (NSString *)savedAPIKeyForService:(NSString *)service marker:(NSString *)marker {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: service,
        (__bridge id)kSecAttrAccount: CQKeychainAccount,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status == errSecSuccess && result) {
        NSData *data = CFBridgingRelease(result);
        NSString *key = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (key.length > 0) return key;
    } else if (result) {
        CFRelease(result);
    }

    NSString *config = [self stringAtURL:self.configURL];
    if (![config containsString:marker]) return nil;
    NSRegularExpression *expression = [NSRegularExpression
        regularExpressionWithPattern:@"experimental_bearer_token\\s*=\\s*\"([^\"]+)\""
                              options:0
                                error:nil];
    NSTextCheckingResult *match = [expression firstMatchInString:config ?: @""
                                                       options:0
                                                         range:NSMakeRange(0, config.length)];
    if (match.numberOfRanges < 2) return nil;
    return [config substringWithRange:[match rangeAtIndex:1]];
}

- (NSString *)savedDeepSeekAPIKey {
    return [self savedAPIKeyForService:CQDeepSeekKeychainService marker:CQDeepSeekManagedMarker];
}

- (NSString *)savedGLMAPIKey {
    return [self savedAPIKeyForService:CQGLMKeychainService marker:CQGLMManagedMarker];
}

- (BOOL)saveAPIKey:(NSString *)apiKey
            service:(NSString *)service
       providerName:(NSString *)providerName
              error:(NSError **)error {
    NSData *data = [apiKey dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: service,
        (__bridge id)kSecAttrAccount: CQKeychainAccount
    };
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query,
                                    (__bridge CFDictionaryRef)@{(__bridge id)kSecValueData: data});
    if (status == errSecItemNotFound) {
        NSMutableDictionary *item = [query mutableCopy];
        item[(__bridge id)kSecValueData] = data;
        item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
        status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
    }
    if (status == errSecSuccess) return YES;
    if (error) {
        *error = [self errorWithCode:status
                         description:[NSString stringWithFormat:@"无法将 %@ API Key 保存到 macOS 钥匙串", providerName]];
    }
    return NO;
}

- (BOOL)validateAPIKey:(NSString *)apiKey
        requiredPrefix:(NSString *)requiredPrefix
          providerName:(NSString *)providerName
                 error:(NSError **)error {
    NSString *trimmed = [apiKey stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    BOOL valid = [trimmed isEqualToString:apiKey]
        && (requiredPrefix.length == 0 || [apiKey hasPrefix:requiredPrefix])
        && apiKey.length > 5
        && [apiKey rangeOfString:@"\""].location == NSNotFound
        && [apiKey rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location == NSNotFound;
    if (valid) return YES;
    if (error) {
        NSString *prefixHint = requiredPrefix.length > 0 ? [NSString stringWithFormat:@"以 %@ 开头的", requiredPrefix] : @"";
        *error = [self errorWithCode:-1
                         description:[NSString stringWithFormat:@"请输入%@有效 %@ API Key", prefixHint, providerName]];
    }
    return NO;
}

- (NSDictionary *)backupManifest {
    return [NSDictionary dictionaryWithContentsOfURL:self.manifestURL];
}

- (void)removeIncompleteBackup {
    if ([self.fileManager fileExistsAtPath:self.backupURL.path]) {
        [self.fileManager removeItemAtURL:self.backupURL error:nil];
    }
}

- (BOOL)prepareBackupWithError:(NSError **)error {
    if ([self.fileManager fileExistsAtPath:self.backupURL.path]) {
        if ([self backupManifest]) return YES;
        if (error) *error = [self errorWithCode:-2 description:@"Codex Quota 的配置备份不完整，请先检查 ~/.codex/codex-quota-backup"];
        return NO;
    }

    NSString *currentConfig = [self stringAtURL:self.configURL];
    BOOL hasUnmanagedDeepSeek = [currentConfig containsString:@"[model_providers.deepseek]"]
        && ![currentConfig containsString:CQDeepSeekManagedMarker];
    BOOL hasUnmanagedGLM = [currentConfig containsString:@"[model_providers.zhipu]"]
        && ![currentConfig containsString:CQGLMManagedMarker];
    if (hasUnmanagedDeepSeek || hasUnmanagedGLM) {
        NSString *provider = hasUnmanagedDeepSeek ? @"DeepSeek" : @"GLM";
        NSString *description = [NSString stringWithFormat:
            @"检测到其他工具写入的 %@ 配置。请先恢复默认 Codex 配置，再使用此开关。", provider];
        if (error) *error = [self errorWithCode:-3 description:description];
        return NO;
    }

    NSError *fileError = nil;
    if (![self.fileManager createDirectoryAtURL:self.codexHomeURL
                    withIntermediateDirectories:YES
                                     attributes:nil
                                          error:&fileError]
        || ![self.fileManager createDirectoryAtURL:self.backupURL
                       withIntermediateDirectories:NO
                                        attributes:nil
                                             error:&fileError]) {
        if (error) *error = fileError;
        return NO;
    }

    BOOL configExisted = [self.fileManager fileExistsAtPath:self.configURL.path];
    BOOL modelsExisted = [self.fileManager fileExistsAtPath:self.modelsURL.path];
    if (configExisted && ![self.fileManager copyItemAtURL:self.configURL toURL:self.backupConfigURL error:&fileError]) {
        [self removeIncompleteBackup];
        if (error) *error = fileError;
        return NO;
    }
    if (modelsExisted && ![self.fileManager copyItemAtURL:self.modelsURL toURL:self.backupModelsURL error:&fileError]) {
        [self removeIncompleteBackup];
        if (error) *error = fileError;
        return NO;
    }
    NSDictionary *manifest = @{
        @"configExisted": @(configExisted),
        @"modelsExisted": @(modelsExisted),
        @"createdAt": NSDate.date
    };
    if (![manifest writeToURL:self.manifestURL atomically:YES]) {
        [self removeIncompleteBackup];
        if (error) *error = [self errorWithCode:-4 description:@"无法写入 Codex 配置备份清单"];
        return NO;
    }
    return YES;
}

- (NSString *)originalConfig {
    NSDictionary *manifest = [self backupManifest];
    return [manifest[@"configExisted"] boolValue] ? ([self stringAtURL:self.backupConfigURL] ?: @"") : @"";
}

- (NSString *)filteredOriginalConfig:(NSString *)original {
    NSSet<NSString *> *controlledKeys = [NSSet setWithArray:@[
        @"model", @"model_provider", @"model_reasoning_effort", @"model_catalog_json",
        @"profile", @"oss_provider",
        @"openai_base_url", @"model_context_window", @"model_auto_compact_token_limit",
        @"model_auto_compact_token_limit_scope", @"base_instructions", @"model_instructions_file",
        @"compact_prompt", @"experimental_compact_prompt_file", @"service_tier", @"model_verbosity",
        @"model_reasoning_summary", @"plan_mode_reasoning_effort", @"experimental_use_unified_exec_tool"
    ]];
    NSArray<NSString *> *lines = [original componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    NSMutableArray<NSString *> *kept = [NSMutableArray arrayWithCapacity:lines.count];
    BOOL inTopLevel = YES;
    BOOL skipSection = NO;
    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([trimmed hasPrefix:@"["] && [trimmed hasSuffix:@"]"]) {
            inTopLevel = NO;
            NSString *section = [trimmed stringByTrimmingCharactersInSet:
                [NSCharacterSet characterSetWithCharactersInString:@"[] "]];
            skipSection = [section isEqualToString:@"model_providers.deepseek"]
                || [section isEqualToString:@"model_providers.zhipu"]
                || [section isEqualToString:@"profiles"]
                || [section hasPrefix:@"profiles."];
            if (!skipSection) [kept addObject:line];
            continue;
        }
        if (skipSection) continue;
        if (inTopLevel) {
            NSRange equals = [trimmed rangeOfString:@"="];
            if (equals.location != NSNotFound) {
                NSString *key = [[trimmed substringToIndex:equals.location]
                    stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                key = [key stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\"'"]];
                if ([controlledKeys containsObject:key]) continue;
            }
        }
        [kept addObject:line];
    }
    NSString *result = [kept componentsJoinedByString:@"\n"];
    return [result stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

- (NSString *)tomlEscapedString:(NSString *)value {
    return [[value stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
        stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
}

- (NSString *)deepSeekConfigForModel:(NSString *)model apiKey:(NSString *)apiKey original:(NSString *)original {
    NSString *preserved = [self filteredOriginalConfig:original];
    NSMutableString *config = [NSMutableString string];
    [config appendFormat:@"%@\n", CQDeepSeekManagedMarker];
    [config appendFormat:@"model = \"%@\"\n", [self tomlEscapedString:model]];
    [config appendString:@"model_provider = \"deepseek\"\n"];
    [config appendString:@"model_reasoning_effort = \"high\"\n"];
    [config appendFormat:@"model_catalog_json = \"%@\"\n",
        [self tomlEscapedString:self.modelsURL.path]];
    if (preserved.length > 0) [config appendFormat:@"\n%@\n", preserved];
    [config appendString:@"\n[model_providers.deepseek]\n"];
    [config appendString:@"name = \"deepseek\"\n"];
    [config appendString:@"base_url = \"https://api.deepseek.com/\"\n"];
    [config appendString:@"wire_api = \"responses\"\n"];
    [config appendFormat:@"experimental_bearer_token = \"%@\"\n", [self tomlEscapedString:apiKey]];
    return config;
}

- (NSString *)glmConfigForModel:(NSString *)model apiKey:(NSString *)apiKey original:(NSString *)original {
    NSString *preserved = [self filteredOriginalConfig:original];
    NSMutableString *config = [NSMutableString string];
    [config appendFormat:@"%@\n", CQGLMManagedMarker];
    [config appendFormat:@"model = \"%@\"\n", [self tomlEscapedString:model]];
    [config appendString:@"model_provider = \"zhipu\"\n"];
    [config appendString:@"model_reasoning_effort = \"high\"\n"];
    [config appendString:@"model_context_window = 1000000\n"];
    [config appendFormat:@"model_catalog_json = \"%@\"\n",
        [self tomlEscapedString:self.modelsURL.path]];
    if (preserved.length > 0) [config appendFormat:@"\n%@\n", preserved];
    [config appendString:@"\n[model_providers.zhipu]\n"];
    [config appendString:@"name = \"Zhipu GLM\"\n"];
    [config appendString:@"base_url = \"https://open.bigmodel.cn/api/v1\"\n"];
    [config appendString:@"wire_api = \"responses\"\n"];
    [config appendFormat:@"experimental_bearer_token = \"%@\"\n", [self tomlEscapedString:apiKey]];
    return config;
}

- (NSDictionary *)templateModelMetadata {
    NSData *data = [NSData dataWithContentsOfURL:self.modelsCacheURL];
    if (!data) return @{};
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSArray *models = [object isKindOfClass:NSDictionary.class]
        && [object[@"models"] isKindOfClass:NSArray.class] ? object[@"models"] : nil;
    for (id value in models) {
        if (![value isKindOfClass:NSDictionary.class]) continue;
        NSString *slug = [value[@"slug"] isKindOfClass:NSString.class] ? value[@"slug"] : @"";
        if ([slug hasPrefix:@"gpt-5"]) return value;
    }
    return [models.firstObject isKindOfClass:NSDictionary.class] ? models.firstObject : @{};
}

- (NSDictionary *)deepSeekModelCatalog {
    NSDictionary *template = [self templateModelMetadata];
    NSMutableDictionary *model = [@{
        @"slug": CQDeepSeekFlashModel,
        @"prefer_websockets": @NO,
        @"support_verbosity": @YES,
        @"default_verbosity": @"low",
        @"apply_patch_tool_type": @"freeform",
        @"web_search_tool_type": @"text",
        @"input_modalities": @[@"text"],
        @"supports_image_detail_original": @NO,
        @"truncation_policy": @{@"mode": @"tokens", @"limit": @10000},
        @"supports_parallel_tool_calls": @YES,
        @"tool_mode": NSNull.null,
        @"multi_agent_version": @"v2",
        @"use_responses_lite": @NO,
        @"include_skills_usage_instructions": @NO,
        @"auto_review_model_override": NSNull.null,
        @"context_window": @1048576,
        @"max_context_window": @1048576,
        @"effective_context_window_percent": @95,
        @"auto_compact_token_limit": NSNull.null,
        @"comp_hash": @"3000",
        @"reasoning_summary_format": @"experimental",
        @"default_reasoning_summary": @"none",
        @"display_name": @"DeepSeek-V4-Flash",
        @"description": @"Latest frontier agentic coding model.",
        @"default_reasoning_level": @"high",
        @"supported_reasoning_levels": @[
            @{@"effort": @"low", @"description": @"Fast responses with lighter reasoning"},
            @{@"effort": @"high", @"description": @"Extra high reasoning depth for complex problems"},
            @{@"effort": @"max", @"description": @"Maximum reasoning depth for the hardest problems"}
        ],
        @"shell_type": @"shell_command",
        @"visibility": @"list",
        @"minimal_client_version": @"0.144.0",
        @"supported_in_api": @YES,
        @"availability_nux": NSNull.null,
        @"upgrade": NSNull.null,
        @"priority": @1,
        @"experimental_supported_tools": @[],
        @"supports_search_tool": @YES,
        @"default_service_tier": NSNull.null,
        @"supports_reasoning_summaries": @YES
    } mutableCopy];
    for (NSString *key in @[@"base_instructions", @"model_messages"]) {
        if (template[key]) model[key] = template[key];
    }
    NSMutableDictionary *proModel = [model mutableCopy];
    proModel[@"slug"] = CQDeepSeekProModel;
    proModel[@"display_name"] = @"DeepSeek-V4-Pro";
    proModel[@"description"] = @"Most capable frontier agentic coding model.";
    proModel[@"priority"] = @2;
    return @{ @"models": @[model, proModel] };
}

- (NSDictionary *)glmModelCatalog {
    NSDictionary *deepSeekCatalog = [self deepSeekModelCatalog];
    NSMutableDictionary *flashModel = [deepSeekCatalog[@"models"][0] mutableCopy];
    flashModel[@"slug"] = CQGLMFlashModel;
    flashModel[@"display_name"] = @"GLM-5.3-Flash";
    flashModel[@"description"] = @"Fast multimodal agentic coding model.";
    flashModel[@"input_modalities"] = @[@"text", @"image"];
    flashModel[@"supports_image_detail_original"] = @YES;
    flashModel[@"context_window"] = @1000000;
    flashModel[@"max_context_window"] = @1000000;

    NSMutableDictionary *flagshipModel = [flashModel mutableCopy];
    flagshipModel[@"slug"] = CQGLMModel;
    flagshipModel[@"display_name"] = @"GLM-5.3";
    flagshipModel[@"description"] = @"Flagship agentic coding model.";
    flagshipModel[@"input_modalities"] = @[@"text"];
    flagshipModel[@"supports_image_detail_original"] = @NO;
    flagshipModel[@"priority"] = @2;
    return @{ @"models": @[flashModel, flagshipModel] };
}

- (BOOL)writeModelCatalog:(NSDictionary *)catalog
                    config:(NSString *)config
                      mode:(CQProviderMode)mode
                     error:(NSError **)error {
    NSError *jsonError = nil;
    NSData *modelsData = [NSJSONSerialization dataWithJSONObject:catalog
                                                         options:NSJSONWritingPrettyPrinted
                                                           error:&jsonError];
    if (!modelsData) {
        if (error) *error = jsonError;
        return NO;
    }
    NSError *writeError = nil;
    if (![modelsData writeToURL:self.modelsURL options:NSDataWritingAtomic error:&writeError]) {
        if (error) *error = writeError;
        return NO;
    }
    if (![config writeToURL:self.configURL atomically:YES encoding:NSUTF8StringEncoding error:&writeError]) {
        NSDictionary *manifest = [self backupManifest];
        [self restoreOriginalFileAtURL:self.modelsURL
                             backupURL:self.backupModelsURL
                                existed:[manifest[@"modelsExisted"] boolValue]
                                  error:nil];
        if (error) *error = writeError;
        return NO;
    }
    [NSUserDefaults.standardUserDefaults setInteger:mode forKey:CQProviderModeDefaultsKey];
    return YES;
}

- (BOOL)switchToDeepSeekModel:(NSString *)model apiKey:(NSString *)apiKey error:(NSError **)error {
    if (![model isEqualToString:CQDeepSeekFlashModel]
        && ![model isEqualToString:CQDeepSeekProModel]) {
        if (error) *error = [self errorWithCode:-5 description:@"不支持的 DeepSeek 模型"];
        return NO;
    }
    if (![self validateAPIKey:apiKey requiredPrefix:@"sk-" providerName:@"DeepSeek" error:error]
        || ![self saveAPIKey:apiKey service:CQDeepSeekKeychainService providerName:@"DeepSeek" error:error]
        || ![self prepareBackupWithError:error]) return NO;

    NSString *config = [self deepSeekConfigForModel:model apiKey:apiKey original:[self originalConfig]];
    return [self writeModelCatalog:[self deepSeekModelCatalog]
                            config:config
                              mode:CQProviderModeDeepSeek
                             error:error];
}

- (BOOL)switchToGLMModel:(NSString *)model apiKey:(NSString *)apiKey error:(NSError **)error {
    if (![model isEqualToString:CQGLMFlashModel] && ![model isEqualToString:CQGLMModel]) {
        if (error) *error = [self errorWithCode:-7 description:@"不支持的 GLM 模型"];
        return NO;
    }
    if (![self validateAPIKey:apiKey requiredPrefix:@"" providerName:@"智谱" error:error]
        || ![self saveAPIKey:apiKey service:CQGLMKeychainService providerName:@"智谱" error:error]
        || ![self prepareBackupWithError:error]) return NO;

    NSString *config = [self glmConfigForModel:model apiKey:apiKey original:[self originalConfig]];
    return [self writeModelCatalog:[self glmModelCatalog]
                            config:config
                              mode:CQProviderModeGLM
                             error:error];
}

- (BOOL)restoreOriginalFileAtURL:(NSURL *)target
                       backupURL:(NSURL *)backup
                          existed:(BOOL)existed
                            error:(NSError **)error {
    if (!existed) {
        if (![self.fileManager fileExistsAtPath:target.path]) return YES;
        return [self.fileManager removeItemAtURL:target error:error];
    }
    NSData *data = [NSData dataWithContentsOfURL:backup options:0 error:error];
    return data && [data writeToURL:target options:NSDataWritingAtomic error:error];
}

- (BOOL)switchToCodexWithError:(NSError **)error {
    NSDictionary *manifest = [self backupManifest];
    if (!manifest) {
        NSString *config = [self stringAtURL:self.configURL];
        if ([config containsString:CQDeepSeekManagedMarker]
            || [config containsString:CQGLMManagedMarker]) {
            if (error) *error = [self errorWithCode:-6 description:@"找不到原始 Codex 配置备份，未执行恢复"];
            return NO;
        }
        [NSUserDefaults.standardUserDefaults setInteger:CQProviderModeCodex forKey:CQProviderModeDefaultsKey];
        return YES;
    }

    NSError *fileError = nil;
    if (![self restoreOriginalFileAtURL:self.configURL
                             backupURL:self.backupConfigURL
                                existed:[manifest[@"configExisted"] boolValue]
                                  error:&fileError]
        || ![self restoreOriginalFileAtURL:self.modelsURL
                                 backupURL:self.backupModelsURL
                                    existed:[manifest[@"modelsExisted"] boolValue]
                                      error:&fileError]) {
        if (error) *error = fileError;
        return NO;
    }
    if (![self.fileManager removeItemAtURL:self.backupURL error:&fileError]) {
        if (error) *error = fileError;
        return NO;
    }
    [NSUserDefaults.standardUserDefaults setInteger:CQProviderModeCodex forKey:CQProviderModeDefaultsKey];
    return YES;
}

@end
