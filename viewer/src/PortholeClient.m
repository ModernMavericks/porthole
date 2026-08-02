#import "PortholeClient.h"
#import "PortholeProtocol.h"

// Private backend surface. The C operations in remote_display.h are implemented
// at the bottom of this file and forward to these methods.
@interface PortholeClient () {
    PortholeTransport *_t;
    rds_callbacks _cb;          // events -> native shell
    NSInteger _focusedWid;      // remote focus coordination
    NSMutableSet *_orWids;      // currently-open override-redirect (popup) window ids
    uint64_t _clipReqId;        // monotonic clipboard-request id (Linux->Mac)
    id _pendingClipReqId;       // in-flight remote clipboard request (Mac->Linux)
    id _pendingClipSel;
    NSMutableArray *_keyQueue;  // pending key-action packets, paced to the server
    BOOL _keyDraining;          // a drain loop is currently scheduled
    double _keyIntervalMs;      // min gap between consecutive key-actions
    NSDictionary *_keysymToKeycode;  // X keysym name -> X keycode (from our keymap)
    NSString *_uuid;                 // this client's id (the server routes printer jobs by it)
    BOOL _disconnected;              // transport failure already reported to the shell (fire-once)
}
// operations invoked by the remote_display C functions at the bottom of the file
- (void)start;
- (void)pointerMoveWid:(long)wid x:(int)x y:(int)y;
- (void)buttonWid:(long)wid button:(int)b pressed:(int)pressed x:(int)x y:(int)y;
- (void)keyWid:(long)wid keysym:(NSString *)ks keyval:(uint32_t)kv text:(NSString *)txt
     modifiers:(NSArray *)mods pressed:(int)pressed;
- (void)focusGained:(long)wid;
- (void)focusLost:(long)wid;
- (void)configureWid:(long)wid w:(int)w h:(int)h;
- (void)clipboardChanged;
- (void)provideClipboardText:(NSData *)utf8;
@end

@implementation PortholeClient

- (instancetype)initWithSocketPath:(NSString *)path
                         callbacks:(const rds_callbacks *)cb {
    if ((self = [super init])) {
        _t = [[PortholeTransport alloc] initWithSocketPath:path];
        _t.delegate = self;
        _cb = *cb;
        _orWids = [[NSMutableSet alloc] init];
        _keyQueue = [[NSMutableArray alloc] init];
        // The server has no client keymap, so it synthesizes a keycode per keysym
        // and injects press+release on the fly; bursts overrun it and it silently
        // drops keys. Pace key-actions so each is fully applied before the next.
        // Default: NO pacing. Key-actions are sent with their natural timing, which
        // preserves the press/release overlap (rollover) of real typing. Pacing was
        // a band-aid from before we sent a keymap; re-timing keystrokes to a fixed
        // cadence scrambles rollover and drops ~half the keys at natural speed.
        // PORTHOLE_KEY_MS>0 re-enables spacing for experiments.
        const char *iv = getenv("PORTHOLE_KEY_MS");
        _keyIntervalMs = iv ? atof(iv) : 0.0;
        // A per-instance client id (hex). The server requires a uuid before it will
        // enable printer forwarding (it routes print jobs back to us by it).
        _uuid = [[[[NSUUID UUID] UUIDString] stringByReplacingOccurrencesOfString:@"-" withString:@""] copy];
    }
    return self;
}

- (void)dealloc {
    [_t release];
    [_orWids release];
    [_keyQueue release];
    [_keysymToKeycode release];
    [_uuid release];
    [_pendingClipReqId release];
    [_pendingClipSel release];
    [super dealloc];
}

- (void)start { [_t connect]; }

- (void)sendPacket:(NSArray *)packet { [_t sendPayload:[PortholeProtocol encodeValue:packet]]; }

