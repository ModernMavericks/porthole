#import "PortholeWindow.h"
#import "PortholeBlit.h"
#import "PortholeLayerPresenter.h"
#import "PortholeBgSample.h"
#import <IOSurface/IOSurface.h>

// Map a Mac charactersIgnoringModifiers unichar to an X keysym name.
static NSString *PortholeKeyname(unichar c) {
    switch (c) {
        case 0x7f: return @"BackSpace";                 // Mac Delete key deletes backwards
        case NSDeleteFunctionKey: return @"Delete";     // forward-delete
        case 0x0d: return @"Return";
        case 0x03: return @"Return";                    // Enter
        case 0x09: return @"Tab";
        case 0x1b: return @"Escape";
        case ' ':  return @"space";
        case NSLeftArrowFunctionKey:  return @"Left";
        case NSRightArrowFunctionKey: return @"Right";
        case NSUpArrowFunctionKey:    return @"Up";
        case NSDownArrowFunctionKey:  return @"Down";
        case NSHomeFunctionKey:       return @"Home";
        case NSEndFunctionKey:        return @"End";
        case NSPageUpFunctionKey:     return @"Prior";
        case NSPageDownFunctionKey:   return @"Next";
    }
    if (c >= NSF1FunctionKey && c <= NSF12FunctionKey)
        return [NSString stringWithFormat:@"F%d", (int)(c - NSF1FunctionKey + 1)];
    // Printable punctuation -> proper X keysym names (letters/digits map to themselves)
    switch (c) {
        case ',': return @"comma";       case '.': return @"period";
        case '/': return @"slash";       case ';': return @"semicolon";
        case '\'': return @"apostrophe"; case '`': return @"grave";
        case '-': return @"minus";       case '=': return @"equal";
        case '[': return @"bracketleft"; case ']': return @"bracketright";
        case '\\': return @"backslash";
        // Shifted symbols need their X keysym NAME (the literal char is not a valid
        // keysym name, so the keymap-less server would drop it).
        case '!': return @"exclam";      case '@': return @"at";
        case '#': return @"numbersign";  case '$': return @"dollar";
        case '%': return @"percent";     case '^': return @"asciicircum";
        case '&': return @"ampersand";   case '*': return @"asterisk";
        case '(': return @"parenleft";   case ')': return @"parenright";
        case '_': return @"underscore";  case '+': return @"plus";
        case '{': return @"braceleft";   case '}': return @"braceright";
        case '|': return @"bar";         case ':': return @"colon";
        case '"': return @"quotedbl";    case '<': return @"less";
        case '>': return @"greater";     case '?': return @"question";
        case '~': return @"asciitilde";
    }
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))
        return [NSString stringWithFormat:@"%C", c];
    // Other printable ASCII: let the server fall back to keyval/string
    if (c >= 0x20 && c < 0x7f) return [NSString stringWithFormat:@"%C", c];
    return nil;
}

// Borderless popup window for override-redirect surfaces (menus, popovers).
// It must NEVER become key: if it stole focus from the parent, Electron would
// see a focus-out on the parent toplevel and instantly dismiss the popup.
// Popups are non-key by default (menus/comboboxes must not steal focus from their
// parent). Quick Access is the exception -- it's a search panel that needs the
// keyboard -- so it opts in via `keyable`.
@interface PortholePopupWindow : NSWindow
@property (nonatomic) BOOL keyable;
@end
@implementation PortholePopupWindow
- (BOOL)canBecomeKeyWindow { return _keyable; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface PortholeView : NSView
@property (nonatomic) NSInteger wid;
// The remote-display session outlives every view (process lifetime in D0), so a
// plain non-owning pointer is correct.
@property (nonatomic) rds_session *session;
// `retain` IS @synthesize-able under MRR; balanced by -dealloc below.
@property (nonatomic, retain) NSBitmapImageRep *bitmap;
- (void)sendControlShortcut:(NSString *)keyname keyval:(uint32_t)keyval shift:(BOOL)shift;
- (void)sendCombo:(NSArray *)mods keyname:(NSString *)keyname keyval:(uint32_t)keyval;
// IOSurface pixel path (see PortholeSurfacePresenter). Falls back to the legacy
// NSBitmapImageRep path (-compositeRep:/-drawRect:) if IOSurface is unavailable.
- (void)ensureSurfaceOpaque:(BOOL)opaque;
- (BOOL)isLegacy;
- (void)writePatchRep:(NSData *)rgb x:(NSInteger)x y:(NSInteger)y
                width:(NSInteger)w height:(NSInteger)h stride:(NSInteger)stride bpp:(int)bpp;
- (void)writeImageRep:(NSBitmapImageRep *)rep atX:(NSInteger)x y:(NSInteger)y;
- (void)resizeSurfaceTo:(NSSize)size;
- (void)compositeRep:(NSBitmapImageRep *)src atX:(NSInteger)x y:(NSInteger)y;
@end

@implementation PortholeView {
    NSCursor *_appCursor;   // the remote app's pointer shape (nil = platform default)
    IOSurfaceRef _surface;             // BGRA backing store (max-size), or NULL
    NSSize _maxSize;                   // allocated surface size
    NSSize _contentSize;   // extent of the last full-window frame drawn
    NSSize _logicalSize;               // current window content size
    id<PortholeSurfacePresenter> _presenter; // GPU compositor (retained)
    BOOL _legacy;                      // YES = use the old NSBitmapImageRep path
}
- (BOOL)isFlipped { return YES; }             // match X's top-left origin
- (BOOL)acceptsFirstResponder { return YES; }
// Show the remote app's cursor over this view. nil -> no cursor rect, so the
// window's default (arrow) shows through.
- (void)setAppCursor:(NSCursor *)cursor {
    if (cursor == _appCursor) return;
    [_appCursor release]; _appCursor = [cursor retain];
    [[self window] invalidateCursorRectsForView:self];   // re-runs -resetCursorRects
}
- (void)resetCursorRects {
    if (_appCursor) [self addCursorRect:[self visibleRect] cursor:_appCursor];
}
// Deliver the click that activates an inactive window straight to content, so
// the first click on a background window isn't swallowed just to raise it.
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (void)drawRect:(NSRect)r {
    (void)r;
    if (!_legacy) return;    // the presenter/layer composites the IOSurface
    if (!self.bitmap) return;
    // Draw the backing at its NATIVE size, top-left aligned (isFlipped=YES) -- do NOT
    // scale it to the view bounds. During a live resize the window changes size
    // instantly, but the app's frame re-rendered at the new size arrives a beat later;
    // scaling the stale frame to fill made contents rubber-band (stretch) then snap
    // when the real frame landed. 1:1 keeps them crisp: a grow reveals fresh area
    // (cleared below), a shrink just clips -- no distortion. The app's reflow (configure
    // is still sent, throttled) fills the rest in.
    CGFloat bw = (CGFloat)[self.bitmap pixelsWide];
    CGFloat bh = (CGFloat)[self.bitmap pixelsHigh];
    NSRect b = [self bounds];
    if (bw < b.size.width || bh < b.size.height) {   // window grew past the frame
        [[NSColor windowBackgroundColor] set];
        NSRectFill(b);
    }
    [self.bitmap drawInRect:NSMakeRect(0, 0, bw, bh) fromRect:NSZeroRect
                  operation:NSCompositeCopy fraction:1.0 respectFlipped:YES hints:nil];
}

// Composite a decoded frame patch into the persistent full-window backing store
// at top-left (x,y). D0 replaced the whole `bitmap` per draw, so a PARTIAL damage
// rect (which 1Password sends constantly during interaction) blanked the rest to
// white -- and a small rect got scaled up to fill the window ("zoomed buttons").
// A real backing buffer that accumulates patches fixes both.
- (void)compositeRep:(NSBitmapImageRep *)src atX:(NSInteger)x y:(NSInteger)y {
    NSInteger vw = (NSInteger)self.bounds.size.width;
    NSInteger vh = (NSInteger)self.bounds.size.height;
    if (vw <= 0 || vh <= 0 || !src) return;
    // (Re)create the backing rep when absent or the view size changed (resize).
    if (!self.bitmap ||
        (NSInteger)[self.bitmap pixelsWide] != vw ||
        (NSInteger)[self.bitmap pixelsHigh] != vh) {
        NSBitmapImageRep *bg = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL pixelsWide:vw pixelsHigh:vh bitsPerSample:8
            samplesPerPixel:4 hasAlpha:YES isPlanar:NO
            colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:vw*4 bitsPerPixel:32];
        // Start fully transparent: regions a window never draws (e.g. the
        // shadow-margin around a Chromium menu, which it leaves undrawn) then read
        // as transparent instead of black on a non-opaque popup window.
        memset([bg bitmapData], 0, (size_t)(vw*4*vh));
        self.bitmap = bg;   // retain property owns it
        [bg release];
    }
    NSInteger sw = (NSInteger)[src pixelsWide], sh = (NSInteger)[src pixelsHigh];
    NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithBitmapImageRep:self.bitmap];
    if (!gc) return;
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:gc];
    // Backing context origin is bottom-left; our (x,y) is top-left, so flip y.
    // Use the 6-arg NSImageRep drawing selector (the 4-arg one is NSImage-only).
    [src drawInRect:NSMakeRect(x, vh - y - sh, sw, sh)
           fromRect:NSZeroRect operation:NSCompositeCopy fraction:1.0
      respectFlipped:NO hints:nil];
    [NSGraphicsContext restoreGraphicsState];
    [self setNeedsDisplay:YES];
}

