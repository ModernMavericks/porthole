#import "PortholeBgSample.h"

static uint32_t pixel_argb(const uint8_t *base, size_t stride, int x, int y,
                           int bpp) {
    const uint8_t *p = base + (size_t)y * stride + (size_t)x * bpp;
    uint8_t b = p[0], g = p[1], r = p[2];
    uint8_t a = (bpp == 4) ? p[3] : 0xFF;
    return ((uint32_t)a << 24) | ((uint32_t)r << 16) |
           ((uint32_t)g << 8) | (uint32_t)b;
}

uint32_t op_sample_bg(const uint8_t *base, size_t stride, int w, int h,
                      int bytesPerPixel) {
    if (!base || w <= 0 || h <= 0) return 0u;
    int xr = w - 1, yb = h - 1, xm = w / 2, ym = h / 2;
    // 4 corners + 4 edge midpoints.
    int xs[8] = { 0, xr, 0,  xr, xm, xm, 0,  xr };
    int ys[8] = { 0, 0,  yb, yb, 0,  yb, ym, ym };
    uint32_t vals[8]; int counts[8] = {0};
    int n = 0;
    for (int i = 0; i < 8; i++) {
        uint32_t c = pixel_argb(base, stride, xs[i], ys[i], bytesPerPixel);
        int found = -1;
        for (int j = 0; j < n; j++) if (vals[j] == c) { found = j; break; }
        if (found < 0) { vals[n] = c; counts[n] = 1; n++; }
        else counts[found]++;
    }
    int best = 0;
    for (int j = 1; j < n; j++) if (counts[j] > counts[best]) best = j;
    return vals[best];
}
