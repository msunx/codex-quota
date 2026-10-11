#import "CQTaskRolloutReader.h"
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

static NSUInteger const CQRolloutReadChunkBytes = 64 * 1024;
static NSUInteger const CQRolloutMaximumLineBytes = 32 * 1024 * 1024;

@interface CQRolloutCursor : NSObject
@property(nonatomic, copy) NSString *path;
@property(nonatomic) ino_t inode;
@property(nonatomic) off_t size;
@property(nonatomic) off_t offset;
@property(nonatomic, strong) NSDate *modifiedAt;
@property(nonatomic, copy, nullable) NSDictionary *turn;
@end

@implementation CQRolloutCursor
@end

@interface CQTaskRolloutReader ()
@property(nonatomic, strong) NSMutableDictionary<NSString *, CQRolloutCursor *> *cursors;
@property(nonatomic, strong) NSISO8601DateFormatter *dateFormatter;
@end

@implementation CQTaskRolloutReader

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _cursors = [NSMutableDictionary dictionary];
    _dateFormatter = [NSISO8601DateFormatter new];
    _dateFormatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    return self;
}

- (void)retainThreads:(NSSet<NSString *> *)threadIDs {
    for (NSString *threadID in self.cursors.allKeys) {
        if (![threadIDs containsObject:threadID]) [self.cursors removeObjectForKey:threadID];
    }
}

- (nullable NSDictionary *)turnFromLine:(NSData *)line previousTurn:(nullable NSDictionary *)previous {
    // Avoid decoding message bodies and tool output; only lifecycle event lines need JSON parsing.
    BOOL lifecycle = NO;
    for (NSString *marker in @[@"\"task_started\"", @"\"task_complete\"", @"\"turn_aborted\""]) {
        if ([line rangeOfData:[marker dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0, line.length)].location != NSNotFound) {
            lifecycle = YES;
            break;
        }
    }
    if (!lifecycle) return nil;
    id record = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
    if (![record isKindOfClass:NSDictionary.class] || ![record[@"type"] isEqual:@"event_msg"]) return nil;
    NSDictionary *payload = record[@"payload"];
    if (![payload isKindOfClass:NSDictionary.class]) return nil;
    NSString *type = payload[@"type"];
    if (![@[@"task_started", @"task_complete", @"turn_aborted"] containsObject:type ?: @""]) return nil;
    NSString *turnID = payload[@"turn_id"];
    if (![turnID isKindOfClass:NSString.class] || turnID.length == 0) return nil;
    NSString *timestamp = record[@"timestamp"];
    if (![timestamp isKindOfClass:NSString.class]) return nil;
    NSDate *date = [self.dateFormatter dateFromString:timestamp];
    if (!date) {
        self.dateFormatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
        date = [self.dateFormatter dateFromString:timestamp];
        self.dateFormatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    }
    if (!date) return nil;
    BOOL running = [type isEqual:@"task_started"];
    NSNumber *startedAt = [payload[@"started_at"] isKindOfClass:NSNumber.class] ? payload[@"started_at"] : nil;
    NSNumber *completedAt = [payload[@"completed_at"] isKindOfClass:NSNumber.class] ? payload[@"completed_at"] : @(date.timeIntervalSince1970);
    if (!startedAt && [previous[@"turnID"] isEqual:turnID]) startedAt = previous[@"startedAt"];
    if (!startedAt && !running && [payload[@"duration_ms"] isKindOfClass:NSNumber.class]) startedAt = @(completedAt.doubleValue - [payload[@"duration_ms"] doubleValue] / 1000.0);
    NSMutableDictionary *turn = [@{@"turnID": turnID, @"status": running ? @"inProgress" : ([type isEqual:@"task_complete"] ? @"completed" : @"interrupted"),
        @"eventAt": @(date.timeIntervalSince1970)} mutableCopy];
    if (startedAt || running) turn[@"startedAt"] = startedAt ?: @(date.timeIntervalSince1970);
    if (!running) turn[@"completedAt"] = completedAt;
    return turn;
}

- (nullable NSData *)readDescriptor:(int)descriptor offset:(off_t)offset length:(NSUInteger)length {
    NSMutableData *data = [NSMutableData dataWithLength:length];
    NSUInteger count = 0;
    while (count < length) {
        ssize_t result = pread(descriptor, (uint8_t *)data.mutableBytes + count, length - count, offset + count);
        if (result < 0 && errno == EINTR) continue;
        if (result <= 0) return nil;
        count += (NSUInteger)result;
    }
    return data;
}

