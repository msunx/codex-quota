#import <Cocoa/Cocoa.h>

static NSColor *CQHex(NSUInteger rgb) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xff) / 255.0
                              green:((rgb >> 8) & 0xff) / 255.0
                               blue:(rgb & 0xff) / 255.0
                              alpha:1.0];
}

static void DrawIcon(CGFloat size, NSString *path) {
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
                      pixelsWide:(NSInteger)size
                      pixelsHigh:(NSInteger)size
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSCalibratedRGBColorSpace
                     bytesPerRow:0
                    bitsPerPixel:0];
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = context;
    context.imageInterpolation = NSImageInterpolationHigh;

    CGFloat inset = size * 0.055;
    NSRect tile = NSInsetRect(NSMakeRect(0, 0, size, size), inset, inset);
    NSBezierPath *background = [NSBezierPath bezierPathWithRoundedRect:tile
                                                              xRadius:size * 0.22
                                                              yRadius:size * 0.22];
    [CQHex(0x24273A) setFill];
    [background fill];

    NSPoint center = NSMakePoint(size * 0.5, size * 0.47);
    CGFloat radius = size * 0.29;
    NSBezierPath *track = [NSBezierPath bezierPath];
    [track appendBezierPathWithArcWithCenter:center radius:radius startAngle:205 endAngle:-25 clockwise:YES];
    track.lineWidth = size * 0.07;
    track.lineCapStyle = NSLineCapStyleRound;
    [CQHex(0x363A4F) setStroke];
    [track stroke];

    NSBezierPath *meter = [NSBezierPath bezierPath];
    [meter appendBezierPathWithArcWithCenter:center radius:radius startAngle:205 endAngle:48 clockwise:YES];
    meter.lineWidth = size * 0.07;
    meter.lineCapStyle = NSLineCapStyleRound;
    [CQHex(0xB7BDF8) setStroke];
    [meter stroke];

    CGFloat angle = 35.0 * M_PI / 180.0;
    NSPoint tip = NSMakePoint(center.x + cos(angle) * radius * 0.72,
                              center.y + sin(angle) * radius * 0.72);
    NSBezierPath *needle = [NSBezierPath bezierPath];
    [needle moveToPoint:center];
    [needle lineToPoint:tip];
    needle.lineWidth = size * 0.038;
    needle.lineCapStyle = NSLineCapStyleRound;
    [CQHex(0xED8796) setStroke];
    [needle stroke];

    NSBezierPath *hub = [NSBezierPath bezierPathWithOvalInRect:
        NSMakeRect(center.x - size * 0.048, center.y - size * 0.048, size * 0.096, size * 0.096)];
    [CQHex(0xCAD3F5) setFill];
    [hub fill];

    NSDictionary *attributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:size * 0.13 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: CQHex(0xCAD3F5)
    };
    NSString *mark = @"CQ";
    NSSize textSize = [mark sizeWithAttributes:attributes];
    [mark drawAtPoint:NSMakePoint((size - textSize.width) / 2, size * 0.16)
       withAttributes:attributes];

    [NSGraphicsContext restoreGraphicsState];
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    [png writeToFile:path atomically:YES];
}

static void AppendUInt32(NSMutableData *data, uint32_t value) {
    uint32_t bigEndian = CFSwapInt32HostToBig(value);
    [data appendBytes:&bigEndian length:sizeof(bigEndian)];
}

static void BuildICNS(NSString *directory, NSString *outputPath) {
    NSArray<NSArray<NSString *> *> *entries = @[
        @[@"icp4", @"icon_16x16.png"],
        @[@"ic11", @"icon_16x16@2x.png"],
        @[@"icp5", @"icon_32x32.png"],
        @[@"ic12", @"icon_32x32@2x.png"],
        @[@"ic07", @"icon_128x128.png"],
        @[@"ic13", @"icon_128x128@2x.png"],
        @[@"ic08", @"icon_256x256.png"],
        @[@"ic14", @"icon_256x256@2x.png"],
        @[@"ic09", @"icon_512x512.png"],
        @[@"ic10", @"icon_512x512@2x.png"]
    ];
    NSMutableData *body = [NSMutableData data];
    for (NSArray<NSString *> *entry in entries) {
        NSData *png = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:entry[1]]];
        if (!png) continue;
        NSData *type = [entry[0] dataUsingEncoding:NSASCIIStringEncoding];
        [body appendData:type];
        AppendUInt32(body, (uint32_t)(8 + png.length));
        [body appendData:png];
    }
    NSMutableData *icns = [NSMutableData dataWithData:[@"icns" dataUsingEncoding:NSASCIIStringEncoding]];
    AppendUInt32(icns, (uint32_t)(8 + body.length));
    [icns appendData:body];
    [icns writeToFile:outputPath atomically:YES];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) return 2;
        NSString *directory = [NSString stringWithUTF8String:argv[1]];
        NSString *outputPath = [NSString stringWithUTF8String:argv[2]];
        NSDictionary<NSString *, NSNumber *> *files = @{
            @"icon_16x16.png": @16,
            @"icon_16x16@2x.png": @32,
            @"icon_32x32.png": @32,
            @"icon_32x32@2x.png": @64,
            @"icon_128x128.png": @128,
            @"icon_128x128@2x.png": @256,
            @"icon_256x256.png": @256,
            @"icon_256x256@2x.png": @512,
            @"icon_512x512.png": @512,
            @"icon_512x512@2x.png": @1024
        };
        [files enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSNumber *size, BOOL *stop) {
            (void)stop;
            DrawIcon(size.doubleValue, [directory stringByAppendingPathComponent:name]);
        }];
        BuildICNS(directory, outputPath);
    }
    return 0;
}
