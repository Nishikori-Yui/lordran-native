#include <stdint.h>
#include "../dm.h"
module_t *module_of(const void *p) { (void)p; return 0; }
module_t g_mod[MAX_MOD];
int g_nmod;
