#ifndef DM_VPHONE_REMAP_H
#define DM_VPHONE_REMAP_H

#include <TargetConditionals.h>

#if TARGET_OS_IPHONE || defined(DM_VPHONE_REMAP_TEST)
#include <mach/mach.h>

// Check the mapping created by vm_remap and, only when explicitly enabled,
// repair the read-only executable alias observed in vphone guests.
int dm_vphone_remap_compatible(const char *name, vm_address_t to,
                               const void *from, vm_size_t size,
                               boolean_t copy, vm_prot_t need,
                               vm_prot_t reported, vm_prot_t reported_max);
#endif

#endif