// A US-QWERTY keymap for the handshake. Without one, the server improvises a
// keycode per keysym and cannot reliably hold shift -- so capitals/symbols came
// out wrong and keys dropped under load (and overlapping/rollover keys dropped).
// We send both `keycodes` (keysym->keycode/level, for shift handling) and
// `x11_keycodes` (keycode->keysyms, which flips the server onto its native
// keycode-injection path so real keycodes in key-actions inject directly). We do
// NOT send `query_struct`, so the server preserves its own keymap and just builds
// a translation from ours (the non-X11-client path) rather than a full remap.
// `keycodes` entry: (keyval, keyname, keycode, group, level); keyval is ignored
// here so we send 0. level 0 = unshifted, level 1 = shifted, at standard evdev
// keycodes (reconciled to the server's by keysym).
- (NSDictionary *)keyboardMap {
    static const struct { int kc; const char *lo; const char *hi; } K[] = {
        {38,"a","A"},{56,"b","B"},{54,"c","C"},{40,"d","D"},{26,"e","E"},
        {41,"f","F"},{42,"g","G"},{43,"h","H"},{31,"i","I"},{44,"j","J"},
        {45,"k","K"},{46,"l","L"},{58,"m","M"},{57,"n","N"},{32,"o","O"},
        {33,"p","P"},{24,"q","Q"},{27,"r","R"},{39,"s","S"},{28,"t","T"},
        {30,"u","U"},{55,"v","V"},{25,"w","W"},{53,"x","X"},{29,"y","Y"},{52,"z","Z"},
        {10,"1","exclam"},{11,"2","at"},{12,"3","numbersign"},{13,"4","dollar"},
        {14,"5","percent"},{15,"6","asciicircum"},{16,"7","ampersand"},{17,"8","asterisk"},
        {18,"9","parenleft"},{19,"0","parenright"},
        {20,"minus","underscore"},{21,"equal","plus"},
        {34,"bracketleft","braceleft"},{35,"bracketright","braceright"},
        {51,"backslash","bar"},{47,"semicolon","colon"},{48,"apostrophe","quotedbl"},
        {49,"grave","asciitilde"},{59,"comma","less"},{60,"period","greater"},{61,"slash","question"},
        {65,"space",NULL},{22,"BackSpace",NULL},{36,"Return",NULL},{23,"Tab",NULL},{9,"Escape",NULL},
        {113,"Left",NULL},{114,"Right",NULL},{111,"Up",NULL},{116,"Down",NULL},
        {110,"Home",NULL},{115,"End",NULL},{112,"Prior",NULL},{117,"Next",NULL},{119,"Delete",NULL},
        {50,"Shift_L",NULL},{62,"Shift_R",NULL},{37,"Control_L",NULL},{105,"Control_R",NULL},
        {64,"Alt_L",NULL},{108,"Alt_R",NULL},{66,"Caps_Lock",NULL},
    };
    NSMutableArray *codes = [NSMutableArray array];
    NSMutableDictionary *x11 = [NSMutableDictionary dictionary];    // keycode -> [level0, level1]
    NSMutableDictionary *sym2kc = [NSMutableDictionary dictionary]; // keysym name -> keycode
    for (size_t i = 0; i < sizeof(K)/sizeof(K[0]); i++) {
        NSString *lo = @(K[i].lo);
        [codes addObject:@[@0, lo, @(K[i].kc), @0, @0]];
        sym2kc[lo] = @(K[i].kc);
        if (K[i].hi) {
            NSString *hi = @(K[i].hi);
            [codes addObject:@[@0, hi, @(K[i].kc), @0, @1]];
            sym2kc[hi] = @(K[i].kc);
            x11[@(K[i].kc)] = @[lo, hi];
        } else {
            x11[@(K[i].kc)] = @[lo];
        }
    }
    if (!_keysymToKeycode) _keysymToKeycode = [sym2kc copy];
    return @{
        @"keycodes": codes,
        // x11_keycodes makes the server take its NATIVE keycode-injection path
        // (do_get_keycode: x11_keycodes set + client_keycode>0) instead of
        // translating each keysym on the fly -- the per-key translation is what
        // dropped overlapping (rollover) keys.
        @"x11_keycodes": x11,
        @"mod_meanings": @{
            @"Shift_L": @"shift", @"Shift_R": @"shift",
            @"Control_L": @"control", @"Control_R": @"control",
            @"Alt_L": @"mod1", @"Alt_R": @"mod1", @"Caps_Lock": @"lock",
        },
        @"layout": @"us",
        @"layout_groups": @NO,
    };
}