// ---- IOSurface pixel path -------------------------------------------------
- (BOOL)isLegacy { return _legacy; }

// Lazily allocate the max-size BGRA IOSurface + attach the presenter. Falls back
// to the legacy NSBitmapImageRep path if anything is unavailable (never a black
// window). opaque = normal window; NO for override-redirect popups.
- (void)ensureSurfaceOpaque:(BOOL)opaque {
    if (_legacy || _surface || _presenter) return;
    if (getenv("PORTHOLE_NO_IOSURFACE")) { _legacy = YES; return; }   // force legacy (A/B)
    NSScreen *scr = [[self window] screen] ?: [NSScreen mainScreen];
    NSSize scrSz = scr ? [scr frame].size : NSMakeSize(3440, 1440);
    int mw = (int)scrSz.width, mh = (int)scrSz.height;
    NSDictionary *props = @{ (id)kIOSurfaceWidth:@(mw), (id)kIOSurfaceHeight:@(mh),
        (id)kIOSurfaceBytesPerElement:@4, (id)kIOSurfacePixelFormat:@((uint32_t)'BGRA') };
    _surface = IOSurfaceCreate((CFDictionaryRef)props);
    if (!_surface) { _legacy = YES; return; }
    _maxSize = NSMakeSize(mw, mh);
    // Fill with a neutral bg (opaque light grey / transparent for popups) so a window
    // that grows past the drawn content shows a clean strip -- not black -- while the
    // reflowed frame is in flight.
    IOSurfaceLock(_surface, 0, NULL);
    memset(IOSurfaceGetBaseAddress(_surface), opaque ? 0xED : 0x00,
           IOSurfaceGetBytesPerRow(_surface) * (size_t)mh);
    IOSurfaceUnlock(_surface, 0, NULL);
    PortholeLayerPresenter *p = [[PortholeLayerPresenter alloc] init];
    if (![p attachToView:self surface:_surface opaque:opaque]) {
        [p release]; CFRelease(_surface); _surface = NULL; _legacy = YES; return;
    }
    _presenter = p;   // owns it
    _logicalSize = [self bounds].size;
    [_presenter setLogicalSize:_logicalSize maxSize:_maxSize];
}

// New patch-write path: pixels straight into the surface, then present.
- (void)writePatchRep:(NSData *)rgb x:(NSInteger)x y:(NSInteger)y
                width:(NSInteger)w height:(NSInteger)h stride:(NSInteger)stride bpp:(int)bpp {
    if (!_surface) return;
    double t0 = getenv("PORTHOLE_BLITLOG") ? [NSDate timeIntervalSinceReferenceDate] : 0;
    IOSurfaceLock(_surface, 0, NULL);
    double t1 = getenv("PORTHOLE_BLITLOG") ? [NSDate timeIntervalSinceReferenceDate] : 0;
    op_blit_patch((uint8_t *)IOSurfaceGetBaseAddress(_surface),
                  IOSurfaceGetBytesPerRow(_surface), (int)_maxSize.width, (int)_maxSize.height,
                  (int)x, (int)y, (const uint8_t *)rgb.bytes, (size_t)stride, (size_t)rgb.length,
                  (int)w, (int)h, bpp);
    IOSurfaceUnlock(_surface, 0, NULL);
    if (getenv("PORTHOLE_BLITLOG"))
        NSLog(@"[IOBLIT] %ldx%ld lockwait=%.1fms copy=%.1fms", (long)w, (long)h,
              (t1 - t0) * 1000.0, ([NSDate timeIntervalSinceReferenceDate] - t1) * 1000.0);
    [_presenter present];
}

