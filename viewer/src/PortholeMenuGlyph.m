#import "PortholeMenuGlyph.h"

// Extract 1Password's dark mark from its app icon as a cropped black-on-transparent
// rep. Discriminator is VALUE (max channel): the navy mark's brightest channel is
// ~0.18, while the blue disc's blue channel is ~0.85 -- luminance fails here because
// blue is inherently low-luminance. An opacity gate drops the icon's glossy rim/shadow
// (semi-transparent) so it can't blow up the bounding box. Returns nil if no mark.
static NSBitmapImageRep *extractMark(NSImage *appIcon) {
    const int N = 512;
    NSBitmapImageRep *src = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:N pixelsHigh:N bitsPerSample:8
        samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    NSGraphicsContext *g = [NSGraphicsContext graphicsContextWithBitmapImageRep:src];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:g];
    [[NSColor clearColor] set];
    NSRectFill(NSMakeRect(0, 0, N, N));
    [appIcon drawInRect:NSMakeRect(0, 0, N, N) fromRect:NSZeroRect
              operation:NSCompositeSourceOver fraction:1.0];
    [NSGraphicsContext restoreGraphicsState];

    const double lo = 0.22, hi = 0.38;   // ramp on VALUE
    unsigned char *A = malloc(N * N);
    int minx = N, miny = N, maxx = -1, maxy = -1;
    for (int y = 0; y < N; y++) {
        for (int x = 0; x < N; x++) {
            NSColor *c = [[src colorAtX:x y:y]
                colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
            double r = c.redComponent, gr = c.greenComponent, b = c.blueComponent,
                   a = c.alphaComponent;
            double val = MAX(r, MAX(gr, b));
            double al = (a > 0.85)
                ? (val <= lo ? 1.0 : val >= hi ? 0.0 : (hi - val) / (hi - lo))
                : 0.0;
            unsigned char av = (unsigned char)(al * 255.0 + 0.5);
            A[y * N + x] = av;
            if (av > 128) {
                if (x < minx) minx = x; if (x > maxx) maxx = x;
                if (y < miny) miny = y; if (y > maxy) maxy = y;
            }
        }
    }
    if (maxx < 0) { free(A); return nil; }
    int pad = (int)((maxx - minx) * 0.06);
    minx = MAX(0, minx - pad); miny = MAX(0, miny - pad);
    maxx = MIN(N - 1, maxx + pad); maxy = MIN(N - 1, maxy + pad);
    int cw = maxx - minx + 1, ch = maxy - miny + 1;

    NSBitmapImageRep *mark = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:cw pixelsHigh:ch bitsPerSample:8
        samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:cw * 4 bitsPerPixel:32];
    unsigned char *d = mark.bitmapData;
    for (int y = 0; y < ch; y++) {
        for (int x = 0; x < cw; x++) {
            unsigned char av = A[(miny + y) * N + (minx + x)];
            unsigned char *p = d + (y * cw + x) * 4;
            p[0] = 0; p[1] = 0; p[2] = 0; p[3] = av;   // black; alpha = mark mask
        }
    }
    free(A);
    return mark;
}

NSImage *PortholeOnePasswordMenuGlyph(NSImage *appIcon, BOOL locked) {
    if (!appIcon) return nil;
    NSBitmapImageRep *mark = extractMark(appIcon);
    if (!mark) return nil;

    // Compose ring + mark into a 2x template bitmap. 2x (not 4x) keeps strokes crisp at
    // menu-bar size -- a 4x rep downscaled to 18px softens the ink and reads low-contrast.
    // Black on transparent -- macOS tints the template.
    const double S = 36.0;   // 18pt @ 2x
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:(int)S pixelsHigh:(int)S bitsPerSample:8
        samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    NSGraphicsContext *g = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:g];
    [g setShouldAntialias:YES];
    [[NSColor clearColor] set];
    NSRectFill(NSMakeRect(0, 0, S, S));
    [[NSColor blackColor] set];
    // Ring -- bold enough to match neighbouring menu-bar glyphs' weight.
    double inset = S * 0.075;
    NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:
        NSInsetRect(NSMakeRect(0, 0, S, S), inset, inset)];
    [ring setLineWidth:S * 0.125];
    [ring stroke];
    // Mark: fit to ~58% of S by height (it's a tall glyph), centred.
    NSImage *markImg = [[NSImage alloc] initWithSize:NSMakeSize(mark.pixelsWide, mark.pixelsHigh)];
    [markImg addRepresentation:mark];
    double mw = mark.pixelsWide, mh = mark.pixelsHigh;
    double box = S * 0.58, sc = box / mh;
    NSRect dr = NSMakeRect((S - mw * sc) / 2.0, (S - mh * sc) / 2.0, mw * sc, mh * sc);
    [markImg drawInRect:dr fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1.0];

    if (locked) {
        // Locked: a padlock badge at the lower-right. First ERASE a rounded halo (so the
        // ring/mark don't touch the badge -- a gap, matching the Tahoe locked icon), then
        // draw the padlock in black.
        double bx = S * 0.62, by = S * 0.16, bw = S * 0.34, bh = S * 0.26;
        double cx = bx + bw / 2.0, sr = bw * 0.32, topY = by + bh + sr;   // shackle top
        NSRect halo = NSMakeRect(bx, by, bw, topY - by);
        halo = NSInsetRect(halo, -S * 0.045, -S * 0.045);
        [[NSGraphicsContext currentContext] setCompositingOperation:NSCompositeDestinationOut];
        [[NSColor blackColor] set];
        [[NSBezierPath bezierPathWithRoundedRect:halo xRadius:S * 0.07 yRadius:S * 0.07] fill];
        [[NSGraphicsContext currentContext] setCompositingOperation:NSCompositeSourceOver];
        [[NSColor blackColor] set];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(bx, by, bw, bh)
                                        xRadius:S * 0.045 yRadius:S * 0.045] fill];
        NSBezierPath *shackle = [NSBezierPath bezierPath];
        [shackle setLineWidth:S * 0.05];
        [shackle appendBezierPathWithArcWithCenter:NSMakePoint(cx, by + bh)
                                            radius:sr startAngle:0 endAngle:180];
        [shackle stroke];
    }
    [NSGraphicsContext restoreGraphicsState];

    NSImage *glyph = [[NSImage alloc] initWithSize:NSMakeSize(18, 18)];
    [glyph addRepresentation:rep];
    [glyph setTemplate:YES];
    return glyph;
}