// ---- handshake ----
- (void)transportDidConnect:(PortholeTransport *)t {
    char _hn[256] = {0}; gethostname(_hn, sizeof _hn - 1);
    NSString *hostname = _hn[0] ? [NSString stringWithUTF8String:_hn] : @"Porthole";
    const char *_u = getenv("USER");
    NSString *username = _u ? [NSString stringWithUTF8String:_u] : @"porthole";
    NSDictionary *caps = @{
        @"version": @"6.5.1",
        @"client_type": @"Porthole",
        @"uuid": _uuid ?: @"",       // required before the server enables printer forwarding
        // `username` (or user/name) is what triggers the server's ClientInfoMixin,
        // which initializes source.hostname -- the printer subsystem dereferences it.
        @"username": username,
        @"name": username,
        @"hostname": hostname,

        // rgb only, no jpeg. jpeg can't carry alpha, so the server jpeg-encoding a
        // 32-bit BGRA popup dropped its transparent Chromium shadow margin and drew a
        // fat black block (worse mid-navigation). "auto" still picked jpeg for some
        // popup redraws, so we drop jpeg entirely: every draw is rgb (alpha preserved,
        // lz4-compressed over the tunnel). 1Password's flat UI compresses well as rgb.
        @"encoding": @"rgb",
        @"encodings": @[@"rgb", @"rgb24", @"rgb32"],
        @"encodings.core": @[@"rgb", @"rgb24", @"rgb32"],
        @"rencodeplus": @YES,
        // We implement lz4 block decompression, so let the server compress its
        // stream to us (bandwidth win over the tunnel). The server reads either a
        // "compressors" list or a boolean "lz4"; advertise both.
        @"lz4": @YES,
        @"compressors": @[@"lz4"],
        // BGRA/RGBA (with alpha) let the server send a window's real alpha channel
        // -- needed so override-redirect popups (Chromium menus) send their
        // shadow-margin transparency instead of a solid black block.
        @"encodings.rgb_formats": @[@"BGRA", @"RGBA", @"RGBX", @"BGRX", @"RGB"],
        @"encoding.transparency": @YES,
        // Declare a desktop that spans the whole server root (the container's Xvfb
        // is 8192x4096). The server CLAMPS pointer events to this declared size, and
        // app windows can spawn anywhere in the big root -- a small desktop made
        // every click on an off-origin window clamp to the desktop edge and miss.
        // We composite each window into its own Mac NSWindow regardless of its
        // server position, so a large desktop costs us nothing.
        @"desktop_size": @[@8192, @4096],
        @"keyboard": @YES,   // enable keyboard input (server drops keys otherwise)
        @"keymap": [self keyboardMap],   // US-QWERTY map so the server manages shift reliably
        @"pointer": @YES,    // enable mouse/pointer input (server drops clicks otherwise)
        @"mouse": @YES,
        @"windows": @YES,
        // Cursor forwarding: show the app's real pointer shapes (I-beam, resize,
        // hand). Advertise "raw" only (not png) so the server sends BGRA pixels,
        // lz4-compressed as a raw chunk our transport already inflates -- no PNG
        // decoder needed.
        @"cursors": @YES,
        @"cursor": @{@"encodings": @[@"raw"]},
        // System-tray forwarding: the app's tray icon becomes a Mac menu-bar item.
        // The server sends a "new-tray" packet + normal draws for its icon.
        @"system_tray": @YES,
        @"chunks": @NO,   // inline pixel data in the draw packet (no separate chunks)
        // Clipboard: the server reads `clipboard` as a NESTED DICT (enabled/greedy/
        // ...). Be greedy + want text targets so the server pushes copied text to us
        // inline with the token. A non-empty dict also satisfies is_needed's boolget.
        @"clipboard": @{
            @"enabled": @YES,
            @"greedy": @YES,
            @"want_targets": @YES,
            @"selections": @[@"CLIPBOARD"],
            @"preferred-targets": @[@"UTF8_STRING", @"text/plain;charset=utf-8", @"STRING", @"TEXT"],
        },
        // Open-URL forwarding: when a link is activated inside the app, the server
        // sends us an ["open-url", url, send_id] packet to open locally. The server
        // reads open-url from the "file" namespace (authoritative); we also mirror
        // it at top level for older servers' backwards-compatible path. ask=NO so
        // the server forwards directly instead of prompting. We do NOT enable file
        // send/receive -- only URL opening.
        // File transfer: enable receiving so the server can push a file for us to
        // open (a download/attachment). We advertise NO chunk support, which makes
        // the server inline the whole file in one send-file packet (no chunk state
        // machine on our side). open-url rides in the same namespace.
        @"file": @{
            @"enabled": @YES,
            @"open": @YES,
            @"open-ask": @NO,
            // The server refuses to send any file larger than the limit WE
            // advertise; absent, it reads 0 and rejects everything ("too large").
            // Cap accepted files at 100 MB.
            @"size-limit": @(100 * 1024 * 1024),
            // Printing rides the same send-file path (printit flag). The server
            // reads printing from this "file" namespace (backwards-compatible).
            @"printing": @YES,
            @"printing-ask": @NO,
            @"open-url": @YES,
            @"open-url-ask": @NO,
        },
        @"printer": @{@"printing": @YES, @"printing-ask": @NO},
        @"open-url": @YES,
        // Notification forwarding: the server posts app notifications to us as
        // ["notify_show", ...]. The server reads the plural "notifications" dict
        // (enabled) and/or the singular "notification" bool; advertise both. The
        // server must also be launched with --notifications=yes.
        @"notification": @YES,
        @"notifications": @{@"enabled": @YES},
        // Sound: receive the app's audio + play it locally. We decode only mp3 (10.9
        // AudioToolbox decodes it natively -> nothing bundled). Server needs --speaker=on.
        // xpra 5/6 renamed the capability key "sound" -> "audio": the server reads our
        // caps from `hello["audio"]` (parse_client_caps -> dictget("audio")), and if it's
        // absent it decides "audio is not enabled for this connection" and IGNORES our
        // start request. Advertise under BOTH keys -- "audio" for this server, "sound" for
        // pre-rename ones. (The wire packet names sound-control/sound-data still work via
        // the server's legacy aliases; only the capability key had to move.)
        @"audio": @{@"receive": @YES, @"send": @NO,
                    @"decoders": @[@"mp3"], @"decoder": @"mp3"},
        @"sound": @{@"receive": @YES, @"send": @NO,
                    @"decoders": @[@"mp3"], @"decoder": @"mp3"},
    };
    [self sendPacket:@[@"hello", caps]];
}

