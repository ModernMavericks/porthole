#import <Cocoa/Cocoa.h>
#import "PortholeLayerPresenter.h"
#include <assert.h>

int main(void) {
    @autoreleasepool {
        // A 800x600 window on a 1600x1200 max surface -> top-left half in each axis.
        CGRect r = [PortholeLayerPresenter contentsRectForSize:NSMakeSize(800,600)
                                                 maxSize:NSMakeSize(1600,1200)];
        assert(r.origin.x == 0.0 && r.origin.y == 0.0);
        assert(r.size.width == 0.5 && r.size.height == 0.5);
        // Degenerate maxSize -> full unit rect, no divide-by-zero.
        CGRect z = [PortholeLayerPresenter contentsRectForSize:NSMakeSize(100,100)
                                                 maxSize:NSMakeSize(0,0)];
        assert(z.size.width == 1.0 && z.size.height == 1.0);
        // contentsRect is clamped to the CONTENT extent, not the window size:
        // window 1600x1000, content only 1000x500, max 2000x2000 -> 0.5 x 0.25.
        {
            CGRect r = [PortholeLayerPresenter contentsRectForSize:NSMakeSize(1600,1000)
                                                     maxSize:NSMakeSize(2000,2000)
                                                     content:NSMakeSize(1000,500)];
            assert(r.size.width == 0.5 && r.size.height == 0.25);
        }
        // When the window is SMALLER than content, it clips to the window (min wins):
        // window 500x250, content 1000x500, max 2000x2000 -> 0.25 x 0.125.
        {
            CGRect r = [PortholeLayerPresenter contentsRectForSize:NSMakeSize(500,250)
                                                     maxSize:NSMakeSize(2000,2000)
                                                     content:NSMakeSize(1000,500)];
            assert(r.size.width == 0.25 && r.size.height == 0.125);
        }
        // ARGB 0xFF3366CC unpacks to R=0x33,G=0x66,B=0xCC,A=0xFF components.
        {
            CGColorRef c = [PortholeLayerPresenter newColorFromARGB:0xFF3366CCu];
            const CGFloat *comp = CGColorGetComponents(c);
            assert((int)(comp[0]*255.0 + 0.5) == 0x33);
            assert((int)(comp[1]*255.0 + 0.5) == 0x66);
            assert((int)(comp[2]*255.0 + 0.5) == 0xCC);
            assert((int)(comp[3]*255.0 + 0.5) == 0xFF);
            CGColorRelease(c);
        }
        printf("test_layer_presenter: OK\n");
    }
    return 0;
}
