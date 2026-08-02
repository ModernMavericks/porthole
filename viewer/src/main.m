#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>   // RegisterEventHotKey (global Quick Access hotkey)
#import "remote_display.h"
#import "PortholeWindow.h"
#import "PortholeAudioPlayer.h"
#import "PortholeMenuController.h"
#import "PortholeStaticMenuProducer.h"
#import "PortholeRemoteMenuProducer.h"
#import "PortholeMenuModel.h"
#import "PortholeMenuGlyph.h"

// The native (Cocoa) shell. It drives a remote-display session through the
// remote_display C interface and renders/handles input via NSWindow/NSEvent/
// NSPasteboard. It knows nothing about Xpra beyond asking for that backend.
@interface PortholeAppDelegate : NSObject <NSApplicationDelegate, PortholeMenuStaticInvoker>
- (void)newWindowWid:(long)wid frame:(NSRect)frame overrideRedirect:(BOOL)overrideRedirect title:(NSString *)title;
- (void)drawWid:(long)wid rect:(NSRect)rect encoding:(NSString *)enc
         pixels:(const void *)pixels length:(size_t)len rowstride:(int)rowstride;
- (void)lostWid:(long)wid;
- (void)clipboardSetText:(NSData *)utf8;
- (void)clipboardWantsText;
- (void)openURL:(NSString *)urlString;
- (void)notifySummary:(NSString *)summary body:(NSString *)body;
- (void)openFileNamed:(NSString *)filename mimetype:(NSString *)mimetype data:(NSData *)data;
- (void)printFileNamed:(NSString *)filename mimetype:(NSString *)mimetype data:(NSData *)data;
- (void)setCursorWidth:(int)w height:(int)h xhot:(int)xhot yhot:(int)yhot bgra:(NSData *)bgra;
- (void)resetCursor;
- (void)newTrayWid:(long)wid w:(int)w h:(int)h;
- (NSImage *)imageFromCoding:(NSString *)coding pixels:(NSData *)pixels w:(int)w h:(int)h stride:(int)stride;
- (void)quickAccessHotKey;
- (void)lockHotKey;
- (void)sessionDisconnected;
@end

@implementation PortholeAppDelegate {
    rds_session *_session;
    NSMutableDictionary *_windows;
    NSMutableDictionary *_trays;   // wid -> NSStatusItem (forwarded system-tray icons)
    NSImage *_opGlyph;             // cached 1Password menu-bar glyph (mark-in-ring), unlocked
    NSImage *_opGlyphLocked;       // ... and locked (+ padlock badge)
    BOOL _locked;                  // last-seen 1Password lock state (from _lockStateFile)
    NSString *_lockStateFile;      // op writes "locked"/"unlocked" here; we poll it
    NSTimer *_lockTimer;           // polls _lockStateFile
    BOOL _trayPopupPending;        // Quick Access summoned -> center the next OR popup
    NSInteger _mainWid;        // first normal window; popups position relative to it
    NSInteger _pbChangeCount;  // last-seen local pasteboard changeCount (loop guard)
    NSTimer *_pbTimer;         // polls the local clipboard for user copies
    EventHotKeyRef _hotKeyRef;     // global Quick Access hotkey (Cmd-Shift-Space)
    EventHotKeyRef _lockHotKeyRef; // global Lock hotkey (Cmd-Shift-L)
    PortholeAudioPlayer *_audio;     // plays the app's forwarded audio out the speakers
    PortholeMenuController *_menuController;
    id<PortholeMenuProducer> _staticMenu;   // retained
    id<PortholeMenuProducer> _remoteMenu;   // retained
    NSString *_lostMarker;         // written just before we exit on a lost backend
}

// ---- session event callbacks (backend -> shell), bridged from C ----
static void cb_new_window(void *ctx, long wid, int x, int y, int w, int h, int overrideRedirect, const char *title) {
    NSString *t = title ? [NSString stringWithUTF8String:title] : nil;
    [(PortholeAppDelegate *)ctx newWindowWid:wid frame:NSMakeRect(x, y, w, h)
                     overrideRedirect:overrideRedirect ? YES : NO title:t];
}
static void cb_draw(void *ctx, long wid, int x, int y, int w, int h,
                    const char *encoding, const void *pixels, size_t len, int rowstride) {
    [(PortholeAppDelegate *)ctx drawWid:wid rect:NSMakeRect(x, y, w, h)
                         encoding:[NSString stringWithUTF8String:encoding]
                           pixels:pixels length:len rowstride:rowstride];
}
static void cb_lost_window(void *ctx, long wid) { [(PortholeAppDelegate *)ctx lostWid:wid]; }
static void cb_clipboard_set_text(void *ctx, const char *utf8, size_t len) {
    [(PortholeAppDelegate *)ctx clipboardSetText:[NSData dataWithBytes:utf8 length:len]];
}
static void cb_clipboard_wants_text(void *ctx) { [(PortholeAppDelegate *)ctx clipboardWantsText]; }
static void cb_open_url(void *ctx, const char *url) {
    if (url) [(PortholeAppDelegate *)ctx openURL:[NSString stringWithUTF8String:url]];
}
static void cb_notify(void *ctx, const char *summary, const char *body) {
    [(PortholeAppDelegate *)ctx notifySummary:(summary ? [NSString stringWithUTF8String:summary] : @"")
                                  body:(body ? [NSString stringWithUTF8String:body] : @"")];
}
static void cb_open_file(void *ctx, const char *filename, const char *mimetype,
                         const void *data, size_t len) {
    [(PortholeAppDelegate *)ctx openFileNamed:(filename ? [NSString stringWithUTF8String:filename] : @"download")
                              mimetype:(mimetype ? [NSString stringWithUTF8String:mimetype] : @"")
                                  data:[NSData dataWithBytes:data length:len]];
}
static void cb_print_file(void *ctx, const char *filename, const char *mimetype,
                          const void *data, size_t len) {
    [(PortholeAppDelegate *)ctx printFileNamed:(filename ? [NSString stringWithUTF8String:filename] : @"document")
                               mimetype:(mimetype ? [NSString stringWithUTF8String:mimetype] : @"")
                                   data:[NSData dataWithBytes:data length:len]];
}
static void cb_set_cursor(void *ctx, int w, int h, int xhot, int yhot, const void *bgra, size_t len) {
    [(PortholeAppDelegate *)ctx setCursorWidth:w height:h xhot:xhot yhot:yhot
                                    bgra:[NSData dataWithBytes:bgra length:len]];
}
static void cb_reset_cursor(void *ctx) { [(PortholeAppDelegate *)ctx resetCursor]; }
static void cb_new_tray(void *ctx, long wid, int w, int h) { [(PortholeAppDelegate *)ctx newTrayWid:wid w:w h:h]; }
static void cb_audio_out(void *ctx, const char *codec, const void *data, size_t len) {
    (void)codec;   // we only advertise mp3
    [(PortholeAppDelegate *)ctx audioOut:(len ? [NSData dataWithBytes:data length:len] : nil)];
}
static void cb_disconnected(void *ctx) { [(PortholeAppDelegate *)ctx sessionDisconnected]; }