// A wire value that is meant to be text may arrive as NSData (raw bytes) or
// already as NSString; normalize to an NSString (UTF-8).
- (NSString *)stringFromWire:(id)v {
    if ([v isKindOfClass:[NSString class]]) return v;
    if ([v isKindOfClass:[NSData class]])
        return [[[NSString alloc] initWithData:v encoding:NSUTF8StringEncoding] autorelease];
    return nil;
}

// Look up a string key in a decoded wire dict, whose keys may be NSString or
// NSData depending on how the peer encoded them.
- (id)wireDict:(NSDictionary *)d get:(NSString *)key {
    if (!d) return nil;
    id v = d[key];
    if (!v) v = d[[key dataUsingEncoding:NSUTF8StringEncoding]];
    return v;
}

// Decode text from a clipboard wire payload (encoding "bytes", UTF-8).
- (NSData *)textDataFromWire:(id)wireData encoding:(NSString *)enc {
    if (![enc isEqualToString:@"bytes"]) return nil;
    if ([wireData isKindOfClass:[NSData class]]) return wireData;
    if ([wireData isKindOfClass:[NSString class]]) return [wireData dataUsingEncoding:NSUTF8StringEncoding];
    return nil;
}

// ---- incoming packets -> shell callbacks ----
- (void)transport:(PortholeTransport *)t didReceivePayload:(NSData *)payload
        rawChunks:(NSDictionary *)rawChunks {
    NSUInteger o = 0; id pkt = [PortholeProtocol decodeValue:payload offset:&o];
    if (![pkt isKindOfClass:[NSArray class]] || [(NSArray*)pkt count]==0) return;
    NSArray *p = pkt;
    // Substitute any raw sub-packets back into the positions the server extracted
    // them from (their placeholder decodes as an empty value). Present only for
    // packets that carried a compressed/large item (e.g. send-file's file-data).
    if (rawChunks.count) {
        NSMutableArray *m = [p mutableCopy];
        for (NSNumber *idx in rawChunks) {
            NSUInteger i = [idx unsignedIntegerValue];
            if (i < m.count) m[i] = rawChunks[idx];
        }
        p = [m autorelease];
    }
    NSString *type;
    if ([p[0] isKindOfClass:[NSData class]]) {
        type = [[[NSString alloc] initWithData:p[0] encoding:NSUTF8StringEncoding] autorelease];
    } else {
        type = [p[0] description];
    }

    if ([type isEqualToString:@"hello"]) {
        NSLog(@"server hello ok");
        // The server defaults XPRA_DELAY_KEYBOARD_DATA=True, so a keymap sent in
        // `hello` is parsed but NEVER applied -- set_keymap only runs on a
        // `keymap-changed` packet. Send it now (force=YES) so the server builds the
        // keysym->keycode translation and can hold shift for capitals/symbols.
        [self sendPacket:@[@"keymap-changed", @{@"keymap": [self keyboardMap], @"modifiers": @[]}, @YES]];
        // Advertise one synthetic "print on the Mac" printer so the server
        // registers a virtual PDF/PostScript printer (via its xpraforwarder cups
        // backend); jobs printed to it forward to us as send-file(printit) ->
        // print_file -> `lp`. The device-uri must NOT start with "xpraforwarder"
        // (the peer skips those to avoid loops).
        [self sendPacket:@[@"print-devices", @{
            @"Porthole": @{
                @"printer-info": @"Porthole (Mac)",
                @"device-uri": @"porthole://mac",
                @"mimetypes": @[@"application/pdf", @"application/postscript"],
            }
        }]];
        // Kick off speaker forwarding. The server (--speaker=on) does NOT auto-start on
        // connect -- parse_audio_caps only records our receive/decoders; the stream only
        // begins when the client explicitly asks. So request it here, after hello, naming
        // the codec we can decode (mp3). "sound-control" is accepted via the server's
        // legacy alias -> "audio-control", and with the server's BACKWARDS_COMPATIBLE
        // default the audio arrives back as "sound-data" (which we handle below).
        [self sendPacket:@[@"sound-control", @"start", @"mp3"]];
    }
    else if ([type isEqualToString:@"new-window"] || [type isEqualToString:@"new-override-redirect"]) {
        if (p.count < 6) return;
        long wid=[p[1] integerValue]; int x=[p[2] intValue], y=[p[3] intValue], w=[p[4] intValue], h=[p[5] intValue];
        BOOL isOR = [type isEqualToString:@"new-override-redirect"];
        if (isOR) [_orWids addObject:@(wid)];
        // Window metadata (title etc.) rides at index 6 as a dict.
        NSString *title = nil;
        if (p.count > 6 && [p[6] isKindOfClass:[NSDictionary class]]) {
            id t = p[6][@"title"];
            if ([t isKindOfClass:[NSData class]])
                t = [[[NSString alloc] initWithData:t encoding:NSUTF8StringEncoding] autorelease];
            if ([t isKindOfClass:[NSString class]]) title = t;
        }
        NSLog(@"[WIN] %@ wid=%ld frame=(%d,%d %dx%d) title=%@", type, wid, x, y, w, h, title);
        if (_cb.new_window) _cb.new_window(_cb.ctx, wid, x, y, w, h, isOR ? 1 : 0,
                                           title ? [title UTF8String] : NULL);
        // Tell the server the window is mapped so it starts sending draws.
        [self sendPacket:@[@"map-window", @(wid), @(x), @(y), @(w), @(h), @{}]];
    }
    else if ([type isEqualToString:@"new-tray"]) {
        // ["new-tray", wid, w, h, metadata]; icon pixels then arrive as `draw`
        // packets for this wid, and it goes away via `lost-window`.
        if (p.count < 4) return;
        long wid=[p[1] integerValue]; int w=[p[2] intValue], h=[p[3] intValue];
        NSLog(@"[TRAY] new-tray wid=%ld %dx%d", wid, w, h);
        if (_cb.new_tray) _cb.new_tray(_cb.ctx, wid, w, h);
        // Do NOT map a tray: the server sends its icon draws itself (new-tray +
        // damage), and it refuses client map/configure for trays -- a map-window
        // here makes the server raise on the tray's missing `client-geometry`.
    }
    else if ([type isEqualToString:@"draw"]) {
        // draw: [ "draw", wid, x, y, w, h, coding, pixels, seq, rowstride, opts ]
        if (p.count < 9) return;
        long wid=[p[1] integerValue]; int x=[p[2] intValue], y=[p[3] intValue], w=[p[4] intValue], h=[p[5] intValue];
        NSString *coding = [p[6] isKindOfClass:[NSString class]] ? (NSString *)p[6]
                            : [[[NSString alloc] initWithData:p[6] encoding:NSUTF8StringEncoding] autorelease];
        NSData *pixels = [p[7] isKindOfClass:[NSData class]] ? p[7] : nil;
        NSInteger seq=[p[8] integerValue];
        int stride = p.count>9 ? [p[9] intValue] : w*4;
        NSDictionary *opts = (p.count>10 && [p[10] isKindOfClass:[NSDictionary class]]) ? p[10] : nil;
        // rgb pixel data can itself be lz4-compressed (flagged by opts["lz4"] once
        // we advertise lz4); inflate it before handing raw pixels to the renderer.
        // The rowstride still describes the *uncompressed* pixels, so it is unchanged.
        if (pixels && [self wireDict:opts get:@"lz4"]) {
            NSData *raw = [PortholeProtocol inflateLZ4:pixels];
            if (raw) pixels = raw;
            else NSLog(@"[DRAW] lz4 pixel inflate failed (%@ %dx%d)", coding, w, h);
        }
        if (getenv("PORTHOLE_WIRELOG"))
            NSLog(@"[DRAW] %@ %dx%d opts=%@ pixlen=%lu stride=%d", coding, w, h, opts, (unsigned long)pixels.length, stride);
        if (pixels && _cb.draw) _cb.draw(_cb.ctx, wid, x, y, w, h, [coding UTF8String], pixels.bytes, pixels.length, stride);
        [self sendPacket:@[@"damage-sequence", @(seq), @(wid), @(w), @(h), @0, @""]];
    }
    else if ([type isEqualToString:@"lost-window"]) {
        if (p.count < 2) return;
        long wid=[p[1] integerValue];
        NSLog(@"[LOST] wid=%ld", wid);
        [_orWids removeObject:@(wid)];
        if (_cb.lost_window) _cb.lost_window(_cb.ctx, wid);
    }
    // ---- clipboard ----
    // Remote copied: greedy tokens carry the text inline (index 3..7); else request it.
    else if ([type isEqualToString:@"clipboard-token"]) {
        if (p.count >= 8) {
            NSData *d = [self textDataFromWire:p[7] encoding:[p[6] description]];
            if (d && _cb.clipboard_set_text) _cb.clipboard_set_text(_cb.ctx, d.bytes, d.length);
        } else {
            [self sendPacket:@[@"clipboard-request", @(++_clipReqId), @"CLIPBOARD", @"UTF8_STRING"]];
        }
    }
    // Remote is pasting and wants our clipboard.
    else if ([type isEqualToString:@"clipboard-request"]) {
        if (p.count < 4) return;
        id reqid = p[1]; id sel = p[2]; NSString *target = [p[3] description];
        if ([target isEqualToString:@"TARGETS"]) {
            [self sendPacket:@[@"clipboard-contents", reqid, sel, @"ATOM", @32, @"atoms",
                               @[@"TARGETS", @"UTF8_STRING", @"STRING", @"TEXT"], @0]];
        } else {
            BOOL isText = [target isEqualToString:@"UTF8_STRING"] || [target isEqualToString:@"STRING"] ||
                          [target isEqualToString:@"TEXT"] || [target hasPrefix:@"text/plain"];
            if (isText) {
                // Remember the request; the shell answers via rds_provide_clipboard_text.
                [_pendingClipReqId release]; _pendingClipReqId = [reqid retain];
                [_pendingClipSel release];   _pendingClipSel = [sel retain];
                if (_cb.clipboard_wants_text) _cb.clipboard_wants_text(_cb.ctx);
                else [self provideClipboardText:nil];
            } else {
                [self sendPacket:@[@"clipboard-contents-none", reqid, sel]];
            }
        }
    }
    // Response to our request (remote -> local).
    else if ([type isEqualToString:@"clipboard-contents"]) {
        if (p.count >= 7) {
            NSData *d = [self textDataFromWire:p[6] encoding:[p[5] description]];
            if (d && _cb.clipboard_set_text) _cb.clipboard_set_text(_cb.ctx, d.bytes, d.length);
        }
    }
    else if ([type isEqualToString:@"clipboard-contents-none"]) { /* nothing to paste */ }
    // ---- open-url: a link activated in the app -> open it locally ----
    else if ([type isEqualToString:@"open-url"]) {
        // ["open-url", url, send_id]; send_id is unused by us.
        if (p.count < 2) return;
        NSString *url = [self stringFromWire:p[1]];
        NSLog(@"[OPEN-URL] %@", url);
        if (url.length && _cb.open_url) _cb.open_url(_cb.ctx, [url UTF8String]);
    }
    // ---- notification: app posted a desktop notification -> show it locally ----
    else if ([type isEqualToString:@"notify_show"] || [type isEqualToString:@"notification-show"]) {
        // [type, dbus_id, nid, app_name, replaces_nid, app_icon, summary, body,
        //  expire_timeout, icon, actions, hints]; we surface summary + body.
        if (p.count < 8) return;
        NSString *summary = [self stringFromWire:p[6]] ?: @"";
        NSString *body = [self stringFromWire:p[7]] ?: @"";
        NSLog(@"[NOTIFY] %@ / %@", summary, body);
        if (_cb.notify) _cb.notify(_cb.ctx, [summary UTF8String], [body UTF8String]);
    }
    // ---- send-file: the app wants a file opened (or printed) locally ----
    else if ([type isEqualToString:@"send-file"]) {
        // ["send-file", basefilename, mimetype, printit, openit, filesize, cdata, options, send_id]
        if (p.count < 7) return;
        NSString *fname = [self stringFromWire:p[1]] ?: @"download";
        NSString *mime = [self stringFromWire:p[2]] ?: @"";
        BOOL printit = [p[3] boolValue];
        BOOL openit = [p[4] boolValue];
        NSDictionary *opts = (p.count > 7 && [p[7] isKindOfClass:[NSDictionary class]]) ? p[7] : nil;
        // We advertised no chunk support, so the whole file should be inline. If a
        // chunked transfer arrives anyway we can't assemble it -- drop cleanly.
        if (opts[@"file-chunk-id"]) { NSLog(@"[SEND-FILE] chunked transfer unsupported, dropping %@", fname); return; }
        NSData *data = [p[6] isKindOfClass:[NSData class]] ? p[6] : nil;
        NSLog(@"[SEND-FILE] %@ mime=%@ print=%d open=%d bytes=%lu", fname, mime, printit, openit, (unsigned long)data.length);
        if (!data.length) return;
        // Print takes precedence: the print control command sets both flags.
        if (printit && _cb.print_file)
            _cb.print_file(_cb.ctx, [fname UTF8String], [mime UTF8String], data.bytes, data.length);
        else if (openit && _cb.open_file)
            _cb.open_file(_cb.ctx, [fname UTF8String], [mime UTF8String], data.bytes, data.length);
    }
    // ---- cursor: the app's pointer shape changed ----
    else if ([type isEqualToString:@"cursor"]) {
        // ["cursor", ""] (len<=2) = revert to the default cursor; otherwise
        // ["cursor", encoding, x, y, w, h, xhot, yhot, serial, pixels, name, ...].
        if (p.count <= 2) {
            if (_cb.reset_cursor) _cb.reset_cursor(_cb.ctx);
        } else if (p.count >= 10) {
            NSString *enc = [self stringFromWire:p[1]] ?: @"";
            if ([enc hasPrefix:@"default:"]) enc = [enc substringFromIndex:8];  // default-cursor def
            int w = [p[4] intValue], h = [p[5] intValue];
            int xhot = [p[6] intValue], yhot = [p[7] intValue];
            NSData *pix = [p[9] isKindOfClass:[NSData class]] ? p[9] : nil;
            NSUInteger need = (NSUInteger)(w * h * 4);
            // "raw" cursor pixels arrive lz4-compressed INLINE (a Compressed item,
            // not a frame-level chunk, so the transport didn't inflate them);
            // inflate here if they don't already match the raw BGRA size.
            if (pix && pix.length != need) {
                NSData *raw = [PortholeProtocol inflateLZ4:pix];
                if (raw) pix = raw;
            }
            if (getenv("PORTHOLE_WIRELOG"))
                NSLog(@"[CURSOR] enc=%@ %dx%d hot=(%d,%d) pixlen=%lu need=%lu", enc, w, h, xhot, yhot,
                      (unsigned long)pix.length, (unsigned long)need);
            if ([enc isEqualToString:@"raw"] && w > 0 && h > 0 && pix.length >= need) {
                if (_cb.set_cursor) _cb.set_cursor(_cb.ctx, w, h, xhot, yhot, pix.bytes, pix.length);
            } else if (_cb.reset_cursor) {
                _cb.reset_cursor(_cb.ctx);   // empty/png -> fall back to the default
            }
        }
    }
    else if ([type isEqualToString:@"sound-data"] || [type isEqualToString:@"audio-data"]) {
        // ["sound-data", codec, data, metadata]. One chunk of the forwarded audio
        // stream -> hand it to the shell to decode + play. The server names it
        // "sound-data" under its BACKWARDS_COMPATIBLE default and "audio-data"
        // otherwise; accept both so we don't depend on that server flag.
        NSString *codec = [self stringFromWire:(p.count>1?p[1]:nil)] ?: @"";
        NSData *d = (p.count>2 && [p[2] isKindOfClass:[NSData class]]) ? p[2] : nil;
        if (getenv("PORTHOLE_WIRELOG")) NSLog(@"[SOUND] %@ %lu bytes", codec, (unsigned long)d.length);
        if (d.length && _cb.audio_out) _cb.audio_out(_cb.ctx, [codec UTF8String], d.bytes, d.length);
    }
    else if ([type isEqualToString:@"sound-control"] || [type isEqualToString:@"audio-control"]) {
        // ["sound-control", command, ...]; a stop means the stream ended -> flush.
        NSString *cmd = [self stringFromWire:(p.count>1?p[1]:nil)] ?: @"";
        if ([cmd isEqualToString:@"stop"] && _cb.audio_out) _cb.audio_out(_cb.ctx, "", NULL, 0);
    }
    else if ([type isEqualToString:@"ping"]) { [self sendPacket:@[@"ping_echo", p.count>1?p[1]:@0, @0, @0, @0]]; }
}

