#include <stdatomic.h>

static _Atomic int focus = 1;
int dm_focus_now(void) { return atomic_load(&focus); }
void test_focus_set(int value) { atomic_store(&focus, value); }