// Carbon global-hotkey handler: forwards Cmd-Shift-Space to the delegate.
static OSStatus porthole_hotkey_handler(EventHandlerCallRef next, EventRef event, void *userData) {
    (void)next;
    EventHotKeyID hkID = {0, 0};
    GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof(hkID), NULL, &hkID);
    PortholeAppDelegate *d = (PortholeAppDelegate *)userData;
    if (hkID.id == 1)      [d quickAccessHotKey];   // Cmd-Shift-Space
    else if (hkID.id == 2) [d lockHotKey];          // Cmd-Shift-L
    return noErr;
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    _windows = [[NSMutableDictionary alloc] init];
    _trays = [[NSMutableDictionary alloc] init];
    [NSApp setMainMenu:[self buildMainMenu]];   // real App/Edit/Window menus
    [self setUpMenuBridge];
    // Server address: an AF_UNIX socket PATH (the local end of the launcher's bridge
    // to the container's xpra Unix socket). Precedence: a command-line path arg (how
    // `op gui` launches us: `open --args <path>`) > PORTHOLE_SOCKET env > a temp default.
    // argv[0] is our own binary path -> skip it; macOS -psn_/-NS* args start with '-'.
    NSString *socketPath = nil;
    NSDictionary *env = [[NSProcessInfo processInfo] environment];
    if ([env[@"PORTHOLE_SOCKET"] length]) socketPath = env[@"PORTHOLE_SOCKET"];
    NSArray *args = [[NSProcessInfo processInfo] arguments];
    for (NSUInteger i = 1; i < args.count; i++) {
        NSString *a = args[i];
        if ([a hasPrefix:@"/"]) socketPath = a;   // an absolute socket path
    }
    if (!socketPath.length)
        socketPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"porthole-xpra.sock"];

    // Auto-recovery marker: the launcher's watcher relaunches us iff this file exists
    // when we exit (a lost backend), vs a deliberate Quit (no marker). Derive it from the
    // socket path both sides share; clear any stale one so a past crash can't relaunch us.
    if ([socketPath hasSuffix:@"-xpra.sock"])
        _lostMarker = [[[socketPath substringToIndex:socketPath.length - 10]
                        stringByAppendingString:@"-viewer-lost"] retain];
    else
        _lostMarker = [[socketPath stringByAppendingString:@".viewer-lost"] retain];
    [[NSFileManager defaultManager] removeItemAtPath:_lostMarker error:NULL];

    // Lock-state channel: the launcher (op) writes "locked"/"unlocked" here; we poll it
    // to switch the 1Password menu-bar glyph. Derived from the shared socket path.
    if ([socketPath hasSuffix:@"-xpra.sock"])
        _lockStateFile = [[[socketPath substringToIndex:socketPath.length - 10]
                           stringByAppendingString:@"-lockstate"] retain];

    rds_callbacks cb = {0};
    cb.ctx = self;
    cb.new_window = cb_new_window;
    cb.draw = cb_draw;
    cb.lost_window = cb_lost_window;
    cb.clipboard_set_text = cb_clipboard_set_text;
    cb.clipboard_wants_text = cb_clipboard_wants_text;
    cb.open_url = cb_open_url;
    cb.notify = cb_notify;
    cb.open_file = cb_open_file;
    cb.print_file = cb_print_file;
    cb.set_cursor = cb_set_cursor;
    cb.reset_cursor = cb_reset_cursor;
    cb.new_tray = cb_new_tray;
    cb.audio_out = cb_audio_out;
    cb.disconnected = cb_disconnected;
    _audio = [[PortholeAudioPlayer alloc] init];
    _session = rds_xpra_create([socketPath UTF8String], &cb);
    rds_start(_session);

    // The shell owns the local clipboard; poll it so a user copy on this machine
    // propagates to the remote (rds_clipboard_changed).
    _pbChangeCount = [[NSPasteboard generalPasteboard] changeCount];
    _pbTimer = [NSTimer timerWithTimeInterval:0.5 target:self selector:@selector(pollPasteboard) userInfo:nil repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:_pbTimer forMode:NSRunLoopCommonModes];

    // Global hotkeys, the combos modern 1Password users expect: Cmd-Shift-Space ->
    // Quick Access, Cmd-Shift-L -> Lock. Carbon's RegisterEventHotKey works app-wide
    // (no Accessibility permission needed), which is what a menu-bar app wants. These
    // are 1Password-specific -- other viewers (Signal) register none.
    if ([self isOnePassword]) {
        EventTypeSpec hkType = { kEventClassKeyboard, kEventHotKeyPressed };
        InstallApplicationEventHandler(&porthole_hotkey_handler, 1, &hkType, self, NULL);
        EventHotKeyID qaID = { 'OPQA', 1 };
        RegisterEventHotKey(kVK_Space, cmdKey | shiftKey, qaID,
                            GetApplicationEventTarget(), 0, &_hotKeyRef);
        EventHotKeyID lkID = { 'OPLK', 2 };
        RegisterEventHotKey(kVK_ANSI_L, cmdKey | shiftKey, lkID,
                            GetApplicationEventTarget(), 0, &_lockHotKeyRef);
        // Poll the lock-state file so the menu-bar glyph gains/loses its padlock badge.
        _lockTimer = [NSTimer timerWithTimeInterval:1.5 target:self
                              selector:@selector(pollLockState) userInfo:nil repeats:YES];
        [[NSRunLoop currentRunLoop] addTimer:_lockTimer forMode:NSRunLoopCommonModes];
    }

    // Menu-bar-resident Dock behavior: keep a Dock icon only while a real (titled) window
    // is visible. After Cmd-Q the window closes but the tray keeps us alive -- drop the
    // Dock icon then (become an accessory), and restore it when a window reopens (from the
    // menu-bar extra now, or /Applications later). Driven off window show/close
    // notifications so every path is covered.
    for (NSString *note in @[NSWindowDidBecomeKeyNotification, NSWindowWillCloseNotification])
        [[NSNotificationCenter defaultCenter] addObserver:self
            selector:@selector(scheduleDockSync:) name:note object:nil];

    // Bare-binary launches (not via LaunchServices) don't auto-activate, so a
    // freshly created window can sit behind the terminal until activation changes.
    [NSApp activateIgnoringOtherApps:YES];
}