// jpeg/png frames (rare -- we pin --encodings=rgb, so this normally never fires)
// decode to a rep with an unknown pixel layout; draw it into the BGRA surface via a
// CGContext so CoreGraphics does the format conversion. Slow-path; correctness first.
- (void)writeImageRep:(NSBitmapImageRep *)rep atX:(NSInteger)x y:(NSInteger)y {
    if (!_surface || !rep) return;
    CGImageRef cg = [rep CGImage];
    if (!cg) return;
    NSInteger w = (NSInteger)[rep pixelsWide], h = (NSInteger)[rep pixelsHigh];
    IOSurfaceLock(_surface, 0, NULL);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(IOSurfaceGetBaseAddress(_surface),
        (size_t)_maxSize.width, (size_t)_maxSize.height, 8, IOSurfaceGetBytesPerRow(_surface),
        cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);  // BGRA
    if (ctx) {
        // Surface row 0 is top; CG is bottom-up -> place at (x, maxH - y - h).
        CGContextDrawImage(ctx, CGRectMake(x, _maxSize.height - y - h, w, h), cg);
        CGContextRelease(ctx);
    }
    CGColorSpaceRelease(cs);
    IOSurfaceUnlock(_surface, 0, NULL);
    [_presenter present];
}

- (void)resizeSurfaceTo:(NSSize)size {
    _logicalSize = size;
    if (_presenter) [_presenter setLogicalSize:size maxSize:_maxSize];
}

// A full-window frame just landed at `size`: record the content extent (so the
// presenter clamps contentsRect there and the grown strip shows our fill color),
// and sample the app's background from the frame's edges for that fill.
- (void)noteFullFrame:(NSSize)size {
    if (size.width <= 0 || size.height <= 0) return;
    // The bg-strip clamp is off by default: the caller's "full frame" heuristic
    // (top-left, >=200px) misfires on the app's PARTIAL pane repaints, clamping
    // the content extent to a sub-region so content renders smaller than the
    // window. Gate the whole strip feature behind PORTHOLE_BG_STRIP until the
    // full-frame detection is made robust (match a requested configure size).
    if (!getenv("PORTHOLE_BG_STRIP")) return;
    _contentSize = size;
    if (_presenter) [_presenter setContentSize:size];
    if (!_surface) return;
    IOSurfaceLock(_surface, kIOSurfaceLockReadOnly, NULL);
    uint32_t argb = op_sample_bg(IOSurfaceGetBaseAddress(_surface),
                                 IOSurfaceGetBytesPerRow(_surface),
                                 (int)size.width, (int)size.height, 4);
    IOSurfaceUnlock(_surface, kIOSurfaceLockReadOnly, NULL);
    if (getenv("PORTHOLE_BGLOG"))
        NSLog(@"[BG] sampled %dx%d -> argb=0x%08X (r=%d g=%d b=%d)",
              (int)size.width, (int)size.height, argb,
              (argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF);
    if (_presenter) [_presenter setFillColor:argb];
}

- (void)sendPointer:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    rds_pointer_move(self.session, self.wid, (int)p.x, (int)p.y);
}
- (void)mouseMoved:(NSEvent *)e { [self sendPointer:e]; }
- (void)mouseDragged:(NSEvent *)e { [self sendPointer:e]; }
- (void)sendButton:(int)button pressed:(BOOL)pressed event:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    rds_button(self.session, self.wid, button, pressed ? 1 : 0, (int)p.x, (int)p.y);
}
- (void)mouseDown:(NSEvent *)e { [self sendButton:1 pressed:YES event:e]; }
- (void)mouseUp:(NSEvent *)e   { [self sendButton:1 pressed:NO event:e]; }
- (void)rightMouseDown:(NSEvent *)e { [self sendButton:3 pressed:YES event:e]; }
- (void)rightMouseUp:(NSEvent *)e   { [self sendButton:3 pressed:NO event:e]; }
- (void)scrollWheel:(NSEvent *)e {
    // Faithfully forward the OS's scroll; don't fabricate one. The old
    // `deltaY>0?4:5` emitted button 5 (scroll-down) even for a delta of exactly 0
    // -- so a two-finger tap (delivered as a zero-delta scrollWheel) nudged the
    // list. Forward only when the OS actually reports movement.
    CGFloat dy = [e hasPreciseScrollingDeltas] ? [e scrollingDeltaY] : [e deltaY];
    if (dy == 0) return;
    int btn = dy > 0 ? 4 : 5;   // wheel up/down = X buttons 4/5
    [self sendButton:btn pressed:YES event:e];
    [self sendButton:btn pressed:NO event:e];
}
// Build the X modifier-name list from Mac flags. NOTE: Command is deliberately
// excluded -- we never forward Super; ⌘ combos are translated/handled below.
- (NSArray *)modsFromFlags:(NSUInteger)f addControl:(BOOL)ctrl {
    NSMutableArray *m = [NSMutableArray array];
    if (f & NSShiftKeyMask)   [m addObject:@"shift"];
    if (ctrl || (f & NSControlKeyMask)) [m addObject:@"control"];
    if (f & NSAlternateKeyMask) [m addObject:@"mod1"];   // Option == Alt
    return m;
}
// Send a key with an explicit keysym name + modifier list through the session.
// keycode is not carried by the interface: it would be a Mac-local keycode that
// means nothing to a remote keymap, and the backend resolves keys by keysym.
- (void)sendKeyName:(NSString *)keyname keyval:(uint32_t)keyval string:(NSString *)str
          modifiers:(NSArray *)mods pressed:(BOOL)pressed keycode:(uint16_t)keycode {
    (void)keycode;
    if (!keyname) return;
    const char *cmods[8]; size_t n = 0;
    for (NSString *m in mods) { if (n < 8) cmods[n++] = [m UTF8String]; }
    rds_key(self.session, self.wid, [keyname UTF8String], keyval,
            str ? [str UTF8String] : "", cmods, n, pressed ? 1 : 0);
}

- (void)keyDown:(NSEvent *)e { if (![self opTranslate:e pressed:YES]) [self opSendNormal:e pressed:YES]; }
- (void)keyUp:(NSEvent *)e   { if (![self opTranslate:e pressed:NO])  [self opSendNormal:e pressed:NO]; }

