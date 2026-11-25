#import "CQCodexConfigManager.h"
#include <errno.h>
#include <unistd.h>

static BOOL CQIsMissingFileError(NSError *error) {
    return [error.domain isEqualToString:NSCocoaErrorDomain]
        && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError);
}

static BOOL CQRestoreFile(NSURL *url, NSData *original, NSError **error) {
    if (original) return [original writeToURL:url options:NSDataWritingAtomic error:error];

    if (unlink(url.fileSystemRepresentation) == 0) return YES;
    int removeError = errno;
    if (removeError == ENOENT) return YES;
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:removeError userInfo:@{NSURLErrorKey: url}];
    return NO;
}

@implementation CQCodexConfigManager

- (BOOL)restoreLegacyConfigurationIfNeededWithError:(NSError **)error {
    NSString *customHome = NSProcessInfo.processInfo.environment[@"CODEX_HOME"];
    NSString *home = customHome.length > 0 ? customHome : @"~/.codex";
    NSURL *codexHome = [NSURL fileURLWithPath:home.stringByExpandingTildeInPath isDirectory:YES];
    NSURL *configURL = [codexHome URLByAppendingPathComponent:@"config.toml" isDirectory:NO];

    NSError *readError = nil;
    NSString *config = [NSString stringWithContentsOfURL:configURL encoding:NSUTF8StringEncoding error:&readError];
    if (!config) {
        if (CQIsMissingFileError(readError)) return YES;
        if (error) *error = readError;
        return NO;
    }
    NSString *marker = [config componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet].firstObject;
    if (![marker isEqualToString:@"# Managed by Codex Quota — DeepSeek"] && ![marker isEqualToString:@"# Managed by Codex Quota — GLM"]) return YES;

    NSURL *backup = [codexHome URLByAppendingPathComponent:@"codex-quota-backup" isDirectory:YES];
    NSURL *manifestURL = [backup URLByAppendingPathComponent:@"manifest.plist" isDirectory:NO];
    NSDictionary *manifest = [NSDictionary dictionaryWithContentsOfURL:manifestURL];
    NSNumber *configExisted = manifest[@"configExisted"];
    NSNumber *modelsExisted = manifest[@"modelsExisted"];
    if (![configExisted isKindOfClass:NSNumber.class] || ![modelsExisted isKindOfClass:NSNumber.class]) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.muyang.codexquota.config" code:1 userInfo:@{
                NSLocalizedDescriptionKey: @"原始配置备份缺失或不完整，请检查 Codex 配置目录下的 codex-quota-backup。"
            }];
        }
        return NO;
    }

    NSURL *modelsURL = [codexHome URLByAppendingPathComponent:@"models.json" isDirectory:NO];
    NSData *originalConfig = nil;
    NSData *originalModels = nil;
    if (configExisted.boolValue) {
        NSURL *originalURL = [backup URLByAppendingPathComponent:@"config.toml" isDirectory:NO];
        originalConfig = [NSData dataWithContentsOfURL:originalURL options:0 error:error];
        if (!originalConfig) return NO;
    }
    if (modelsExisted.boolValue) {
        NSURL *originalURL = [backup URLByAppendingPathComponent:@"models.json" isDirectory:NO];
        originalModels = [NSData dataWithContentsOfURL:originalURL options:0 error:error];
        if (!originalModels) return NO;
    }

    // Restore config.toml last so its marker remains available if restoring the catalog fails.
    return CQRestoreFile(modelsURL, originalModels, error) && CQRestoreFile(configURL, originalConfig, error);
}

@end