// Cmd-Shift-Space: summon Quick Access directly (native 1Password's hotkey opens
// the panel, not the menu). No tray yet -> nothing to summon.
- (void)quickAccessHotKey { [self summonQuickAccess]; }
// Cmd-Shift-L: lock (the native macOS 1Password lock shortcut).
- (void)lockHotKey { [self focusMainThenShortcut:@"l" keyval:'l' shift:YES]; }

- (void)newWindowWid:(long)wid frame:(NSRect)frame overrideRedirect:(BOOL)overrideRedirect title:(NSString *)title {
    // Every window after the main one is positioned at its server (root) position
    // relative to the main window's on-screen content origin. The main window has
    // no parent -> NaN sentinel -> default slot.
    NSPoint parentTopLeft = NSMakePoint(NAN, NAN);
    if (_mainWid)
        parentTopLeft = [_windows[@(_mainWid)] contentTopLeftScreen];
    PortholeWindow *w = [[PortholeWindow alloc] initWithSession:_session wid:wid frame:frame
                        overrideRedirect:overrideRedirect parentTopLeft:parentTopLeft title:title];
    _windows[@(wid)] = w;
    if (!overrideRedirect && !_mainWid) _mainWid = wid;   // first normal window
    // A tray was just clicked/hotkeyed -> this OR window is 1Password's Quick
    // Access panel; show it centered (where modern 1Password puts it) rather than
    // at its remote position relative to the main window.
    if (_trayPopupPending && overrideRedirect) {
        [w centerOnScreen];
        [w makeKeyPopup];   // Quick Access owns the keyboard itself (no main window needed)
        _trayPopupPending = NO;
    }
    [w release];   // dictionary retains it
    // NSRunningApplication activation is more reliable for a process that started
    // life without a window (we connect first, windows arrive ~130ms later).
    [[NSRunningApplication currentApplication]
        activateWithOptions:NSApplicationActivateAllWindows | NSApplicationActivateIgnoringOtherApps];
}

- (void)drawWid:(long)wid rect:(NSRect)rect encoding:(NSString *)enc
         pixels:(const void *)pixels length:(size_t)len rowstride:(int)rowstride {
    // The pixel buffer is valid for this synchronous call, so wrap it without a copy.
    NSData *d = [NSData dataWithBytesNoCopy:(void *)pixels length:len freeWhenDone:NO];
    // A tray's icon pixels arrive as draws too -> update its menu-bar item; tray
    // draws are always full frames, so the whole rect is the icon. Rendered as a
    // TEMPLATE (monochrome, adapts to light/dark) like a modern macOS menu-bar extra
    // -- 1Password's is colorless. Lock state is a shape difference (open vs closed
    // padlock), which the silhouette preserves.
    NSStatusItem *tray = _trays[@(wid)];
    if (tray) {
        NSImage *icon = [self imageFromCoding:enc pixels:d w:(int)rect.size.width
                                            h:(int)rect.size.height stride:rowstride];
        if (icon) {
            // 1Password: show a native mark-in-ring glyph derived from the app's OWN
            // bundled icon -- value-threshold isolates the navy mark from the blue disc
            // (the earlier attempt derived it from the low-res FORWARDED icon and failed).
            // Any other app: the forwarded tray icon, as a plain template.
            NSImage *glyph = [self isOnePassword] ? [self onePasswordTrayGlyph] : nil;
            if (glyph) {
                [tray setImage:glyph];
            } else {
                [icon setSize:NSMakeSize(18, 18)]; [icon setTemplate:YES]; [tray setImage:icon];
            }
        }
        return;
    }
    [_windows[@(wid)] drawRGB:d rect:rect coding:enc rowstride:rowstride];
}