// Send a normal (untranslated) key using its real keysym name + mods.
- (void)opSendNormal:(NSEvent *)e pressed:(BOOL)pressed {
    NSString *ign = [e charactersIgnoringModifiers];
    if (ign.length == 0) return;
    unichar c = [ign characterAtIndex:0];
    NSString *keyname = PortholeKeyname(c);
    if (!keyname) return;
    NSString *str = pressed ? [e characters] : @"";
    uint32_t keyval = (c < 0x100) ? (uint32_t)c : 0;   // Latin-1 keysyms == codepoint
    // Send the (possibly shifted) keysym with its modifier list. We advertise a
    // real keymap in the handshake, so the server presses shift itself via
    // make_keymask_match to reach the shifted keysym level -- no Shift_L bracket.
    [self sendKeyName:keyname keyval:keyval string:str
            modifiers:[self modsFromFlags:e.modifierFlags addControl:NO]
              pressed:pressed keycode:(uint16_t)e.keyCode];
}

// Intercept ⌘/⌥ combos. Returns YES if handled (translated or native action).
// Only fires on keyDown for native actions; forwards press+release for translated keys.
- (BOOL)opTranslate:(NSEvent *)e pressed:(BOOL)pressed {
    NSUInteger f = e.modifierFlags;
    BOOL cmd = (f & NSCommandKeyMask) != 0;
    BOOL opt = (f & NSAlternateKeyMask) != 0;
    if (!cmd && !opt) return NO;
    NSString *ign = [e charactersIgnoringModifiers];
    if (ign.length == 0) return NO;
    unichar c = [ign characterAtIndex:0];

    // --- native Mac actions (only act on press) ---
    if (cmd && !opt) {
        // Cmd-Q closes to the menu bar (does NOT quit) -- like modern 1Password, which
        // stays a menu-bar extra after Cmd-Q. Fully quitting is the tray menu's Quit.
        // With a tray present, closing the window leaves us resident (see
        // applicationShouldTerminateAfterLastWindowClosed).
        if (c == 'q') { if (pressed) [[NSApp keyWindow] performClose:nil]; return YES; }
        if (c == 'w') { if (pressed) [[NSApp keyWindow] performClose:nil]; return YES; }
        if (c == 'm') { if (pressed) [[NSApp keyWindow] miniaturize:nil]; return YES; }
        if (c == 'h') { if (pressed) [NSApp hide:nil]; return YES; }
        // ⌘-Delete: delete to start of line. No single Linux key does this, so
        // select to line start (Shift+Home) then delete the selection.
        if (c == 0x7f) {
            if (pressed) {
                [self sendKeyName:@"Shift_L"   keyval:0xffe1 string:@"" modifiers:@[]         pressed:YES keycode:0];
                [self sendKeyName:@"Home"      keyval:0      string:@"" modifiers:@[@"shift"] pressed:YES keycode:0];
                [self sendKeyName:@"Home"      keyval:0      string:@"" modifiers:@[@"shift"] pressed:NO  keycode:0];
                [self sendKeyName:@"Shift_L"   keyval:0xffe1 string:@"" modifiers:@[]         pressed:NO  keycode:0];
                [self sendKeyName:@"BackSpace" keyval:0xff08 string:@"" modifiers:@[]         pressed:YES keycode:0];
                [self sendKeyName:@"BackSpace" keyval:0xff08 string:@"" modifiers:@[]         pressed:NO  keycode:0];
            }
            return YES;
        }
    }

    // --- translated: forward a Ctrl-based key to Linux (Shift preserved) ---
    // returns keyname (+ whether to add Control). nil keyname => not in table.
    NSString *keyname = nil; BOOL addControl = NO;
    if (cmd && !opt) {
        // TODO: clipboard sync (Xpra clipboard packets) for real ⌘-C/⌘-V data movement
        if (c=='c'||c=='x'||c=='a'||c=='z'||c=='v') { keyname=[NSString stringWithFormat:@"%C",c]; addControl=YES; }
        else if (c==',') { keyname=@"comma"; addControl=YES; }          // ⌘-, -> Ctrl-,
        else if (c==NSLeftArrowFunctionKey)  keyname=@"Home";           // ⌘-← -> Home
        else if (c==NSRightArrowFunctionKey) keyname=@"End";            // ⌘-→ -> End
        else if (c==NSUpArrowFunctionKey)   { keyname=@"Home"; addControl=YES; }  // ⌘-↑ -> Ctrl-Home
        else if (c==NSDownArrowFunctionKey) { keyname=@"End";  addControl=YES; }  // ⌘-↓ -> Ctrl-End
    } else if (opt && !cmd) {
        if (c==NSLeftArrowFunctionKey)  { keyname=@"Left";  addControl=YES; }     // ⌥-← -> Ctrl-Left (word)
        else if (c==NSRightArrowFunctionKey) { keyname=@"Right"; addControl=YES; }// ⌥-→ -> Ctrl-Right
        else if (c==NSUpArrowFunctionKey)   { keyname=@"Up";   addControl=YES; }  // ⌥-↑ -> Ctrl-Up (paragraph)
        else if (c==NSDownArrowFunctionKey) { keyname=@"Down"; addControl=YES; }  // ⌥-↓ -> Ctrl-Down
        else if (c==0x7f) { keyname=@"BackSpace"; addControl=YES; }               // ⌥-Delete -> Ctrl-BackSpace
        else return NO;   // other ⌥ combos (⌥-letter accents) pass through untranslated
    }
    if (!keyname) return NO;

    // Preserve Shift; add Control when the row needs it. (Command/Option are the
    // Mac triggers and are NOT sent to the server.)
    NSMutableArray *mods = [NSMutableArray array];
    BOOL wantShift = (f & NSShiftKeyMask) != 0;
    if (wantShift) [mods addObject:@"shift"];
    if (addControl) [mods addObject:@"control"];
    uint32_t keyval = ([keyname length]==1) ? (uint32_t)[keyname characterAtIndex:0] : 0;
    // Bracket the key with real modifier-key presses: the server maps keysyms
    // (Control_L/Shift_L) to keycodes via its default keymap, but its
    // make_keymask_match CANNOT press a modifier from its NAME alone (no client
    // keymap) -- it can only *release* ones already held. So each key-action's
    // mods list can drop held modifiers but not add them. Therefore each bracket
    // key carries the modifiers already held (Control_L carries [shift]) so
    // pressing the 2nd modifier doesn't release the 1st -- which is what broke
    // double-modifier combos like Ctrl+Shift+Left (select word).
    NSArray *ctrlMods = wantShift ? @[@"shift"] : @[];
    if (pressed) {
        if (wantShift)  [self sendKeyName:@"Shift_L"   keyval:0xffe1 string:@"" modifiers:@[]       pressed:YES keycode:0];
        if (addControl) [self sendKeyName:@"Control_L" keyval:0xffe3 string:@"" modifiers:ctrlMods  pressed:YES keycode:0];
        [self sendKeyName:keyname keyval:keyval string:@"" modifiers:mods pressed:YES keycode:0];
    } else {
        [self sendKeyName:keyname keyval:keyval string:@"" modifiers:mods pressed:NO keycode:0];
        if (addControl) [self sendKeyName:@"Control_L" keyval:0xffe3 string:@"" modifiers:ctrlMods  pressed:NO keycode:0];
        if (wantShift)  [self sendKeyName:@"Shift_L"   keyval:0xffe1 string:@"" modifiers:@[]       pressed:NO keycode:0];
    }
    return YES;
}

