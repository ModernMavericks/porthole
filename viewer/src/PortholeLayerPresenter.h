#import "PortholeSurfacePresenter.h"

// Presenter A: hand the IOSurface straight to a layer-backed view's CALayer.
@interface PortholeLayerPresenter : NSObject <PortholeSurfacePresenter>
// Compute the normalized contentsRect for a size within maxSize (testable seam).
+ (CGRect)contentsRectForSize:(NSSize)size maxSize:(NSSize)maxSize;
+ (CGRect)contentsRectForSize:(NSSize)size maxSize:(NSSize)maxSize content:(NSSize)content;
// Unpack a packed ARGB color (0xAARRGGBB) into a CGColor. Caller releases (+1).
+ (CGColorRef)newColorFromARGB:(uint32_t)argb;
- (void)setContentSize:(NSSize)content;
- (void)setFillColor:(uint32_t)argb;
@end
