#include "remap.h"

#if TARGET_OS_IPHONE || defined(DM_VPHONE_REMAP_TEST)

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libkern/OSCacheControl.h>

#define LOG(...) do { fprintf(stderr, "[dm] " __VA_ARGS__); fputc('\n', stderr); } while (0)

static int mapped_protection(vm_address_t start, vm_size_t length, vm_prot_t need,
                             int exact, int trace, const char *label) {
    vm_address_t end = start + length;
    if (!length || end < start) return 0;
    for (vm_address_t p = start; p < end;) {
        vm_address_t a = p;
        vm_size_t region_size = 0;
        vm_region_basic_info_data_64_t info = {0};
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        kern_return_t kr = vm_region_64(mach_task_self(), &a, &region_size,
            VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object);
        if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
        if (kr != KERN_SUCCESS || a > p || !region_size || p - a >= region_size) {
            LOG("【红】VM map %s: query %#lx failed (%d)", label, (unsigned long)p, kr);
            return 0;
        }
        if (trace || (info.protection & need) != need || (exact && info.protection != need))
            LOG("VM map %s: %#lx + %#lx actual=%#x max=%#x shared=%d", label,
                (unsigned long)a, (unsigned long)region_size, info.protection,
                info.max_protection, info.shared);
        if ((info.protection & need) != need || (exact && info.protection != need)) return 0;
        vm_size_t step = region_size - (p - a);
        p += step < end - p ? step : end - p;
    }
    return 1;
}

int dm_vphone_remap_compatible(const char *name, vm_address_t to,
                               const void *from, vm_size_t size,
                               boolean_t copy, vm_prot_t need,
                               vm_prot_t reported, vm_prot_t reported_max) {
    const char *compat = getenv("DM_VPHONE_CODE_COPY");
    int repair = compat && !strcmp(compat, "1") && (need & VM_PROT_EXECUTE);
    int trace = repair || getenv("DM_VM_MAP_DIAG") != NULL;
    char source[64], target[64];
    snprintf(source, sizeof source, "%s source", name);
    snprintf(target, sizeof target, "%s target", name);

    if (trace)
        LOG("VM remap %s: %p -> %#lx size=%#lx copy=%d reported=%#x/%#x",
            name, from, (unsigned long)to, (unsigned long)size, copy,
            reported, reported_max);
    if (trace && !mapped_protection((vm_address_t)from, size, need, 0, trace, source))
        return 0;
    if (mapped_protection(to, size, need, 0, trace, target)) return 1;

    // This is deliberately narrow: only an executable, shared remap whose
    // destination became exactly read-only is eligible for the vphone fallback.
    vm_address_t src = (vm_address_t)from;
    if (!repair || copy || need != (VM_PROT_READ | VM_PROT_EXECUTE) ||
        ((to | src | size) & (vm_page_size - 1)) ||
        size > UINTPTR_MAX - to || size > UINTPTR_MAX - src ||
        !(to + size <= src || src + size <= to) ||
        (reported & need) != need ||
        !mapped_protection(src, size, VM_PROT_READ | VM_PROT_EXECUTE, 1, 1, source) ||
        !mapped_protection(to, size, VM_PROT_READ, 1, 1, target))
        return 0;

    vm_address_t a = to;
    kern_return_t kr = vm_allocate(mach_task_self(), &a, size,
                                   VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE);
    if (kr != KERN_SUCCESS || a != to) {
        LOG("【红】VM vphone code allocation %s failed (%d)", name, kr);
        if (kr == KERN_SUCCESS) vm_deallocate(mach_task_self(), a, size);
        return 0;
    }
    kr = vm_inherit(mach_task_self(), to, size, VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS) {
        LOG("【红】VM vphone code inheritance %s failed (%d)", name, kr);
        vm_deallocate(mach_task_self(), to, size);
        return 0;
    }
    memcpy((void *)to, from, size);
    sys_icache_invalidate((void *)to, size);
    kr = vm_protect(mach_task_self(), to, size, FALSE, need);
    if (kr != KERN_SUCCESS || !mapped_protection(to, size, need, 1, 1, target)) {
        LOG("【红】VM vphone code sealing %s failed (%d)", name, kr);
        vm_deallocate(mach_task_self(), to, size);
        return 0;
    }
    LOG("VM vphone code copy %s: sealed %#lx bytes at %#lx", name,
        (unsigned long)size, (unsigned long)to);
    return 1;
}

#endif
