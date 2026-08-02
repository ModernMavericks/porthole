#include "PortholeBlit.h"
#include <string.h>
#include <stdio.h>
#include <assert.h>

int main(void) {
    // 4x3 BGRA destination, prefilled 0xEE so we can see untouched bytes.
    uint8_t dst[4*3*4];
    memset(dst, 0xEE, sizeof dst);
    size_t dstStride = 4*4;

    // --- 4-byte BGRX patch copied straight (no swap) at (0,0), 2x1 ---
    uint8_t src4[] = {10,20,30,40,  50,60,70,80};
    op_blit_patch(dst, dstStride, 4, 3, 0, 0, src4, 8, sizeof src4, 2, 1, 4);
    assert(dst[0]==10 && dst[1]==20 && dst[2]==30 && dst[3]==40);
    assert(dst[4]==50 && dst[5]==60 && dst[6]==70 && dst[7]==80);
    assert(dst[8]==0xEE);                       // third pixel untouched

    // --- 3-byte RGB patch reordered to BGRA at (1,1), 1x1 ---
    uint8_t src3[] = {100,110,120};             // R=100,G=110,B=120
    op_blit_patch(dst, dstStride, 4, 3, 1, 1, src3, 3, sizeof src3, 1, 1, 3);
    size_t o = 1*dstStride + 1*4;
    assert(dst[o+0]==120 && dst[o+1]==110 && dst[o+2]==100 && dst[o+3]==255);

    // --- bounds clip: a 3-wide patch at x=2 into a 4-wide dst copies only 2 px ---
    uint8_t wide[] = {1,1,1,1, 2,2,2,2, 3,3,3,3};
    op_blit_patch(dst, dstStride, 4, 3, 2, 2, wide, 12, sizeof wide, 3, 1, 4);
    size_t r2 = 2*dstStride;
    assert(dst[r2 + 2*4]==1 && dst[r2 + 3*4]==2); // px 0,1 written
    // (px 2 would be at x=4, out of bounds -> not written; no overrun)

    // --- short source: srcLen too small stops before reading past the end ---
    uint8_t two[] = {9,9,9,9};                  // claims 2x1 but only 1 px of data
    memset(dst, 0, sizeof dst);
    op_blit_patch(dst, dstStride, 4, 3, 0, 0, two, 8, sizeof two, 2, 1, 4);
    assert(dst[0]==0);                          // row needs 8 bytes, only 4 -> skipped

    printf("test_iosurface_blit: OK\n");
    return 0;
}
