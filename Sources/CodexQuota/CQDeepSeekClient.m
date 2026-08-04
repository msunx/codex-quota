#import "CQDeepSeekClient.h"

static NSString * const CQDeepSeekErrorDomain = @"com.muyang.codexquota.deepseek";

@interface CQDeepSeekClient ()
@property(nonatomic, strong, nullable) NSURLSessionDataTask *task;
@end

@implementation CQDeepSeekClient

- (void)fetchBalanceWithAPIKey:(NSString *)apiKey completion:(CQDeepSeekBalanceBlock)completion {
    [self cancel];
    NSURL *url = [NSURL URLWithString:@"https://api.deepseek.com/user/balance"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    request.timeoutInterval = 15.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:[@"Bearer " stringByAppendingString:apiKey]
   forHTTPHeaderField:@"Authorization"];

    __weak typeof(self) weakSelf = self;
    self.task = [NSURLSession.sharedSession dataTaskWithRequest:request
                                             completionHandler:^(NSData *data,
                                                                 NSURLResponse *response,
                                                                 NSError *networkError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self) return;
            self.task = nil;
            if (networkError) {
                completion(nil, networkError);
                return;
            }

            NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class]
                ? (NSHTTPURLResponse *)response : nil;
            NSError *jsonError = nil;
            id object = data.length > 0
                ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError]
                : nil;
            NSDictionary *dictionary = [object isKindOfClass:NSDictionary.class] ? object : nil;
            if (http.statusCode < 200 || http.statusCode >= 300) {
                NSString *message = [dictionary[@"error"] isKindOfClass:NSDictionary.class]
                    ? dictionary[@"error"][@"message"] : nil;
                if (![message isKindOfClass:NSString.class] || message.length == 0) {
                    message = http.statusCode == 401
                        ? @"DeepSeek API Key 无效或已过期"
                        : [NSString stringWithFormat:@"DeepSeek 请求失败（HTTP %ld）", (long)http.statusCode];
                }
                NSError *error = [NSError errorWithDomain:CQDeepSeekErrorDomain
                                                       code:http.statusCode
                                                   userInfo:@{NSLocalizedDescriptionKey: message}];
                completion(nil, error);
                return;
            }
            if (!dictionary) {
                NSError *error = jsonError ?: [NSError errorWithDomain:CQDeepSeekErrorDomain
                                                                   code:-1
                                                               userInfo:@{NSLocalizedDescriptionKey: @"DeepSeek 返回了无法识别的数据"}];
                completion(nil, error);
                return;
            }
            completion([CQDeepSeekBalance balanceFromResponse:dictionary], nil);
        });
    }];
    [self.task resume];
}

- (void)cancel {
    [self.task cancel];
    self.task = nil;
}

@end