- (void)lostWid:(long)wid {
    if (wid == _mainWid) _mainWid = 0;
    NSStatusItem *tray = _trays[@(wid)];
    if (tray) {
        [[NSStatusBar systemStatusBar] removeStatusItem:tray];
        [_trays removeObjectForKey:@(wid)];
        return;
    }
    [_windows removeObjectForKey:@(wid)];
}

// ---- local clipboard (shell owns NSPasteboard; backend owns the protocol) ----
- (void)pollPasteboard {
    NSInteger cc = [[NSPasteboard generalPasteboard] changeCount];
    if (cc != _pbChangeCount) { _pbChangeCount = cc; rds_clipboard_changed(_session); }
}
- (void)clipboardSetText:(NSData *)utf8 {
    NSString *s = [[[NSString alloc] initWithData:utf8 encoding:NSUTF8StringEncoding] autorelease];
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    if (s) [pb setString:s forType:NSPasteboardTypeString];
    _pbChangeCount = pb.changeCount;   // don't let our own write look like a user copy
}
- (void)clipboardWantsText {
    NSString *s = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    rds_provide_clipboard_text(_session, d.length ? d.bytes : NULL, d.length);
}

// ---- open-url (remote link -> local browser) ----
- (void)openURL:(NSString *)urlString {
    NSURL *url = [NSURL URLWithString:urlString];
    NSString *scheme = [[url scheme] lowercaseString];
    // Only hand safe web/mail schemes to LaunchServices. A remote request must
    // never be able to launch arbitrary URL handlers (file:, custom app schemes).
    if (url && ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"] ||
                [scheme isEqualToString:@"mailto"])) {
        [[NSWorkspace sharedWorkspace] openURL:url];
    } else {
        NSLog(@"open-url: refusing non-web URL: %@", urlString);
    }
}

// ---- notification (remote app notification -> Notification Center) ----
- (void)notifySummary:(NSString *)summary body:(NSString *)body {
    NSUserNotification *n = [[[NSUserNotification alloc] init] autorelease];
    n.title = summary.length ? summary : [[NSProcessInfo processInfo] processName];
    n.informativeText = body;
    [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:n];
}

// ---- open-file (remote download/attachment -> local open) ----
- (void)openFileNamed:(NSString *)filename mimetype:(NSString *)mimetype data:(NSData *)data {
    (void)mimetype;
    // lastPathComponent strips any directory parts -> no path traversal from a
    // remote-supplied name. Refuse obviously-executable types so a remote request
    // can't drop and launch code (the file:-analogue of open_url's scheme vetting).
    NSString *base = [filename lastPathComponent];
    if (!base.length) base = @"download";
    static NSSet *blocked;
    if (!blocked) blocked = [[NSSet alloc] initWithObjects:
        @"app", @"command", @"sh", @"bash", @"zsh", @"scpt", @"scptd", @"applescript",
        @"terminal", @"tool", @"action", @"workflow", @"pkg", @"mpkg", @"dmg", @"jar", nil];
    NSString *ext = [[base pathExtension] lowercaseString];
    if ([blocked containsObject:ext]) {
        NSLog(@"open-file: refusing executable type .%@ (%@)", ext, base);
        return;
    }
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"Porthole-files"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *path = [dir stringByAppendingPathComponent:base];
    if ([data writeToFile:path atomically:YES]) {
        [[NSWorkspace sharedWorkspace] openFile:path];
    } else {
        NSLog(@"open-file: failed to write %@", path);
    }
}

// ---- print-file (remote print job -> local print system) ----
- (void)printFileNamed:(NSString *)filename mimetype:(NSString *)mimetype data:(NSData *)data {
    (void)mimetype;
    NSString *base = [filename lastPathComponent];
    if (!base.length) base = @"document";
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"Porthole-print"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *path = [dir stringByAppendingPathComponent:base];
    if (![data writeToFile:path atomically:YES]) { NSLog(@"print-file: failed to write %@", path); return; }
    // Hand the document (PDF/PostScript) to CUPS via `lp` -- the user already chose
    // Print in the app. "--" guards against a name that looks like an option.
    @try {
        [NSTask launchedTaskWithLaunchPath:@"/usr/bin/lp" arguments:@[@"--", path]];
    } @catch (NSException *e) {
        NSLog(@"print-file: lp failed: %@", e);
    }
}

// ---- cursor (remote pointer shape -> NSCursor) ----
- (void)setCursorWidth:(int)w height:(int)h xhot:(int)xhot yhot:(int)yhot bgra:(NSData *)bgra {
    if (w <= 0 || h <= 0 || (NSUInteger)(w * h * 4) > bgra.length) return;
    NSBitmapImageRep *rep = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:w pixelsHigh:h bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:w * 4 bitsPerPixel:32] autorelease];
    const uint8_t *s = bgra.bytes; uint8_t *d = [rep bitmapData];
    for (int i = 0; i < w * h; i++) {   // premultiplied BGRA -> RGBA
        d[i*4+0] = s[i*4+2]; d[i*4+1] = s[i*4+1]; d[i*4+2] = s[i*4+0]; d[i*4+3] = s[i*4+3];
    }
    NSImage *img = [[[NSImage alloc] initWithSize:NSMakeSize(w, h)] autorelease];
    [img addRepresentation:rep];
    NSCursor *c = [[[NSCursor alloc] initWithImage:img hotSpot:NSMakePoint(xhot, yhot)] autorelease];
    for (PortholeWindow *win in [_windows allValues]) [win setAppCursor:c];
}
- (void)resetCursor {
    for (PortholeWindow *win in [_windows allValues]) [win setAppCursor:nil];
}