// Menu-driven Ctrl(+Shift)+key shortcut, bracketed with real modifier-key presses
// the same way opTranslate does: the keymap-less server can *drop* a held modifier
// from a key-action's mods list but cannot *press* one from its name alone, so we
// send Shift_L / Control_L explicitly (each carrying the modifiers already held).
- (void)sendControlShortcut:(NSString *)keyname keyval:(uint32_t)keyval shift:(BOOL)shift {
    NSArray *ctrlMods = shift ? @[@"shift"] : @[];
    NSMutableArray *mods = [NSMutableArray array];
    if (shift) [mods addObject:@"shift"];
    [mods addObject:@"control"];
    if (shift) [self sendKeyName:@"Shift_L"   keyval:0xffe1 string:@"" modifiers:@[]       pressed:YES keycode:0];
    [self sendKeyName:@"Control_L" keyval:0xffe3 string:@"" modifiers:ctrlMods pressed:YES keycode:0];
    [self sendKeyName:keyname keyval:keyval string:@"" modifiers:mods pressed:YES keycode:0];
    [self sendKeyName:keyname keyval:keyval string:@"" modifiers:mods pressed:NO  keycode:0];
    [self sendKeyName:@"Control_L" keyval:0xffe3 string:@"" modifiers:ctrlMods pressed:NO keycode:0];
    if (shift) [self sendKeyName:@"Shift_L"   keyval:0xffe1 string:@"" modifiers:@[]       pressed:NO  keycode:0];
}
// General combo sender (for menu-manifest items): hold an arbitrary set of X modifiers,
// then press+release the key. Same bracketing rule as sendControlShortcut -- each
// modifier press carries the modifiers already held (the keymap-less server can drop but
// not add held modifiers), so double/triple combos don't release each other.
- (void)sendCombo:(NSArray *)mods keyname:(NSString *)keyname keyval:(uint32_t)keyval {
    NSDictionary *modKeysym = @{ @"control": @[@"Control_L", @0xffe3],
                                 @"shift":   @[@"Shift_L",   @0xffe1],
                                 @"mod1":    @[@"Alt_L",     @0xffe9] };
    NSMutableArray *held = [NSMutableArray array];
    for (NSString *m in mods) {
        NSArray *mk = modKeysym[m]; if (!mk) continue;
        [self sendKeyName:mk[0] keyval:[mk[1] unsignedIntValue] string:@"" modifiers:[[held copy] autorelease] pressed:YES keycode:0];
        [held addObject:m];
    }
    [self sendKeyName:keyname keyval:keyval string:@"" modifiers:held pressed:YES keycode:0];
    [self sendKeyName:keyname keyval:keyval string:@"" modifiers:held pressed:NO  keycode:0];
    for (NSInteger i = (NSInteger)mods.count - 1; i >= 0; i--) {
        NSArray *mk = modKeysym[mods[i]]; if (!mk) continue;
        [held removeObject:mods[i]];
        [self sendKeyName:mk[0] keyval:[mk[1] unsignedIntValue] string:@"" modifiers:[[held copy] autorelease] pressed:NO keycode:0];
    }
}
- (void)dealloc {
    // balance the `retain` bitmap property's backing ivar
    [_bitmap release];
    [_appCursor release];
    [_presenter detach]; [(NSObject *)_presenter release];
    if (_surface) CFRelease(_surface);
    [super dealloc];
}
@end

@interface PortholeWindow () <NSWindowDelegate>
@end