- (void)transport:(PortholeTransport *)t didFailWithError:(NSString *)msg {
    (void)t;
    NSLog(@"transport error: %@", msg);
    // A transport failure means the session is over (no reconnect). Tell the shell once
    // -- EOF can arrive as both a zero-length read and an end-of-stream event, and a
    // teardown may surface several errors -- so it can end cleanly instead of hanging on
    // as a zombie with a dead connection.
    if (_disconnected) return;
    _disconnected = YES;
    if (_cb.disconnected) _cb.disconnected(_cb.ctx);
}

// ---- operations: input ----
// Coordinates are WINDOW-RELATIVE (view-local). The server reads a 2-element pos
// as absolute root coords, but a 4-element pos [ax,ay,rx,ry] as "window geometry
// origin + (rx,ry)". We send the relative coords in BOTH slots so the server adds
// them to the window's LIVE position -- correct wherever the window sits on the
// virtual display (a 2-element form only worked while the window was at 0,0).
- (void)pointerMoveWid:(long)wid x:(int)x y:(int)y {
    [self sendPacket:@[@"pointer-position", @(wid), @[@(x), @(y), @(x), @(y)], @[], @{}]];
}
- (void)buttonWid:(long)wid button:(int)b pressed:(int)pressed x:(int)x y:(int)y {
    [self sendPacket:@[@"button-action", @(wid), @(b), @(pressed?YES:NO), @[@(x), @(y), @(x), @(y)], @[]]];
}
- (void)keyWid:(long)wid keysym:(NSString *)ks keyval:(uint32_t)kv text:(NSString *)txt
     modifiers:(NSArray *)mods pressed:(int)pressed {
    if (!ks.length) return;
    // Native keycode for this keysym (0 if we don't map it -> server falls back to
    // keysym translation). Sending it lets the server inject directly, which
    // survives rollover.
    NSNumber *keycode = _keysymToKeycode[ks] ?: @0;
    if (getenv("PORTHOLE_KEYLOG"))
        NSLog(@"[KEY] %@ %@ kc=%@ mods=%@ kv=%u", pressed?@"v":@"^", ks, keycode, mods ?: @[], kv);
    [self enqueueKey:@[@"key-action", @(wid), ks, @(pressed?YES:NO),
                       mods ?: @[], @(kv), txt ?: @"", keycode, @0]];
}

