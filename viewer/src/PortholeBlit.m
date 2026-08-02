#include "PortholeBlit.h"
#include <string.h>

void op_blit_patch(uint8_t *dst, size_t dstStride, int dstW, int dstH,
                   int x, int y,
                   const uint8_t *src, size_t srcStride, size_t srcLen,
                   int w, int h, int srcBpp) {
    if (!dst || !src || x < 0 || y < 0 || x >= dstW || y >= dstH) return;
    if (x + w > dstW) w = dstW - x;          // clip right
    if (y + h > dstH) h = dstH - y;          // clip bottom
    if (w <= 0 || h <= 0) return;
    for (int row = 0; row < h; row++) {
        size_t so = (size_t)row * srcStride;
        if (so + (size_t)w * srcBpp > srcLen) break;   // short source: stop
        const uint8_t *s = src + so;
        uint8_t *d = dst + (size_t)(y + row) * dstStride + (size_t)x * 4;
        if (srcBpp == 4) {
            memcpy(d, s, (size_t)w * 4);               // BGRX/BGRA -> BGRA, no swap
        } else {                                        // 3-byte RGB -> BGRA reorder
            for (int px = 0; px < w; px++) {
                d[px*4+0] = s[px*3+2];   // B
                d[px*4+1] = s[px*3+1];   // G
                d[px*4+2] = s[px*3+0];   // R
                d[px*4+3] = 255;         // A
            }
        }
    }
}