@implementation PortholeWindow {
    NSWindow *_window; PortholeView *_view;
    NSInteger _wid; rds_session *_session;   // session non-owning (outlives windows)
    NSTimeInterval _lastConfigure;
    // Bounded-pipeline live resize: keep up to _pipeDepth configures in flight so the app
    // reflows the next size WHILE xpra encodes/ships the previous -- overlapping the
    // (app-reflow | encode | wire) stages across cores instead of serializing them. Depth 1
    // = the old one-in-flight behavior. Each slot is a requested-but-unanswered size + when.
    NSMutableArray *_inFlight;                // NSValue(NSSize): requested, not-yet-answered
    NSMutableArray *_inFlightAt;              // NSNumber(NSTimeInterval): send times, parallel
    NSSize _inFlightSize;                     // newest requested size (skip re-asking for it)
    NSTimeInterval _configureSentAt;          // kept for RESIZELOG dt
    int _resizeEvents;                       // PORTHOLE_RESIZELOG: Cocoa resize-event count
    BOOL _overrideRedirect;
    BOOL _inLiveResize;   // YES between windowWillStart/DidEndLiveResize
}
- (instancetype)initWithSession:(rds_session *)session wid:(NSInteger)wid frame:(NSRect)frame
               overrideRedirect:(BOOL)overrideRedirect parentTopLeft:(NSPoint)parentTopLeft
                          title:(NSString *)title {
    if ((self = [super init])) {
        _wid = wid; _session = session; _overrideRedirect = overrideRedirect;
        NSSize sz = frame.size;
        // Position every window at its server (root) position relative to the main
        // window's on-screen content origin, so secondary windows and popups land
        // where the app put them instead of stacking. The main window itself has
        // no parent (NaN sentinel) and gets a default screen slot.
        NSRect contentRect;
        if (isnan(parentTopLeft.x)) {
            // Main window: default slot.
            contentRect = NSMakeRect(100, 100, sz.width, sz.height);
        } else if (overrideRedirect) {
            // Popup (menu/combobox): the server offset is small and meaningful --
            // place it at the parent's content origin + that offset.
            CGFloat screenH = [[NSScreen mainScreen] frame].size.height;
            CGFloat tlx = parentTopLeft.x + frame.origin.x;         // top-left origin
            CGFloat tly = parentTopLeft.y + frame.origin.y;
            contentRect = NSMakeRect(tlx, screenH - tly - sz.height, sz.width, sz.height);
        } else {
            // Secondary TOPLEVEL dialog (Settings, the SSH-authorization prompt, etc.):
            // openbox centers it in the container's huge virtual root (e.g. ~3700,1700
            // in an 8192x4096 display), so the root coords are off our Mac screen.
            // Ignore them and center on the Mac screen like a normal Mac dialog --
            // otherwise the window (e.g. the SSH approval prompt) is invisible off-screen.
            NSRect vf = [[NSScreen mainScreen] visibleFrame];
            contentRect = NSMakeRect(NSMidX(vf) - sz.width/2, NSMidY(vf) - sz.height/2,
                                     sz.width, sz.height);
        }
        if (overrideRedirect) {
            // Popup: borderless, never takes key focus, and NON-OPAQUE so the
            // shadow-margin Chromium leaves undrawn around a menu shows through as
            // transparent (not a black block). macOS draws a real shadow.
            _window = [[PortholePopupWindow alloc] initWithContentRect:contentRect
                styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
            [_window setOpaque:NO];
            [_window setBackgroundColor:[NSColor clearColor]];
            [_window setHasShadow:YES];
            [_window setLevel:NSPopUpMenuWindowLevel];
        } else {
            _window = [[NSWindow alloc] initWithContentRect:contentRect
                styleMask:NSTitledWindowMask|NSClosableWindowMask|NSMiniaturizableWindowMask|NSResizableWindowMask
                backing:NSBackingStoreBuffered defer:NO];
            // Advertise native full-screen capability. On a stock Mac this just adds the
            // standard full-screen affordance; on a Mac running the GreenFullscreen haxie
            // it's what makes its repurposed green button actually work -- GFS's
            // toggleFullscreen calls native -[NSWindow toggleFullScreen:], which no-ops
            // unless the window opts in here.
            [_window setCollectionBehavior:
                [_window collectionBehavior] | NSWindowCollectionBehaviorFullScreenPrimary];
        }
        _view = [[PortholeView alloc] initWithFrame:NSMakeRect(0,0,sz.width,sz.height)];
        _view.wid = wid; _view.session = session;
        [_window setContentView:_view];
        [_window setAcceptsMouseMovedEvents:YES];
        [_window setDelegate:self];
        // We own the window's lifetime (released in -dealloc when its wid is lost).
        // NSWindow defaults isReleasedWhenClosed=YES, so a close (red button, ⌘-W,
        // popup dismiss) would auto-release it and -dealloc's [_window release]
        // would then double-free -> EXC_BAD_ACCESS.
        [_window setReleasedWhenClosed:NO];
        // Title toplevel windows. The MAIN window (no parent) gets the stable app
        // name -- its server title changes (lock->unlock) and we don't track title
        // updates yet, so the app name avoids a stale "Lock Screen -- 1Password".
        // Secondary dialogs get their (fixed) server title, e.g. "Settings".
        // Borderless popups ignore the title.
        if (!overrideRedirect) {
            NSString *appName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];
            if (!appName.length) appName = @"1Password";
            BOOL isMain = isnan(parentTopLeft.x);
            [_window setTitle:((!isMain && title.length) ? title : appName)];
            if (isMain) {
                // Remember the main window's on-screen frame across launches, like a
                // normal Mac app. (1Password co-owns the size -- it persists its own --
                // so restoring the saved frame keeps position and size consistent.)
                [_window setFrameAutosaveName:@"PortholeMainWindow"];
                [_window setFrameUsingName:@"PortholeMainWindow"];
            }
        }
        if (overrideRedirect) {
            // Show without stealing key focus from the parent (keeps the popup alive).
            [_window orderFront:nil];
        } else {
            [_window makeKeyAndOrderFront:nil];
            [_window orderFrontRegardless];   // surface even if the app isn't active yet
        }
    }
    return self;
}
// Route key changes to the client's focus coordinator. Xpra keeps a focused
// window and an unfocused parent dismisses its popups -- so establishing focus
// on our normal windows keeps popups alive, and dropping focus (when the last
// window loses key) dismisses them.
- (void)windowDidBecomeKey:(NSNotification *)n { rds_window_focus_gained(_session, _wid); }
- (void)windowDidResignKey:(NSNotification *)n { rds_window_focus_lost(_session, _wid); }
- (NSPoint)contentTopLeftScreen {
    NSRect cf = [_window contentRectForFrameRect:[_window frame]];   // screen, bottom-left
    CGFloat screenH = [[NSScreen mainScreen] frame].size.height;
    return NSMakePoint(cf.origin.x, screenH - (cf.origin.y + cf.size.height));
}
// On resize, tell the server the new geometry so it reflows the real Linux window
// and sends fresh draws at the new size (instead of us just scaling the old frame).
// Freeze reflow during live drag; reflow once on pause (idle pump) and once on end.
- (void)windowWillStartLiveResize:(NSNotification *)n {
    _inLiveResize = YES;
    if (getenv("PORTHOLE_RESIZELOG")) NSLog(@"[RESIZE] live-resize START");
}
- (void)windowDidEndLiveResize:(NSNotification *)n {
    _inLiveResize = NO;
    [NSObject cancelPreviousPerformRequestsWithTarget:self
              selector:@selector(dragIdlePump) object:nil];
    if (getenv("PORTHOLE_RESIZELOG")) NSLog(@"[RESIZE] live-resize END -> configure");
    [self pumpConfigure];   // one reflow at the final size
}
- (void)dragIdlePump {
    if (getenv("PORTHOLE_RESIZELOG")) NSLog(@"[RESIZE] drag idle -> configure");
    [self pumpConfigure];   // motion paused mid-drag: catch up once
}
- (void)windowDidResize:(NSNotification *)n {
    if (getenv("PORTHOLE_RESIZELOG")) {
        _resizeEvents++;
        NSSize s = [[_window contentView] frame].size;
        NSLog(@"[RESIZE] event #%d %dx%d live=%d t=%.0fms", _resizeEvents,
              (int)s.width, (int)s.height, _inLiveResize,
              [NSDate timeIntervalSinceReferenceDate]*1000.0);
    }
    // Client-side anchored display always tracks the window at 60fps (cheap
    // contentsRect update; layer-hosting means AppKit never re-runs drawRect).
    [_view resizeSurfaceTo:[_view bounds].size];
    if (_inLiveResize) {
        // Two live-resize policies (PORTHOLE_RESIZE_MODE):
        //  freeze (default): suppress the round-trip during motion; reflow once
        //    on pause (idle pump) and once on end. Content is steady/crisp but a
        //    placeholder strip persists for the whole drag.
        //  track: self-clock reflows to the app's real rate -- pumpConfigure only
        //    sends when the previous frame landed (see -ackResizeFrame:), so the
        //    strip is transient (fills every ~reflow) at the cost of content
        //    trailing the cursor by ~one reflow. Best paired with PIPE_DEPTH=1.
        static int track = -1;
        if (track < 0) { const char *m = getenv("PORTHOLE_RESIZE_MODE");
            track = (m && strcmp(m, "track") == 0) ? 1 : 0; }
        if (track) { [self pumpConfigure]; return; }
        // FREEZE: re-arm a short idle timer -- only fires when the cursor stops,
        // then we reflow once. Common-mode so it fires in AppKit's resize loop.
        [NSObject cancelPreviousPerformRequestsWithTarget:self
                  selector:@selector(dragIdlePump) object:nil];
        [self performSelector:@selector(dragIdlePump) withObject:nil afterDelay:0.12
                      inModes:@[NSRunLoopCommonModes]];
        return;
    }
    // Non-drag resize (programmatic, zoom, fullscreen): reflow immediately.
    [self pumpConfigure];
}
// Send a configure only when the previous one has been answered (its frame arrived, see
// -ackResizeFrame:) or has been outstanding too long. This caps the send rate at the
// app's actual reflow rate instead of a fixed timer, so configures stop backlogging.
- (void)pumpConfigure {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (!_inFlight) { _inFlight = [[NSMutableArray alloc] init]; _inFlightAt = [[NSMutableArray alloc] init]; }
    // Per-slot timeout: if a slot's frame never comes (the app coalesced/skipped that
    // intermediate size), free the slot after this so the pipeline doesn't stall.
    static double gate = -1;
    if (gate < 0) { const char *g = getenv("PORTHOLE_GATE_MS"); gate = g ? atof(g) / 1000.0 : 0.25; }
    // Pipeline depth: how many configures may be in flight at once. Depth>1 overlaps the
    // app-reflow of a newer size with the encode/wire of an older frame. Default 3.
    static int depth = -1;
    if (depth < 0) { const char *d = getenv("PORTHOLE_PIPE_DEPTH"); depth = d ? atoi(d) : 3; if (depth < 1) depth = 1; }
    // Expire timed-out (oldest-first) in-flight requests.
    while (_inFlight.count && (now - [_inFlightAt[0] doubleValue]) > gate) {
        [_inFlight removeObjectAtIndex:0]; [_inFlightAt removeObjectAtIndex:0];
    }
    NSSize sz = [[_window contentView] frame].size;
    if ((int)sz.width == (int)_inFlightSize.width && (int)sz.height == (int)_inFlightSize.height)
        return;   // current size already requested (it's the newest in flight) -- nothing new
    if ((NSInteger)_inFlight.count >= depth) return;   // pipeline full -- wait for a frame/timeout
    _inFlightSize = sz;
    [_inFlight addObject:[NSValue valueWithSize:sz]];
    [_inFlightAt addObject:@(now)];
    _configureSentAt = now;
    _lastConfigure = now;
    if (getenv("PORTHOLE_RESIZELOG"))
        NSLog(@"[RESIZE] --> configure %dx%d inflight=%lu t=%.0fms", (int)sz.width, (int)sz.height,
              (unsigned long)_inFlight.count, now*1000.0);
    rds_configure_window(_session, _wid, (int)sz.width, (int)sz.height);
}
// A near-full-window frame at a size we requested = that reflow is done. Free that slot
// (oldest match) and pump: a slot is now open, so ask for the newest size if the window
// kept moving. This is what lets the next size reflow while this frame ships.
- (void)ackResizeFrame:(NSSize)drawn {
    for (NSUInteger i = 0; i < _inFlight.count; i++) {
        NSSize req = [_inFlight[i] sizeValue];
        if (drawn.width >= req.width - 2 && drawn.height >= req.height - 2) {
            [_inFlight removeObjectAtIndex:i]; [_inFlightAt removeObjectAtIndex:i];
            [self pumpConfigure];
            return;
        }
    }
}
- (void)windowWillClose:(NSNotification *)n {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(pumpConfigure) object:nil];
}
- (void)drawRGB:(NSData *)rgb rect:(NSRect)rect coding:(NSString *)coding rowstride:(NSInteger)stride {
    NSInteger x = (NSInteger)rect.origin.x, y = (NSInteger)rect.origin.y;
    if (getenv("PORTHOLE_DRAWLOG"))
        NSLog(@"[DRAW] %@ x=%ld y=%ld w=%ld h=%ld stride=%ld len=%lu", coding, (long)x, (long)y,
              (long)rect.size.width, (long)rect.size.height, (long)stride, (unsigned long)rgb.length);
    if (getenv("PORTHOLE_RESIZELOG"))
        NSLog(@"[RESIZE] <-- draw %@ %ldx%ld dt=%.0fms t=%.0fms", coding,
              (long)rect.size.width, (long)rect.size.height,
              ([NSDate timeIntervalSinceReferenceDate]-_lastConfigure)*1000.0,
              [NSDate timeIntervalSinceReferenceDate]*1000.0);
    [self ackResizeFrame:rect.size];   // release the live-resize gate when the frame lands
    if ([coding hasPrefix:@"jpeg"] || [coding isEqualToString:@"png"] ||
        [coding hasPrefix:@"png"]  || [coding hasPrefix:@"webp"]) {
        // Cocoa decodes JPEG/PNG/WebP natively. Route into the IOSurface (or the
        // legacy backing store) -- rare, since we pin --encodings=rgb.
        NSBitmapImageRep *jr = [NSBitmapImageRep imageRepWithData:rgb];   // autoreleased
        if (!jr) return;
        [_view ensureSurfaceOpaque:!_overrideRedirect];
        if ([_view isLegacy]) [_view compositeRep:jr atX:x y:y];
        else                  [_view writeImageRep:jr atX:x y:y];
        return;
    }
    // Raw RGB. The server picks a format from our advertised list per window: big
    // frames come as jpeg (above), but small/simple windows (menus, popovers) come
    // as raw "rgb24" (3 bytes/px) or "rgb32" (4 bytes/px BGRX). Handle both -- a
    // 24-bit frame fed to a hardcoded 32-bit rep makes initWithBitmapDataPlanes
    // return nil ("Inconsistent set of values"), and writing through nil bitmapData
    // segfaults (this is what crashed on the first context menu).
    NSInteger w = rect.size.width, h = rect.size.height;
    // The coding string ("rgb24"/"rgb32"/"rgb") does NOT reliably give bytes-per-
    // pixel: with the RGBX/BGRX formats we advertise, the server sends 4-byte
    // pixels even under an "rgb24" label. Derive bytes-per-pixel from the row
    // stride (stride >= w*4 => 4 bytes) so a wide patch doesn't shear.
    BOOL is24 = !(w > 0 && stride >= w * 4);
    // Fast path: write the patch straight into the view's IOSurface (no swap; the
    // GPU composites). ensureSurface picks opaque (normal window) vs. alpha (popup).
    [_view ensureSurfaceOpaque:!_overrideRedirect];
    if (![_view isLegacy]) {
        [_view writePatchRep:rgb x:x y:y width:w height:h stride:stride bpp:(is24 ? 3 : 4)];
        // A big top-left-anchored frame = a full window (re)paint: record its
        // extent + sample the bg color (main windows only; popups keep alpha).
        if (!_overrideRedirect && x == 0 && y == 0 && w >= 200 && h >= 200)
            [_view noteFullFrame:NSMakeSize(w, h)];
        return;
    }
    // --- legacy NSBitmapImageRep path (safety net) ---
    NSInteger spp = is24 ? 3 : 4, bpp = is24 ? 24 : 32;
    // Allocate a rep that OWNS its pixel buffer (initWithBitmapDataPlanes:NULL);
    // a rep over external bytes isn't deep-copied by -copy and would dangle.
    // bytesPerRow:0 lets Cocoa pick its own (often padded/aligned) destination
    // stride -- which is generally NOT the server's source stride.
    double _bt0 = getenv("PORTHOLE_BLITLOG") ? [NSDate timeIntervalSinceReferenceDate] : 0;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:w pixelsHigh:h bitsPerSample:8 samplesPerPixel:spp
        hasAlpha:(is24 ? NO : YES) isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace
        bytesPerRow:0 bitsPerPixel:bpp];
    if (!rep) return;   // inconsistent values -> nil; never write through NULL bitmapData
    unsigned char *dst = [rep bitmapData];
    const unsigned char *src = (const unsigned char *)rgb.bytes;
    // Copy ROW BY ROW honouring both strides. The server often pads its rowstride,
    // and Cocoa pads the rep's bytesPerRow -- copying contiguously (assuming one
    // stride for both) shears every scanline, producing a chopped, colour-fringed
    // image on small rgb patches (typed characters, icons).
    NSInteger dstStride = (NSInteger)[rep bytesPerRow];
    NSInteger srcStride = stride > 0 ? stride : w * spp;
    NSInteger srcLen = (NSInteger)rgb.length;
    for (NSInteger row = 0; row < h; row++) {
        NSInteger so = row * srcStride, doff = row * dstStride;
        if (so + w * spp > srcLen) break;   // short data: stop, don't read past end
        const unsigned char *s = src + so;
        unsigned char *d = dst + doff;
        if (is24) {
            memcpy(d, s, (size_t)(w * 3));   // rgb24 already R,G,B in order
        } else {
            // 4-byte is B,G,R + a 4th byte. For override-redirect popups we
            // advertise BGRA and want the REAL alpha (so Chromium's shadow margin
            // renders transparent instead of a black block); for normal opaque
            // windows the 4th byte is BGRX padding, so force it opaque.
            for (NSInteger px = 0; px < w; px++) {
                d[px*4+0] = s[px*4+2]; d[px*4+1] = s[px*4+1];
                d[px*4+2] = s[px*4+0]; d[px*4+3] = _overrideRedirect ? s[px*4+3] : 255;
            }
        }
    }
    double _bt1 = getenv("PORTHOLE_BLITLOG") ? [NSDate timeIntervalSinceReferenceDate] : 0;
    [_view compositeRep:rep atX:x y:y];   // composite patch into backing store
    [rep release];                        // balance the alloc
    if (getenv("PORTHOLE_BLITLOG"))
        NSLog(@"[BLIT] %ldx%ld alloc+swap=%.1fms composite=%.1fms", (long)w, (long)h,
              (_bt1 - _bt0) * 1000.0, ([NSDate timeIntervalSinceReferenceDate] - _bt1) * 1000.0);
}
- (void)setAppCursor:(NSCursor *)cursor { [_view setAppCursor:cursor]; }
- (void)centerOnScreen {
    NSScreen *scr = [_window screen] ?: [NSScreen mainScreen];
    NSRect sf = [scr visibleFrame], wf = [_window frame];
    [_window setFrameOrigin:NSMakePoint(NSMinX(sf) + (NSWidth(sf) - NSWidth(wf)) / 2,
                                        NSMinY(sf) + (NSHeight(sf) - NSHeight(wf)) / 2)];
}
- (void)showFront { [_window makeKeyAndOrderFront:nil]; [_window orderFrontRegardless]; }
// Show this popup AS the key window (Quick Access needs the keyboard). Opting a
// popup into key means it captures typing itself, so summoning it doesn't require
// the main window to be shown/focused.
- (void)makeKeyPopup {
    if ([_window isKindOfClass:[PortholePopupWindow class]]) [(PortholePopupWindow *)_window setKeyable:YES];
    [_window makeKeyAndOrderFront:nil];
    [_window orderFrontRegardless];
}
- (void)sendControlShortcut:(NSString *)keyname keyval:(uint32_t)keyval shift:(BOOL)shift {
    [_view sendControlShortcut:keyname keyval:keyval shift:shift];
}
- (void)sendCombo:(NSArray *)mods keyname:(NSString *)keyname keyval:(uint32_t)keyval {
    [_view sendCombo:mods keyname:keyname keyval:keyval];
}
- (BOOL)isKeyWindow { return [_window isKeyWindow]; }
- (void)dealloc {
    // Stop delegate callbacks (windowDidResignKey etc.) from firing on us mid-
    // teardown, and take the window off-screen before releasing it.
    [_window setDelegate:nil];
    [_window orderOut:nil];
    // setContentView: retained _view; our alloc is balanced here.
    [_window release];
    [_view release];
    [_inFlight release];
    [_inFlightAt release];
    [super dealloc];
}
@end