// Serialize key-actions and drain them at a fixed minimum interval so the
// keymap-less server has time to apply each before the next arrives.
- (void)enqueueKey:(NSArray *)pkt {
    if (_keyIntervalMs <= 0) { [self sendPacket:pkt]; return; }   // no pacing: natural timing
    [_keyQueue addObject:pkt];
    if (!_keyDraining) { _keyDraining = YES; [self drainKeyQueue]; }
}
- (void)drainKeyQueue {
    if (_keyQueue.count == 0) { _keyDraining = NO; return; }
    NSArray *pkt = [[_keyQueue objectAtIndex:0] retain];
    [_keyQueue removeObjectAtIndex:0];
    [self sendPacket:pkt];
    [pkt release];
    [self performSelector:@selector(drainKeyQueue) withObject:nil
               afterDelay:_keyIntervalMs/1000.0 inModes:@[NSRunLoopCommonModes]];
}

// ---- operations: focus coordination ----
// Xpra keeps a focused toplevel; an unfocused toplevel dismisses its popups. So
// establishing focus on our windows keeps popups alive; dropping focus dismisses
// them. focus(0) alone does not move X focus, so if a popup is open when we lose
// focus we also send Escape to the parent to dismiss it.
- (void)focusGained:(long)wid {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(sendLostFocus) object:nil];
    if (getenv("PORTHOLE_KEYLOG")) NSLog(@"[FOCUS] gained wid=%ld (was %ld)", wid, (long)_focusedWid);
    if (_focusedWid != wid) { _focusedWid = wid; [self sendPacket:@[@"focus", @(wid), @[]]]; }
}
- (void)focusLost:(long)wid {
    (void)wid;
    [self performSelector:@selector(sendLostFocus) withObject:nil afterDelay:0.05
                  inModes:@[NSRunLoopCommonModes]];
}
- (void)sendLostFocus {
    NSInteger prev = _focusedWid;
    if (getenv("PORTHOLE_KEYLOG")) NSLog(@"[FOCUS] LOST -> focus 0 (was %ld, popups=%lu)", (long)prev, (unsigned long)_orWids.count);
    _focusedWid = 0;
    if (_orWids.count > 0 && prev) {
        [self sendPacket:@[@"key-action", @(prev), @"Escape", @YES, @[], @0xff1b, @"", @0, @0]];
        [self sendPacket:@[@"key-action", @(prev), @"Escape", @NO,  @[], @0xff1b, @"", @0, @0]];
    }
    [self sendPacket:@[@"focus", @0, @[]]];
}

