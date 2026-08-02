// Headless protocol probe for the remote-display interface: drives a session on
// a bare NSRunLoop (no NSApplication / no window server), logging handshake +
// events, so the network/protocol path can be exercised and debugged without a
// GUI session. It talks only to the remote_display C API -- a small proof that
// the seam is usable without the Cocoa shell.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>   // NSBitmapImageRep for the frame dump
#import "remote_display.h"

static void on_new_window(void *ctx, long wid, int x, int y, int w, int h, int overrideRedirect, const char *title) {
    (void)ctx;
    NSLog(@"[probe] NEW-WINDOW wid=%ld  %dx%d @ %d,%d%s title=%s", wid, w, h, x, y, overrideRedirect ? " (OR)" : "", title ? title : "");
}
static void on_draw(void *ctx, long wid, int x, int y, int w, int h,
                    const char *encoding, const void *pixels, size_t len, int rowstride) {
    (void)ctx;
    NSLog(@"[probe] DRAW wid=%ld  %dx%d @ %d,%d  coding=%s bytes=%lu stride=%d",
          wid, w, h, x, y, encoding, (unsigned long)len, rowstride);
    static BOOL saved = NO;
    if (!saved && strncmp(encoding, "rgb", 3) == 0 && len >= (size_t)(w*h*4)) {
        saved = YES;
        unsigned char *plane[1] = { (unsigned char *)pixels };
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:plane pixelsWide:w pixelsHigh:h
            bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
            colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:rowstride bitsPerPixel:32];
        [[rep representationUsingType:NSPNGFileType properties:@{}] writeToFile:@"/tmp/porthole-frame-asis.png" atomically:YES];
        NSLog(@"[probe] wrote /tmp/porthole-frame-asis.png");
    }
}
static void on_lost_window(void *ctx, long wid) { (void)ctx; NSLog(@"[probe] LOST-WINDOW wid=%ld", wid); }
static void on_open_url(void *ctx, const char *url) { (void)ctx; NSLog(@"[probe] OPEN-URL %s", url ? url : "(null)"); }
static void on_notify(void *ctx, const char *summary, const char *body) {
    (void)ctx; NSLog(@"[probe] NOTIFY summary=%s body=%s", summary ?: "", body ?: "");
}
static void on_open_file(void *ctx, const char *filename, const char *mimetype, const void *data, size_t len) {
    (void)ctx; (void)data;
    NSLog(@"[probe] OPEN-FILE name=%s mime=%s bytes=%lu", filename ?: "", mimetype ?: "", (unsigned long)len);
}
static void on_print_file(void *ctx, const char *filename, const char *mimetype, const void *data, size_t len) {
    (void)ctx; (void)data;
    NSLog(@"[probe] PRINT-FILE name=%s mime=%s bytes=%lu", filename ?: "", mimetype ?: "", (unsigned long)len);
}
static void on_set_cursor(void *ctx, int w, int h, int xhot, int yhot, const void *bgra, size_t len) {
    (void)ctx; (void)bgra;
    NSLog(@"[probe] SET-CURSOR %dx%d hot=(%d,%d) bytes=%lu", w, h, xhot, yhot, (unsigned long)len);
}
static void on_reset_cursor(void *ctx) { (void)ctx; NSLog(@"[probe] RESET-CURSOR"); }
static void on_new_tray(void *ctx, long wid, int w, int h) {
    (void)ctx; NSLog(@"[probe] NEW-TRAY wid=%ld %dx%d", wid, w, h);
}

int main(void) {
    @autoreleasepool {
        NSString *sock = [[NSProcessInfo processInfo] environment][@"PORTHOLE_SOCKET"];
        if (!sock.length) sock = [NSTemporaryDirectory() stringByAppendingPathComponent:@"porthole-xpra.sock"];
        double secs = 8.0;
        NSString *se = [[NSProcessInfo processInfo] environment][@"PORTHOLE_SECS"];
        if (se) secs = [se doubleValue];
        NSLog(@"[probe] connecting %@ (run %.0fs)", sock, secs);
        rds_callbacks cb = {0};
        cb.new_window = on_new_window;
        cb.draw = on_draw;
        cb.lost_window = on_lost_window;
        cb.open_url = on_open_url;
        cb.notify = on_notify;
        cb.open_file = on_open_file;
        cb.print_file = on_print_file;
        cb.set_cursor = on_set_cursor;
        cb.reset_cursor = on_reset_cursor;
        cb.new_tray = on_new_tray;
        rds_session *s = rds_xpra_create([sock UTF8String], &cb);
        rds_start(s);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:secs]];
        NSLog(@"[probe] done");
        rds_destroy(s);
    }
    return 0;
}
