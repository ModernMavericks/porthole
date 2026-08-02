#import <Cocoa/Cocoa.h>
#import <IOSurface/IOSurface.h>

@class PortholeView;

// Presents an IOSurface backing store on-screen. The view owns the surface and
// writes pixels into it; the presenter only handles GPU composition + geometry.
@protocol PortholeSurfacePresenter <NSObject>
// Wire up against the view's layer. `opaque` = normal window (ignore the 4th byte)
// vs. NO for override-redirect popups (honor alpha). Returns NO if unusable.
- (BOOL)attachToView:(PortholeView *)view surface:(IOSurfaceRef)surface opaque:(BOOL)opaque;
// Show the sub-region (0,0,size) of a maxSize surface at 1:1, top-left, no stretch.
- (void)setLogicalSize:(NSSize)size maxSize:(NSSize)maxSize;
// Constrain the visible content to this extent (drawn area within the surface).
- (void)setContentSize:(NSSize)content;
// Recolor the exposed "growth strip" with a sampled background (packed 0xAARRGGBB).
- (void)setFillColor:(uint32_t)argb;
// Recomposite after the view has written this frame's patches + unlocked.
- (void)present;
- (void)detach;
@end
