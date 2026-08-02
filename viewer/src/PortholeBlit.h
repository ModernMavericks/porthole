#ifndef PORTHOLE_BLIT_H
#define PORTHOLE_BLIT_H
#include <stddef.h>
#include <stdint.h>

// Write one decoded patch into a BGRA destination buffer at (x,y), clipped to
// the destination bounds. The server sends two source layouts:
//   srcBpp == 4: B,G,R,(X|A)  -> copied straight into BGRA (no swap). The 4th byte
//                is X (padding) for opaque windows -- the layer is opaque so the
//                compositor ignores it -- or real alpha for override-redirect popups.
//   srcBpp == 3: R,G,B        -> reordered to B,G,R,255 (xpra "rgb24" is RGB order).
// srcLen guards against a short source (stops the copy at the last full row).
void op_blit_patch(uint8_t *dst, size_t dstStride, int dstW, int dstH,
                   int x, int y,
                   const uint8_t *src, size_t srcStride, size_t srcLen,
                   int w, int h, int srcBpp);

#endif
