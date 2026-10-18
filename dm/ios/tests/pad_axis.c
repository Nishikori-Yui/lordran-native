#include "../Sources/dm_pad_axis.h"
#include "../../host/dm_padmap.h"
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
int main(void) {
    int32_t x, y;
    dm_pad_axis(0.08, -0.04, 0.12, &x, &y); assert(x == 0 && y == 0);
    dm_pad_axis(0.56, 0, 0.12, &x, &y); assert(abs(x - 16384) <= 1 && y == 0);
    dm_pad_axis(1, -1, 0.12, &x, &y); assert(abs(x - 23170) <= 1 && abs(y + 23170) <= 1);
    dm_pad_axis(-1, 0, 0.12, &x, &y); assert(x == -32767 && y == 0);
    dm_pad_axis(0.12, 0, 0.12, &x, &y); assert(x == 0 && y == 0);
    dm_pad_axis(NAN, 1, 0.12, &x, &y); assert(x == 0 && y == 0);
    dm_pad_axis(0, INFINITY, 0.12, &x, &y); assert(x == 0 && y == 0);
    dm_pad_axis(0.56, 0, NAN, &x, &y); assert(abs(x - 16384) <= 1 && y == 0);
    assert(dm_padmap_face(DM_PADKIND_NINTENDO, 1, 0, 0, 0) == DM_BTN_B);
    assert(dm_padmap_face(DM_PADKIND_XBOX, 1, 0, 0, 0) == DM_BTN_A);
    assert(dm_padmap_kind("Switch Pro Controller", "Pro Controller") == DM_PADKIND_NINTENDO);
    assert(dm_padmap_kind("DualSense", "Sony") == DM_PADKIND_XBOX);
    for (int i = 0; i <= 100; i++) {
        dm_pad_axis(i / 100.0, 0, 0.12, &x, &y);
        assert(x >= 0 && x <= 32767 && y == 0);
    }
    puts("controller: radial deadzone, range, invalid input and face mapping passed");
    return 0;
}