// ---- operations: geometry ----
- (void)configureWid:(long)wid w:(int)w h:(int)h {
    [self sendPacket:@[@"configure-window", @(wid), @0, @0, @(w), @(h), @{}]];
}
// ---- operations: clipboard ----
- (void)clipboardChanged {
    // Claim the remote clipboard and advertise our text targets so a remote
    // paste can request them.
    [self sendPacket:@[@"clipboard-token", @"CLIPBOARD",
                       @[@"UTF8_STRING", @"STRING", @"TEXT", @"text/plain;charset=utf-8", @"text/plain", @"TARGETS"]]];
}
- (void)provideClipboardText:(NSData *)utf8 {
    if (!_pendingClipReqId) return;
    if (utf8.length) {
        [self sendPacket:@[@"clipboard-contents", _pendingClipReqId, _pendingClipSel,
                           @"UTF8_STRING", @8, @"bytes", utf8, @0]];
    } else {
        [self sendPacket:@[@"clipboard-contents-none", _pendingClipReqId, _pendingClipSel]];
    }
    [_pendingClipReqId release]; _pendingClipReqId = nil;
    [_pendingClipSel release];   _pendingClipSel = nil;
}

@end

// ============================================================================
// remote_display C interface -- the Xpra backend. rds_session is an PortholeClient.
// ============================================================================
rds_session *rds_xpra_create(const char *socket_path, const rds_callbacks *cb) {
    PortholeClient *c = [[PortholeClient alloc]
        initWithSocketPath:[NSString stringWithUTF8String:socket_path] callbacks:cb];
    return (rds_session *)c;
}
void rds_start(rds_session *s)   { [(PortholeClient *)s start]; }
void rds_destroy(rds_session *s) { [(PortholeClient *)s release]; }

