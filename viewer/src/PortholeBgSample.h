#ifndef OP_BG_SAMPLE_H
#define OP_BG_SAMPLE_H
#include <stdint.h>
#include <stddef.h>

// Sample the dominant "window background" color from a BGRA (or BGRX) pixel
// buffer by reading 8 points around the edges of the w*h content region (the
// 4 corners + 4 edge midpoints) and returning the most frequent one (ties ->
// first sampled). Returns packed ARGB 0xAARRGGBB. Returns 0 if w<=0 or h<=0.
// bytesPerPixel is 3 (rgb24, alpha forced to 0xFF) or 4 (BGRA/BGRX).
uint32_t op_sample_bg(const uint8_t *base, size_t stride, int w, int h,
                      int bytesPerPixel);
#endif