- (BOOL)loadLatestTurnFromDescriptor:(int)descriptor cursor:(CQRolloutCursor *)cursor {
    off_t position = cursor.size;
    NSMutableData *suffix = [NSMutableData data];
    BOOL foundEnd = NO;
    BOOL skipOversizedLine = NO;
    cursor.offset = 0;
    while (position > 0) {
        NSUInteger length = (NSUInteger)MIN((off_t)CQRolloutReadChunkBytes, position);
        position -= length;
        NSData *chunk = [self readDescriptor:descriptor offset:position length:length];
        if (!chunk) return NO;
        NSMutableData *data = [chunk mutableCopy];
        [data appendData:suffix];
        const uint8_t *bytes = data.bytes;
        NSUInteger end = data.length;
        for (NSUInteger index = length; index > 0; index--) {
            if (bytes[index - 1] != '\n') continue;
            if (!foundEnd) {
                // Leave an incomplete final line unread until the writer appends its newline.
                cursor.offset = position + index;
                foundEnd = YES;
            } else if (!skipOversizedLine && end - index <= CQRolloutMaximumLineBytes) {
                NSDictionary *turn = [self turnFromLine:[data subdataWithRange:NSMakeRange(index, end - index)] previousTurn:nil];
                if (turn) { cursor.turn = turn; return YES; }
            }
            skipOversizedLine = NO;
            end = index - 1;
        }
        if (end > CQRolloutMaximumLineBytes) skipOversizedLine = YES;
        suffix = skipOversizedLine ? [NSMutableData data] : [[data subdataWithRange:NSMakeRange(0, end)] mutableCopy];
    }
    if (foundEnd && !skipOversizedLine) cursor.turn = [self turnFromLine:suffix previousTurn:nil];
    return YES;
}

- (BOOL)readAppendedTurnsFromDescriptor:(int)descriptor cursor:(CQRolloutCursor *)cursor {
    off_t position = cursor.offset;
    NSMutableData *line = [NSMutableData data];
    BOOL skipOversizedLine = NO;
    while (position < cursor.size) {
        NSUInteger length = (NSUInteger)MIN((off_t)CQRolloutReadChunkBytes, cursor.size - position);
        NSData *chunk = [self readDescriptor:descriptor offset:position length:length];
        if (!chunk) return NO;
        const uint8_t *bytes = chunk.bytes;
        NSUInteger start = 0;
        for (NSUInteger index = 0; index < length; index++) {
            if (bytes[index] != '\n') continue;
            if (line.length + index - start > CQRolloutMaximumLineBytes) skipOversizedLine = YES;
            if (!skipOversizedLine) {
                [line appendBytes:bytes + start length:index - start];
                NSDictionary *turn = [self turnFromLine:line previousTurn:cursor.turn];
                if (turn) cursor.turn = turn;
            }
            [line setLength:0];
            skipOversizedLine = NO;
            start = index + 1;
            cursor.offset = position + start;
        }
        if (line.length + length - start > CQRolloutMaximumLineBytes) skipOversizedLine = YES;
        if (!skipOversizedLine) [line appendBytes:bytes + start length:length - start];
        else [line setLength:0];
        position += length;
    }
    return YES;
}

- (nullable NSDictionary *)latestTurnForThread:(NSString *)threadID rolloutPath:(NSString *)path {
    if (path.length == 0) return nil;
    struct stat attributes;
    if (stat(path.fileSystemRepresentation, &attributes) != 0 || !S_ISREG(attributes.st_mode)) {
        [self.cursors removeObjectForKey:threadID];
        return nil;
    }
    NSDate *modifiedAt = [NSDate dateWithTimeIntervalSince1970:attributes.st_mtimespec.tv_sec + attributes.st_mtimespec.tv_nsec / 1e9];
    CQRolloutCursor *cursor = self.cursors[threadID];
    BOOL sameFile = cursor && [cursor.path isEqual:path] && cursor.inode == attributes.st_ino;
    if (sameFile && cursor.size == attributes.st_size && [cursor.modifiedAt isEqualToDate:modifiedAt]) return cursor.turn;
    BOOL appended = sameFile && attributes.st_size > cursor.size;
    if (!appended) {
        cursor = [CQRolloutCursor new];
        cursor.path = path;
        cursor.inode = attributes.st_ino;
    }
    cursor.size = attributes.st_size;
    cursor.modifiedAt = modifiedAt;
    int descriptor = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (descriptor < 0) { [self.cursors removeObjectForKey:threadID]; return nil; }
    BOOL success = appended ? [self readAppendedTurnsFromDescriptor:descriptor cursor:cursor] : [self loadLatestTurnFromDescriptor:descriptor cursor:cursor];
    close(descriptor);
    if (!success) { [self.cursors removeObjectForKey:threadID]; return nil; }
    self.cursors[threadID] = cursor;
    return cursor.turn;
}

@end
