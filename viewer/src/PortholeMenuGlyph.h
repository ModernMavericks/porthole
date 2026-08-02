// PortholeMenuGlyph -- derive a native menu-bar template glyph for 1Password from the
// app's own icon (extracted, at build time, into the .app bundle -- never committed).
// Value-thresholds the icon to isolate 1Password's dark navy mark from its blue disc,
// then composes it inside a ring (matching the modern macOS menu-bar presentation).
// Returns a template NSImage (18pt), or nil if the icon has no isolable mark (caller
// then falls back to the forwarded tray icon). When `locked` is YES, a small padlock
// badge is added at the lower-right (matching 1Password's locked menu-bar state).
#import <Cocoa/Cocoa.h>

NSImage *PortholeOnePasswordMenuGlyph(NSImage *appIcon, BOOL locked);
