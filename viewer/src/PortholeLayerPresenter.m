#import "PortholeLayerPresenter.h"
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurface.h>

@implementation PortholeLayerPresenter {
    NSView *_view;          // weak (owned by the window)
    IOSurfaceRef _surface;  // owned by the view; not retained here
    BOOL _opaque;
    NSSize _content;              // extent of real drawn content in the surface (<= max)
    NSSize _lastLogical, _lastMax; // remembered for setContentSize: re-apply
}

+ (CGRect)contentsRectForSize:(NSSize)size maxSize:(NSSize)maxSize {
    return [self contentsRectForSize:size maxSize:maxSize content:maxSize];
}

+ (CGRect)contentsRectForSize:(NSSize)size maxSize:(NSSize)maxSize content:(NSSize)content {
    if (maxSize.width <= 0 || maxSize.height <= 0) return CGRectMake(0,0,1,1);
    CGFloat vw = size.width  < content.width  ? size.width  : content.width;
    CGFloat vh = size.height < content.height ? size.height : content.height;
    CGFloat w = vw / maxSize.width, h = vh / maxSize.height;
    if (w > 1) w = 1;
    if (h > 1) h = 1;
    return CGRectMake(0, 0, w, h);   // top-left sub-region
}

- (BOOL)attachToView:(PortholeView *)view surface:(IOSurfaceRef)surface opaque:(BOOL)opaque {
    if (!view || !surface) return NO;
    _view = (NSView *)view; _surface = surface; _opaque = opaque;
    _content = NSMakeSize((CGFloat)IOSurfaceGetWidth(surface),
                          (CGFloat)IOSurfaceGetHeight(surface));
    // Layer-HOSTING (set the layer BEFORE wantsLayer), not layer-BACKED: we own the
    // layer and AppKit never renders into it via drawRect. Under layer-backing, a live
    // resize makes AppKit re-run drawRect (which draws nothing on this path) and clobber
    // our IOSurface contents every frame -> blank in the in-betweens.
    CALayer *layer = [CALayer layer];
    [_view setLayer:layer];
    [_view setWantsLayer:YES];
    if (!layer) return NO;
    // The host PortholeView is isFlipped=YES (top-left origin to match X). In that
    // flipped geometry, CA's "bottomLeft" gravity is the VISUAL top-left, so a
    // grown layer keeps content pinned to the visual top-left and opens the strip
    // at the bottom/right (kCAGravityTopLeft would pin to the visual bottom).
    [layer setContentsGravity:kCAGravityBottomLeft];
    [layer setOpaque:opaque];
    // Fill exposed (grown) area cleanly, matching the old drawRect background fill.
    CGColorRef bg = CGColorCreateGenericGray(0.93, opaque ? 1.0 : 0.0);
    [layer setBackgroundColor:bg];
    CGColorRelease(bg);
    [layer setContents:(id)surface];
    return YES;
}

- (void)setLogicalSize:(NSSize)size maxSize:(NSSize)maxSize {
    if (!_view) return;
    _lastLogical = size; _lastMax = maxSize;
    [[_view layer] setContentsRect:
        [PortholeLayerPresenter contentsRectForSize:size maxSize:maxSize content:_content]];
}

+ (CGColorRef)newColorFromARGB:(uint32_t)argb {
    CGFloat a = ((argb >> 24) & 0xFF) / 255.0;
    CGFloat r = ((argb >> 16) & 0xFF) / 255.0;
    CGFloat g = ((argb >> 8)  & 0xFF) / 255.0;
    CGFloat b = ( argb        & 0xFF) / 255.0;
    return CGColorCreateGenericRGB(r, g, b, a);   // +1
}

- (void)setFillColor:(uint32_t)argb {
    if (!_view) return;
    CGColorRef c = [PortholeLayerPresenter newColorFromARGB:argb];
    [[_view layer] setBackgroundColor:c];
    CGColorRelease(c);
}

- (void)setContentSize:(NSSize)content {
    _content = content;
    if (!_view || _lastMax.width <= 0) return;
    [[_view layer] setContentsRect:
        [PortholeLayerPresenter contentsRectForSize:_lastLogical maxSize:_lastMax content:content]];
}

- (void)present {
    CALayer *layer = [_view layer];
    if (!layer) return;
    double t0 = getenv("PORTHOLE_PRESENTLOG") ? [NSDate timeIntervalSinceReferenceDate] : 0;
    // Force CA to re-read the (mutated) surface: clear + re-set contents with
    // implicit animations disabled so it composites the new pixels immediately.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [layer setContents:nil];
    [layer setContents:(id)_surface];
    [CATransaction commit];
    if (getenv("PORTHOLE_PRESENTLOG"))
        NSLog(@"[PRESENT] %.1fms", ([NSDate timeIntervalSinceReferenceDate] - t0) * 1000.0);
}

- (void)detach { _view = nil; _surface = NULL; }
@end
