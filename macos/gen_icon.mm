// gen_icon.mm - draws a simple 1024x1024 app icon (red rounded square with a
// gold star, evoking the Vietnamese flag) and saves it as a PNG. Used only
// at build time by build.sh to produce AppIcon.icns; not part of the app.
#import <Cocoa/Cocoa.h>

static NSBezierPath *StarPath(NSPoint center, CGFloat outerR, CGFloat innerR, int points) {
    NSBezierPath *path = [NSBezierPath bezierPath];
    CGFloat angle = -M_PI_2; // start pointing straight up
    CGFloat step = M_PI / points;
    for (int i = 0; i < points * 2; i++) {
        CGFloat r = (i % 2 == 0) ? outerR : innerR;
        NSPoint p = NSMakePoint(center.x + r * cos(angle), center.y + r * sin(angle));
        if (i == 0) [path moveToPoint:p]; else [path lineToPoint:p];
        angle += step;
    }
    [path closePath];
    return path;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *outPath = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"AppIcon.png";
        CGFloat size = 1024;

        NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(size, size)];
        [img lockFocus];

        NSRect full = NSMakeRect(0, 0, size, size);
        NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:full xRadius:size * 0.22 yRadius:size * 0.22];
        [[NSColor colorWithCalibratedRed:0.855 green:0.145 blue:0.114 alpha:1.0] setFill]; // VN flag red
        [bg fill];

        NSPoint center = NSMakePoint(size / 2, size / 2 + size * 0.02);
        NSBezierPath *star = StarPath(center, size * 0.32, size * 0.32 * 0.382, 5);
        [[NSColor colorWithCalibratedRed:1.0 green:0.816 blue:0.0 alpha:1.0] setFill]; // gold
        [star fill];

        [img unlockFocus];

        NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:[img TIFFRepresentation]];
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        [png writeToFile:outPath atomically:YES];
    }
    return 0;
}