// ---- system tray (remote app tray icon -> Mac menu-bar item) ----
- (void)newTrayWid:(long)wid w:(int)w h:(int)h {
    (void)w; (void)h;
    NSStatusItem *item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
    [item setHighlightMode:YES];
    [item setMenu:[self buildTrayMenu]];   // native click -> menu, like macOS 1Password
    _trays[@(wid)] = item;
}
// The display name of the app this viewer was stamped for (CFBundleName ==
// PORTHOLE_APP_NAME). The minimal per-app switch keys off it; the generator will later
// replace this with real per-app config.
- (NSString *)appDisplayName {
    NSString *n = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];
    return n.length ? n : @"1Password";
}
// The app IDENTITY slug (e.g. "1password"): the last component of the bundle id
// (dev.modernmavericks.porthole.<slug>). Per-app behavior + the menu socket key off THIS,
// so a display name like "Linux 1Password" doesn't change identity or routing.
- (NSString *)appSlug {
    NSString *last = [[[[NSBundle mainBundle] bundleIdentifier]
                       componentsSeparatedByString:@"."] lastObject];
    return last.length ? last : @"1password";
}
- (BOOL)isOnePassword { return [[self appSlug] isEqualToString:@"1password"]; }

// The 1Password menu-bar glyph (mark-in-ring), derived from the app's own bundled icon
// for the current lock state and cached per state. nil if the icon has no isolable mark
// (e.g. built with a generic icon) -- the caller falls back to the forwarded tray icon.
- (NSImage *)onePasswordTrayGlyph {
    NSImage *cached = _locked ? _opGlyphLocked : _opGlyph;
    if (!cached) {
        cached = [PortholeOnePasswordMenuGlyph([NSApp applicationIconImage], _locked) retain];
        if (_locked) _opGlyphLocked = cached; else _opGlyph = cached;
    }
    return cached;
}

// Poll the lock-state file op maintains; on a change, re-glyph every live tray item.
- (void)pollLockState {
    if (!_lockStateFile) return;
    NSString *s = [NSString stringWithContentsOfFile:_lockStateFile
                                            encoding:NSUTF8StringEncoding error:NULL];
    BOOL locked = [[s stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]] isEqualToString:@"locked"];
    if (locked == _locked) return;
    _locked = locked;
    NSImage *glyph = [self onePasswordTrayGlyph];
    if (glyph) for (NSStatusItem *tray in [_trays allValues]) [tray setImage:glyph];
}

// The menu the menu-bar item pops. For 1Password it mirrors native (Open / Quick
// Access / Lock / Settings / Quit); other apps get a generic Open <name> / Quit.
- (NSMenu *)buildTrayMenu {
    NSMenu *m = [[[NSMenu alloc] initWithTitle:[self appDisplayName]] autorelease];
    // Lay the shortcut out ourselves (attributed title + right tab stop) so the key
    // equivalents right-align in a column, like modern macOS. Use the menu's OWN font.
    NSFont *mfont = [m font] ?: [NSFont menuFontOfSize:0];
    NSDictionary *fa = @{NSFontAttributeName: mfont};
    CGFloat tabLoc = [@"Open Quick Access" sizeWithAttributes:fa].width + 24
                   + [@"⇧⌘Space" sizeWithAttributes:fa].width;
    [m setMinimumWidth:tabLoc + 24];
    [self addItemTo:m title:[@"Open " stringByAppendingString:[self appDisplayName]]
           shortcut:nil action:@selector(menuOpenMain:) tabLoc:tabLoc];
    if ([self isOnePassword]) {
        // 1Password-only: Quick Access + Lock ride the global hotkeys (shown for
        // display); Settings has no shortcut.
        [self addItemTo:m title:@"Open Quick Access" shortcut:@"⇧⌘Space" action:@selector(menuQuickAccess:) tabLoc:tabLoc];
        [m addItem:[NSMenuItem separatorItem]];
        [self addItemTo:m title:@"Lock"     shortcut:@"⇧⌘L" action:@selector(menuLock:)     tabLoc:tabLoc];
        [self addItemTo:m title:@"Settings" shortcut:nil     action:@selector(menuSettings:) tabLoc:tabLoc];
    } else {
        [m addItem:[NSMenuItem separatorItem]];
    }
    [self addItemTo:m title:@"Quit" shortcut:nil action:@selector(menuQuit:) tabLoc:tabLoc];
    return m;
}
// Add a menu item. EVERY item gets an attributed title with the same menu font, so
// rows render uniformly (mixing attributed and plain titles looked uneven). When
// `shortcut` is given we append "<tab>shortcut" with a RIGHT tab stop at tabLoc so
// shortcuts right-align in a column (see buildTrayMenu).
- (void)addItemTo:(NSMenu *)m title:(NSString *)title shortcut:(NSString *)sc
           action:(SEL)action tabLoc:(CGFloat)tabLoc {
    NSMenuItem *it = [m addItemWithTitle:title action:action keyEquivalent:@""];
    [it setTarget:self];
    NSMutableParagraphStyle *ps = [[[NSMutableParagraphStyle alloc] init] autorelease];
    if (sc.length)
        [ps setTabStops:@[[[[NSTextTab alloc] initWithType:NSRightTabStopType location:tabLoc] autorelease]]];
    NSString *str = sc.length ? [title stringByAppendingFormat:@"\t%@", sc] : title;
    NSAttributedString *as = [[[NSAttributedString alloc] initWithString:str
        attributes:@{NSFontAttributeName: ([m font] ?: [NSFont menuFontOfSize:0]),
                     NSParagraphStyleAttributeName: ps}] autorelease];
    [it setAttributedTitle:as];
}

