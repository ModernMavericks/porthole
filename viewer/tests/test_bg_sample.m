#import <Foundation/Foundation.h>
#import "PortholeBgSample.h"

static int failures = 0;
#define CHECK(cond, msg) do { if (!(cond)) { \
    fprintf(stderr, "FAIL: %s\n", msg); failures++; } } while (0)

// Fill a w*h BGRA buffer with one color (b,g,r,a) at 4 bytes/px.
static uint8_t *solid(int w, int h, uint8_t b, uint8_t g, uint8_t r, uint8_t a) {
    uint8_t *buf = malloc((size_t)w * h * 4);
    for (int i = 0; i < w * h; i++) {
        buf[i*4+0] = b; buf[i*4+1] = g; buf[i*4+2] = r; buf[i*4+3] = a;
    }
    return buf;
}

int main(void) {
    // Solid red -> 0xFFFF0000 (A=FF,R=FF,G=00,B=00).
    uint8_t *red = solid(100, 80, 0, 0, 255, 255);
    CHECK(op_sample_bg(red, 100*4, 100, 80, 4) == 0xFFFF0000u, "solid red");
    free(red);

    // rgb24 (3 bpp): solid green, alpha forced to 0xFF -> 0xFF00FF00.
    int w = 50, h = 40; uint8_t *g24 = malloc((size_t)w*h*3);
    for (int i = 0; i < w*h; i++) { g24[i*3+0]=0; g24[i*3+1]=255; g24[i*3+2]=0; }
    CHECK(op_sample_bg(g24, (size_t)w*3, w, h, 3) == 0xFF00FF00u, "rgb24 green");
    free(g24);

    // Uniform edges, different center: edges win (center is never sampled).
    uint8_t *buf = solid(60, 60, 255, 0, 0, 255);   // all blue = 0xFF0000FF
    int cx = 30, cy = 30; uint8_t *p = buf + (size_t)cy*60*4 + cx*4;
    p[0]=0; p[1]=0; p[2]=255; p[3]=255;
    CHECK(op_sample_bg(buf, 60*4, 60, 60, 4) == 0xFF0000FFu, "edges beat center");
    free(buf);

    // Degenerate dims -> 0, no crash.
    CHECK(op_sample_bg(NULL, 0, 0, 0, 4) == 0u, "zero dims -> 0");

    if (failures) { fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    printf("all bg_sample tests passed\n");
    return 0;
}
