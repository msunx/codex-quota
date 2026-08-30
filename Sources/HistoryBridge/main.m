#import <Foundation/Foundation.h>

static NSArray<NSString *> *CQVisibleModelProviders(void) {
    return @[@"openai", @"deepseek", @"zhipu", @"custom"];
}

static NSString *CQRealCLIPath(void) {
    NSString *configured = NSProcessInfo.processInfo.environment[@"CODEX_QUOTA_REAL_CLI_PATH"];
    if ([NSFileManager.defaultManager isExecutableFileAtPath:configured]) return configured;

    for (NSString *candidate in @[
        @"/Applications/ChatGPT.app/Contents/Resources/codex",
        @"/Applications/Codex.app/Contents/Resources/codex"
    ]) {
        if ([NSFileManager.defaultManager isExecutableFileAtPath:candidate]) return candidate;
    }
    return nil;
}

static NSData *CQRewrittenRequestLine(NSData *lineData) {
    if (lineData.length == 0) return lineData;

    static NSData *threadListMarker;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        threadListMarker = [@"thread/list" dataUsingEncoding:NSUTF8StringEncoding];
    });
    if ([lineData rangeOfData:threadListMarker
                     options:0
                       range:NSMakeRange(0, lineData.length)].location == NSNotFound) return lineData;

    NSError *jsonError = nil;
    id object = [NSJSONSerialization JSONObjectWithData:lineData options:NSJSONReadingMutableContainers error:&jsonError];
    if (jsonError || ![object isKindOfClass:NSMutableDictionary.class]) return lineData;

    NSMutableDictionary *request = object;
    if (![request[@"method"] isEqualToString:@"thread/list"]) return lineData;

    id paramsValue = request[@"params"];
    NSMutableDictionary *params = [paramsValue isKindOfClass:NSDictionary.class]
        ? [paramsValue mutableCopy] : [NSMutableDictionary dictionary];
    id providers = params[@"modelProviders"];
    if (providers && providers != NSNull.null) return lineData;

    params[@"modelProviders"] = CQVisibleModelProviders();
    request[@"params"] = params;
    NSData *rewritten = [NSJSONSerialization dataWithJSONObject:request options:0 error:&jsonError];
    return rewritten ?: lineData;
}

static BOOL CQShouldBridgeAppServer(NSArray<NSString *> *arguments) {
    NSUInteger appServerIndex = [arguments indexOfObject:@"app-server"];
    if (appServerIndex == NSNotFound) return NO;
    NSSet<NSString *> *nonTransportCommands = [NSSet setWithArray:@[
        @"daemon", @"proxy", @"generate-ts", @"generate-json-schema", @"help"
    ]];
    NSUInteger nextIndex = appServerIndex + 1;
    return nextIndex >= arguments.count
        || ![nonTransportCommands containsObject:arguments[nextIndex]];
}

static int CQRunTask(NSURL *executableURL, NSArray<NSString *> *arguments, BOOL bridgeRequests) {
    NSTask *task = [NSTask new];
    task.executableURL = executableURL;
    task.arguments = arguments;
    task.standardOutput = NSFileHandle.fileHandleWithStandardOutput;
    task.standardError = NSFileHandle.fileHandleWithStandardError;

    NSPipe *childInput = nil;
    if (bridgeRequests) {
        childInput = [NSPipe pipe];
        task.standardInput = childInput;
    } else {
        task.standardInput = NSFileHandle.fileHandleWithStandardInput;
    }

    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        fprintf(stderr, "Codex Quota history bridge: %s\n", launchError.localizedDescription.UTF8String);
        return 127;
    }

    if (bridgeRequests) {
        NSFileHandle *source = NSFileHandle.fileHandleWithStandardInput;
        NSFileHandle *destination = childInput.fileHandleForWriting;
        NSMutableData *buffer = [NSMutableData data];

        while (YES) {
            NSData *chunk = source.availableData;
            if (chunk.length == 0) break;
            [buffer appendData:chunk];

            while (YES) {
                const uint8_t *bytes = buffer.bytes;
                NSUInteger newlineIndex = NSNotFound;
                for (NSUInteger index = 0; index < buffer.length; index++) {
                    if (bytes[index] == '\n') {
                        newlineIndex = index;
                        break;
                    }
                }
                if (newlineIndex == NSNotFound) break;

                NSData *line = [buffer subdataWithRange:NSMakeRange(0, newlineIndex)];
                NSData *rewritten = CQRewrittenRequestLine(line);
                [destination writeData:rewritten];
                [destination writeData:[NSData dataWithBytes:"\n" length:1]];
                [buffer replaceBytesInRange:NSMakeRange(0, newlineIndex + 1) withBytes:NULL length:0];
            }
        }

        if (buffer.length > 0) [destination writeData:CQRewrittenRequestLine(buffer)];
        [destination closeFile];
    }

    [task waitUntilExit];
    return task.terminationReason == NSTaskTerminationReasonExit ? task.terminationStatus : 1;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *realCLIPath = CQRealCLIPath();
        if (realCLIPath.length == 0) {
            fprintf(stderr, "Codex Quota history bridge: real Codex CLI is unavailable\n");
            return 127;
        }

        NSMutableArray<NSString *> *arguments = [NSMutableArray array];
        for (int index = 1; index < argc; index++) {
            [arguments addObject:[NSString stringWithUTF8String:argv[index]]];
        }
        return CQRunTask([NSURL fileURLWithPath:realCLIPath], arguments,
                         CQShouldBridgeAppServer(arguments));
    }
}