void rds_pointer_move(rds_session *s, long wid, int x, int y) {
    [(PortholeClient *)s pointerMoveWid:wid x:x y:y];
}
void rds_button(rds_session *s, long wid, int button, int pressed, int x, int y) {
    [(PortholeClient *)s buttonWid:wid button:button pressed:pressed x:x y:y];
}
void rds_key(rds_session *s, long wid, const char *keysym, uint32_t keyval,
             const char *text, const char *const *modifiers, size_t modifier_count, int pressed) {
    NSMutableArray *mods = [NSMutableArray arrayWithCapacity:modifier_count];
    for (size_t i = 0; i < modifier_count; i++)
        [mods addObject:[NSString stringWithUTF8String:modifiers[i]]];
    [(PortholeClient *)s keyWid:wid
                      keysym:(keysym ? [NSString stringWithUTF8String:keysym] : @"")
                      keyval:keyval
                        text:(text ? [NSString stringWithUTF8String:text] : @"")
                   modifiers:mods
                     pressed:pressed];
}
void rds_window_focus_gained(rds_session *s, long wid) { [(PortholeClient *)s focusGained:wid]; }
void rds_window_focus_lost(rds_session *s, long wid)   { [(PortholeClient *)s focusLost:wid]; }
void rds_configure_window(rds_session *s, long wid, int w, int h) {
    [(PortholeClient *)s configureWid:wid w:w h:h];
}
void rds_clipboard_changed(rds_session *s) { [(PortholeClient *)s clipboardChanged]; }
void rds_provide_clipboard_text(rds_session *s, const char *utf8, size_t len) {
    NSData *d = (utf8 && len) ? [NSData dataWithBytes:utf8 length:len] : nil;
    [(PortholeClient *)s provideClipboardText:d];
}