// ---- native main menu bar (App / Edit / Window), engine-wide default -------------
// Porthole had only NSApplication's bare default menu. This gives every viewer real
// menus: standard App items, and an Edit/Window set whose ⌘-shortcuts are the native
// source of truth -- AppKit's performKeyEquivalent fires these BEFORE the window's
// keyDown, so they cleanly subsume the in-view opTranslate (no double-send). Edit
// items forward the app's Ctrl-based shortcut to whichever viewer window has focus.
// (Per-app menu manifests + auto-derivation come later.)
- (PortholeWindow *)keyOPWindow {
    for (PortholeWindow *w in [_windows allValues]) if ([w isKeyWindow]) return w;
    return _mainWid ? _windows[@(_mainWid)] : nil;
}
- (void)forwardShortcut:(NSString *)keyname keyval:(uint32_t)keyval shift:(BOOL)shift {
    [[self keyOPWindow] sendControlShortcut:keyname keyval:keyval shift:shift];
}
- (void)menuCut:(id)s       { (void)s; [self forwardShortcut:@"x" keyval:'x' shift:NO];  }
- (void)menuCopy:(id)s      { (void)s; [self forwardShortcut:@"c" keyval:'c' shift:NO];  }
- (void)menuPaste:(id)s     { (void)s; [self forwardShortcut:@"v" keyval:'v' shift:NO];  }
- (void)menuSelectAll:(id)s { (void)s; [self forwardShortcut:@"a" keyval:'a' shift:NO];  }
- (void)menuUndo:(id)s      { (void)s; [self forwardShortcut:@"z" keyval:'z' shift:NO];  }
- (void)menuRedo:(id)s      { (void)s; [self forwardShortcut:@"z" keyval:'z' shift:YES]; }
// ⌘Q keeps our "close to the menu bar" behavior (matches the in-view ⌘Q): with a tray
// we stay resident; tray-less viewers terminate on last-window-close as before. Full
// quit for a tray viewer is the tray menu's Quit.
- (void)menuCloseToMenuBar:(id)s { (void)s; [[NSApp keyWindow] performClose:nil]; }
- (NSMenuItem *)item:(NSMenu *)m title:(NSString *)t action:(SEL)a key:(NSString *)k target:(id)tg {
    NSMenuItem *it = [m addItemWithTitle:t action:a keyEquivalent:k];
    [it setTarget:tg];
    return it;
}
// Perform a menu.json action string: a native pseudo-action (@about/.../@quit) or a
// forwarded key combo sent to the focused window. (Extracted from menuManifestAction:
// so PortholeStaticMenuProducer can invoke by nodeId.)
- (void)invokeSendString:(NSString *)send {
    if (![send isKindOfClass:[NSString class]] || !send.length) return;
    if ([send hasPrefix:@"@"]) {
        if ([send isEqualToString:@"@about"])    [NSApp orderFrontStandardAboutPanel:nil];
        else if ([send isEqualToString:@"@hide"])     [NSApp hide:nil];
        else if ([send isEqualToString:@"@minimize"]) [[NSApp keyWindow] performMiniaturize:nil];
        else if ([send isEqualToString:@"@zoom"])     [[NSApp keyWindow] performZoom:nil];
        else if ([send isEqualToString:@"@close"])    [[NSApp keyWindow] performClose:nil];
        else if ([send isEqualToString:@"@quit"])     [NSApp terminate:nil];
        return;
    }
    NSArray *parts = [send componentsSeparatedByString:@"+"];
    NSMutableArray *mods = [NSMutableArray array];
    for (NSUInteger i = 0; i + 1 < parts.count; i++) {
        NSString *m = [parts[i] lowercaseString];
        if ([m isEqualToString:@"ctrl"] || [m isEqualToString:@"control"]) [mods addObject:@"control"];
        else if ([m isEqualToString:@"shift"]) [mods addObject:@"shift"];
        else if ([m isEqualToString:@"alt"] || [m isEqualToString:@"mod1"] || [m isEqualToString:@"option"]) [mods addObject:@"mod1"];
    }
    NSString *key = [parts lastObject];
    uint32_t keyval = 0;
    if ([key isEqualToString:@"comma"])       keyval = ',';
    else if ([key isEqualToString:@"period"]) keyval = '.';
    else if ([key isEqualToString:@"space"])  keyval = ' ';
    else if (key.length == 1)                 keyval = [key characterAtIndex:0];
    [[self keyOPWindow] sendCombo:mods keyname:key keyval:keyval];
}
- (NSMenu *)buildMainMenu {
    NSString *app = [self appDisplayName];
    NSMenu *main = [[[NSMenu alloc] initWithTitle:@""] autorelease];

    // App menu (AppKit names it from CFBundleName; first submenu is the app menu).
    NSMenuItem *appHolder = [main addItemWithTitle:@"" action:NULL keyEquivalent:@""];
    NSMenu *appMenu = [[[NSMenu alloc] initWithTitle:app] autorelease];
    [self item:appMenu title:[@"About " stringByAppendingString:app]
         action:@selector(orderFrontStandardAboutPanel:) key:@"" target:nil];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [self item:appMenu title:[@"Hide " stringByAppendingString:app] action:@selector(hide:) key:@"h" target:nil];
    NSMenuItem *hideOthers = [self item:appMenu title:@"Hide Others"
        action:@selector(hideOtherApplications:) key:@"h" target:nil];
    [hideOthers setKeyEquivalentModifierMask:NSCommandKeyMask | NSAlternateKeyMask];
    [self item:appMenu title:@"Show All" action:@selector(unhideAllApplications:) key:@"" target:nil];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [self item:appMenu title:[@"Quit " stringByAppendingString:app]
         action:@selector(menuCloseToMenuBar:) key:@"q" target:self];
    [appHolder setSubmenu:appMenu];

    // Edit menu -- ⌘-shortcuts forwarded to the focused viewer window.
    NSMenuItem *editHolder = [main addItemWithTitle:@"Edit" action:NULL keyEquivalent:@""];
    NSMenu *edit = [[[NSMenu alloc] initWithTitle:@"Edit"] autorelease];
    [self item:edit title:@"Undo" action:@selector(menuUndo:) key:@"z" target:self];
    NSMenuItem *redo = [self item:edit title:@"Redo" action:@selector(menuRedo:) key:@"z" target:self];
    [redo setKeyEquivalentModifierMask:NSCommandKeyMask | NSShiftKeyMask];
    [edit addItem:[NSMenuItem separatorItem]];
    [self item:edit title:@"Cut"   action:@selector(menuCut:)   key:@"x" target:self];
    [self item:edit title:@"Copy"  action:@selector(menuCopy:)  key:@"c" target:self];
    [self item:edit title:@"Paste" action:@selector(menuPaste:) key:@"v" target:self];
    [edit addItem:[NSMenuItem separatorItem]];
    [self item:edit title:@"Select All" action:@selector(menuSelectAll:) key:@"a" target:self];
    [editHolder setSubmenu:edit];

    // Per-app menus from the bundled menu.json (generator-emitted, app-authored) are
    // inserted between Edit and Window by the live menu bridge (setUpMenuBridge), so
    // every viewer keeps the standard menus and gains its own (e.g. CLion's
    // File/View/Navigate/Run, 1Password's Lock/Quick Access).

    // Window menu -- standard NSWindow actions via the responder chain.
    NSMenuItem *winHolder = [main addItemWithTitle:@"Window" action:NULL keyEquivalent:@""];
    NSMenu *win = [[[NSMenu alloc] initWithTitle:@"Window"] autorelease];
    [self item:win title:@"Minimize" action:@selector(performMiniaturize:) key:@"m" target:nil];
    [self item:win title:@"Zoom" action:@selector(performZoom:) key:@"" target:nil];
    [win addItem:[NSMenuItem separatorItem]];
    [self item:win title:@"Close" action:@selector(performClose:) key:@"w" target:nil];
    [winHolder setSubmenu:win];
    [NSApp setWindowsMenu:win];

    return main;
}
// Wire the live menu bridge: static producer (bundled menu.json) as the baseline,
// remote producer (the container's menu daemon over a Unix socket) as the upgrade.
- (void)setUpMenuBridge {
    NSMenu *main = [NSApp mainMenu];
    NSMenuItem *winHolder = nil;
    for (NSMenuItem *it in [main itemArray]) if ([[it title] isEqualToString:@"Window"]) winHolder = it;
    if (!winHolder) return;
    _menuController = [[PortholeMenuController alloc] initWithMainMenu:main windowHolder:winHolder];

    NSString *jsonPath = [[NSBundle mainBundle] pathForResource:@"menu" ofType:@"json"];
    _staticMenu = [[PortholeStaticMenuProducer alloc] initWithJSONPath:jsonPath invoker:self];

    NSString *sock = [NSString stringWithFormat:@"%@/%@-menu.sock",
        NSTemporaryDirectory(), [self appSlug]];
    _remoteMenu = [[PortholeRemoteMenuProducer alloc] initWithSocketPath:sock];

    [_menuController useStaticProducer:_staticMenu remoteProducer:_remoteMenu];
}
// Summon Quick Access: 1Password's shortcut is Ctrl+Shift+Space, sent to the
// focused main window (verified: a tray left-click merely toggles the main window,
// it does NOT open Quick Access). Flag the next OR window to be centered.
- (void)summonQuickAccess {
    PortholeWindow *mainWin = _mainWid ? _windows[@(_mainWid)] : nil;
    if (!mainWin) return;
    // Do NOT activate the whole app -- that foregrounds the (backgrounded) main
    // window too. Only the Quick Access panel should come forward: it does so itself
    // when it maps (makeKeyPopup -> orderFrontRegardless + becomes key).
    _trayPopupPending = YES;
    // Focus 1Password server-side WITHOUT showing our main window (rds_window_focus,
    // not showFront), so summoning Quick Access doesn't raise or reopen the main window.
    rds_window_focus_gained(_session, _mainWid);
    [mainWin sendControlShortcut:@"space" keyval:' ' shift:YES];
}
// Bring the main window forward (focusing 1Password server-side) then drive it with
// a Ctrl(+Shift)+key shortcut -- the reliable way to reach the app, as `op lock`
// does (windowfocus, then the shortcut).
- (void)focusMainThenShortcut:(NSString *)keyname keyval:(uint32_t)keyval shift:(BOOL)shift {
    PortholeWindow *mainWin = _mainWid ? _windows[@(_mainWid)] : nil;
    if (!mainWin) return;
    [NSApp activateIgnoringOtherApps:YES];
    [mainWin showFront];
    [mainWin sendControlShortcut:keyname keyval:keyval shift:shift];
}
// Show the main window. If we still have it (you closed the Porthole window but it's
// alive client-side), just bring it front. If 1Password destroyed it (its own tray
// toggle-hide), we have nothing to show -> forward a tray left-click, which makes
// 1Password re-create/show its window (that toggle is what closed it).
- (void)menuOpenMain:(id)s {
    (void)s;
    [NSApp activateIgnoringOtherApps:YES];
    if (_mainWid && _windows[@(_mainWid)]) { [_windows[@(_mainWid)] showFront]; return; }
    NSNumber *twid = [[_trays allKeys] firstObject];
    if (twid) { long t = [twid longValue]; rds_button(_session, t, 1, 1, 0, 0); rds_button(_session, t, 1, 0, 0, 0); }
}
- (void)menuQuickAccess:(id)s { (void)s; [self summonQuickAccess]; }
- (void)menuLock:(id)s        { (void)s; [self focusMainThenShortcut:@"l"     keyval:'l' shift:YES]; }
- (void)menuSettings:(id)s    { (void)s; [self focusMainThenShortcut:@"comma" keyval:',' shift:NO]; }
- (void)menuQuit:(id)s        { (void)s; [NSApp terminate:nil]; }
// Build an NSImage from a full-frame draw (jpeg/png data, or raw 3/4-byte BGR(X)).
- (NSImage *)imageFromCoding:(NSString *)coding pixels:(NSData *)pixels w:(int)w h:(int)h stride:(int)stride {
    if (w <= 0 || h <= 0 || pixels.length == 0) return nil;
    if ([coding hasPrefix:@"jpeg"] || [coding hasPrefix:@"png"])
        return [[[NSImage alloc] initWithData:pixels] autorelease];
    BOOL is24 = !(stride >= w * 4);       // 4-byte BGRX/BGRA if stride covers it, else 3-byte BGR
    int bpp = is24 ? 3 : 4;
    if ((NSUInteger)(stride * h) > pixels.length) return nil;
    NSBitmapImageRep *rep = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:w pixelsHigh:h bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:w * 4 bitsPerPixel:32] autorelease];
    const uint8_t *s = pixels.bytes; uint8_t *d = [rep bitmapData];
    for (int y = 0; y < h; y++) {
        const uint8_t *sr = s + y * stride; uint8_t *dr = d + y * w * 4;
        for (int x = 0; x < w; x++) {     // BGR(X) -> RGBA
            dr[x*4+0] = sr[x*bpp+2]; dr[x*4+1] = sr[x*bpp+1];
            dr[x*4+2] = sr[x*bpp+0]; dr[x*4+3] = (bpp == 4) ? sr[x*bpp+3] : 255;
        }
    }
    NSImage *img = [[[NSImage alloc] initWithSize:NSMakeSize(w, h)] autorelease];
    [img addRepresentation:rep];
    return img;
}

