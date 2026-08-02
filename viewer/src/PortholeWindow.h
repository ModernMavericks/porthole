#import <Cocoa/Cocoa.h>
#import "remote_display.h"

@interface PortholeWindow : NSObject
// frame.origin = the window's server-side (root) position; frame.size = its size.
// override-redirect windows (menus/popovers) are shown borderless, never take key
// focus, and are positioned at their server position relative to `parentTopLeft`.
- (instancetype)initWithSession:(rds_session *)session wid:(NSInteger)wid frame:(NSRect)frame
               overrideRedirect:(BOOL)overrideRedirect parentTopLeft:(NSPoint)parentTopLeft
                          title:(NSString *)title;
- (void)drawRGB:(NSData *)rgb rect:(NSRect)rect coding:(NSString *)coding rowstride:(NSInteger)stride;
// Set the remote app's pointer shape over this window (nil = platform default).
- (void)setAppCursor:(NSCursor *)cursor;
// Center this window on the main screen. Used for the tray/hotkey-summoned Quick
// Access panel, which modern 1Password shows as a centered floating window.
- (void)centerOnScreen;
// Bring this window back on screen and focus it (e.g. re-launching the app while
// it sits resident in the menu bar with its window closed).
- (void)showFront;
// Show this popup as the key window (used for the Quick Access panel, so it captures
// the keyboard without the main window needing to be shown/focused).
- (void)makeKeyPopup;
// Inject a synthetic Ctrl(+Shift)+<key> shortcut into the session (menu-driven
// actions: Lock = Ctrl+Shift+L, Settings = Ctrl+comma). keyname is the X keysym
// name, keyval its Latin-1 codepoint (0 for named keys).
- (void)sendControlShortcut:(NSString *)keyname keyval:(uint32_t)keyval shift:(BOOL)shift;
// General combo forwarder for menu-manifest items: hold `mods` (X modifier names:
// "control"/"shift"/"mod1") and press `keyname` (X keysym name; keyval its codepoint).
- (void)sendCombo:(NSArray *)mods keyname:(NSString *)keyname keyval:(uint32_t)keyval;
// Is this the app's key (focused) window? Lets the main-menu Edit actions route a
// forwarded shortcut to whichever viewer window currently has focus.
- (BOOL)isKeyWindow;
// Top-left screen coordinate (y measured from the top) of this window's content
// view -- used to place child popups at the right spot.
- (NSPoint)contentTopLeftScreen;
@end
