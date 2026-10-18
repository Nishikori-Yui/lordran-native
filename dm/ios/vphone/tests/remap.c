#include "../remap.h"
#include <assert.h>
#include <libkern/OSCacheControl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const vm_prot_t rx = VM_PROT_READ | VM_PROT_EXECUTE;

static vm_address_t allocate(vm_size_t size) {
    vm_address_t p = 0;
    assert(vm_allocate(mach_task_self(), &p, size, VM_FLAGS_ANYWHERE) == KERN_SUCCESS);
    return p;
}

static vm_prot_t protection(vm_address_t p) {
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info = {0};
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    assert(vm_region_64(mach_task_self(), &p, &size, VM_REGION_BASIC_INFO_64,
        (vm_region_info_t)&info, &count, &object) == KERN_SUCCESS);
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    return info.protection;
}

int main(void) {
    vm_size_t size = vm_page_size;
    vm_address_t src = allocate(size), dst = allocate(size * 2);
    // mov w0, #42; ret. The fallback must produce executable, identical bytes.
    const uint32_t code[] = {0x52800540, 0xd65f03c0};
    memcpy((void *)src, code, sizeof code);
    sys_icache_invalidate((void *)src, size);
    assert(vm_protect(mach_task_self(), src, size, FALSE, rx) == KERN_SUCCESS);
    assert(vm_protect(mach_task_self(), dst, size * 2, FALSE, VM_PROT_READ) == KERN_SUCCESS);
    unsetenv("DM_VPHONE_CODE_COPY");
    unsetenv("DM_VM_MAP_DIAG");

    assert(!dm_vphone_remap_compatible("off", dst, (void *)src, size, FALSE, rx, rx, rx));
    assert(protection(dst) == VM_PROT_READ);
    setenv("DM_VPHONE_CODE_COPY", "true", 1);
    assert(!dm_vphone_remap_compatible("exact-opt-in", dst, (void *)src, size, FALSE, rx, rx, rx));
    setenv("DM_VPHONE_CODE_COPY", "1", 1);
    assert(!dm_vphone_remap_compatible("private", dst, (void *)src, size, TRUE, rx, rx, rx));
    assert(!dm_vphone_remap_compatible("reported-r", dst, (void *)src, size, FALSE, rx, VM_PROT_READ, rx));
    assert(!dm_vphone_remap_compatible("unaligned", dst + 1, (void *)src, size - 1, FALSE, rx, rx, rx));
    assert(!dm_vphone_remap_compatible("empty", dst, (void *)src, 0, FALSE, rx, rx, rx));
    assert(!dm_vphone_remap_compatible("overflow", UINTPTR_MAX - 1, (void *)src, size, FALSE, rx, rx, rx));
    assert(protection(dst) == VM_PROT_READ);

    assert(vm_protect(mach_task_self(), src, size, FALSE, VM_PROT_READ) == KERN_SUCCESS);
    assert(!dm_vphone_remap_compatible("source-r", dst, (void *)src, size, FALSE, rx, rx, rx));
    assert(vm_protect(mach_task_self(), src, size, FALSE, rx) == KERN_SUCCESS);
    assert(vm_protect(mach_task_self(), dst, size, FALSE, VM_PROT_READ | VM_PROT_WRITE) == KERN_SUCCESS);
    assert(!dm_vphone_remap_compatible("target-rw", dst, (void *)src, size, FALSE, rx, rx, rx));
    unsetenv("DM_VPHONE_CODE_COPY");
    assert(!dm_vphone_remap_compatible("cross-region", dst, (void *)src, size * 2, TRUE,
        VM_PROT_READ | VM_PROT_WRITE, VM_PROT_READ | VM_PROT_WRITE, VM_PROT_ALL));
    assert(protection(dst) == (VM_PROT_READ | VM_PROT_WRITE));
    assert(protection(dst + size) == VM_PROT_READ);

    setenv("DM_VPHONE_CODE_COPY", "1", 1);
    assert(vm_protect(mach_task_self(), dst, size, FALSE, VM_PROT_READ) == KERN_SUCCESS);
    assert(dm_vphone_remap_compatible("repair", dst, (void *)src, size, FALSE, rx, rx, rx));
    assert(protection(dst) == rx);
    assert(protection(dst + size) == VM_PROT_READ);
    assert(!memcmp((void *)src, (void *)dst, size));
    assert(((int (*)(void))dst)() == 42);

    unsetenv("DM_VPHONE_CODE_COPY");
    assert(dm_vphone_remap_compatible("native-rx", dst, (void *)src, size, FALSE, rx, rx, rx));
    assert(((int (*)(void))dst)() == 42);
    assert(vm_deallocate(mach_task_self(), src, size) == KERN_SUCCESS);
    assert(vm_deallocate(mach_task_self(), dst, size * 2) == KERN_SUCCESS);
    puts("vphone remap: opt-in, rejection, region boundaries, RX copy and execution passed");
    return 0;
}