// Stay alive as a menu-bar-resident app while a forwarded tray icon exists (so
// closing the 1Password window leaves its menu-bar item, like real macOS); with no
// tray, quit when the last window closes as before. (Cmd-Q always quits.)
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)s { return _trays.count == 0; }
// Re-launching (`op gui` / clicking the app) while we sit resident in the menu bar
// with no window open: single-instance means LaunchServices re-activates us rather
// than starting a second process -- so bring the main 1Password window back.
- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)hasVisible {
    (void)app; (void)hasVisible;
    // Reuse the tray's "Open" path rather than a bare `if (_mainWid) showFront`: that
    // did nothing when 1Password had destroyed its own main window (its tray toggle-hide
    // clears _mainWid), so a Dock click / `op gui` / `open` re-activated us with NO window.
    // menuOpenMain re-shows a client-side-closed window when we still have it, and forwards
    // a tray click to make 1Password re-create the window when we don't.
    [self menuOpenMain:nil];
    return YES;
}
// A visible titled window = a real app window (main/dialog); borderless popups and the
// status-bar item don't count.
- (BOOL)hasVisibleAppWindow {
    for (NSWindow *w in [NSApp windows])
        if ([w isVisible] && ([w styleMask] & NSTitledWindowMask)) return YES;
    return NO;
}
// Dock icon while a window is shown; none while we sit menu-bar-only (a tray is keeping us
// alive with no window). Regaining Regular needs a re-activate for the icon to attach.
- (void)syncDockPresence {
    NSApplicationActivationPolicy want =
        ([self hasVisibleAppWindow] || _trays.count == 0)
            ? NSApplicationActivationPolicyRegular
            : NSApplicationActivationPolicyAccessory;
    if ([NSApp activationPolicy] == want) return;
    [NSApp setActivationPolicy:want];
    if (want == NSApplicationActivationPolicyRegular) [NSApp activateIgnoringOtherApps:YES];
}
// Window notifications fire mid-transition (a closing window still reports visible), so
// re-evaluate on the next runloop turn.
- (void)scheduleDockSync:(NSNotification *)n {
    (void)n;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(syncDockPresence) object:nil];
    [self performSelector:@selector(syncDockPresence) withObject:nil afterDelay:0 inModes:@[NSRunLoopCommonModes]];
}
// Forwarded app audio (mp3 chunk, or nil = stream stopped) -> the player.
- (void)audioOut:(NSData *)mp3 { if (mp3) [_audio playChunk:mp3]; else [_audio reset]; }
// The backend lost its connection to the remote (server/container/VM gone, or the
// socket bridge dropped). There's no reconnect, so terminate cleanly rather than
// linger as a menu-bar zombie around a dead session -- a fresh `op gui` reconnects.
- (void)sessionDisconnected {
    NSLog(@"Porthole: session disconnected; terminating");
    // Signal the launcher's watcher that this exit is a lost backend, not a user Quit.
    if (_lostMarker)
        [[NSData data] writeToFile:_lostMarker atomically:YES];
    [NSApp terminate:nil];
}
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [_audio release];
    if (_hotKeyRef) UnregisterEventHotKey(_hotKeyRef);
    if (_lockHotKeyRef) UnregisterEventHotKey(_lockHotKeyRef);
    [_pbTimer invalidate];
    rds_destroy(_session);
    [_windows release];
    [_menuController release];
    [_staticMenu release];
    [_remoteMenu release];
    [_lostMarker release];
    [super dealloc];
}
@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        PortholeAppDelegate *d = [[PortholeAppDelegate alloc] init];
        [app setDelegate:d];
        [app run];
    }
    return 0;
}
