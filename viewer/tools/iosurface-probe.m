// Render-confirm for presenter A: does CALayer.contents = IOSurface actually
// render on OS X 10.9? Fills a magenta IOSurface, hands it to a layer-backed view,
// then reads back the window's composited center pixel via CGWindowListCreateImage
// (self-verifying, so it works even from a headless launch as long as the SCREEN
// IS AWAKE). Prints MAGENTA (works -> build presenter A) or NOT magenta (-> B).
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurface.h>

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        int W = 300, H = 200;
        NSDictionary *props = @{ (id)kIOSurfaceWidth:@(W), (id)kIOSurfaceHeight:@(H),
            (id)kIOSurfaceBytesPerElement:@4, (id)kIOSurfacePixelFormat:@((uint32_t)'BGRA') };
        IOSurfaceRef surf = IOSurfaceCreate((CFDictionaryRef)props);
        if (!surf) { NSLog(@"RESULT: IOSurfaceCreate failed"); return 2; }
        IOSurfaceLock(surf, 0, NULL);
        uint8_t *base = IOSurfaceGetBaseAddress(surf);
        size_t stride = IOSurfaceGetBytesPerRow(surf);
        for (int y=0;y<H;y++){ uint8_t *r=base+y*stride;
            for (int x=0;x<W;x++){ r[x*4+0]=255; r[x*4+1]=0; r[x*4+2]=255; r[x*4+3]=255; } }
        IOSurfaceUnlock(surf, 0, NULL);

        NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(200,200,W,H)
            styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:NO];
        NSView *v = [win contentView];
        [v setWantsLayer:YES];
        [v layer].contents = (id)surf;
        [v layer].contentsGravity = kCAGravityResize;
        [win makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.5]];

        CGImageRef img = CGWindowListCreateImage(CGRectNull,
            kCGWindowListOptionIncludingWindow, (CGWindowID)[win windowNumber],
            kCGWindowImageBoundsIgnoreFraming);
        if (!img) { NSLog(@"RESULT: capture failed (is the screen awake?)"); return 3; }
        size_t iw=CGImageGetWidth(img), ih=CGImageGetHeight(img);
        uint8_t px[4]={0};
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(px,1,1,8,4,cs,
            kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
        CGContextDrawImage(ctx, CGRectMake(-(CGFloat)iw/2+0.5,-(CGFloat)ih/2+0.5, iw, ih), img);
        BOOL magenta = (px[0]>200 && px[1]<60 && px[2]>200);
        NSLog(@"RESULT: center RGBA=%d,%d,%d,%d -> %@", px[0],px[1],px[2],px[3],
              magenta ? @"MAGENTA (layer.contents=IOSurface RENDERS on 10.9 -> build presenter A)"
                      : @"NOT magenta (-> build presenter B, the GL fallback)");
        CGContextRelease(ctx); CGColorSpaceRelease(cs); CGImageRelease(img);
    }
    return 0;
}
