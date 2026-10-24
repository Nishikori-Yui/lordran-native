#include "../hle_ngc.c"
#include <assert.h>
#include <stdarg.h>

static int deleted;
static void *deleted_object;
static const uintptr_t sdk_vtable[] = {0, 0x12345678};
static void fake_delete(void *object) { deleted++; deleted_object = object; }
void *guest_sym(const char *name) {
    if (!strcmp(name, "_ZTVN2nn3ngc15ProfanityFilterE")) return (void *)sdk_vtable;
    if (!strcmp(name, "_ZdlPv")) return (void *)fake_delete;
    assert(0); return NULL;
}

static void *construct(void *arg) { filter_construct(arg); return NULL; }

int main(void) {
    _Static_assert(offsetof(filter_vtable, destroy) == 16, "Itanium address point");
    _Static_assert(sizeof(filter_vtable) == 9 * sizeof(void *), "SDK seven-slot vtable");
    _Alignas(16) unsigned char objects[8][64];
    memset(objects, 0xa5, sizeof objects);
    pthread_t threads[8];
    for (int i = 0; i < 8; ++i) assert(!pthread_create(&threads[i], NULL, construct, objects[i]));
    for (int i = 0; i < 8; ++i) assert(!pthread_join(threads[i], NULL));
    void **vt = *(void ***)objects[0];
    assert(vt[-2] == NULL && vt[-1] == (void *)sdk_vtable[1]);
    for (int i = 0; i < 8; ++i) {
        assert(*(void ***)objects[i] == vt);
        for (size_t j = sizeof(void *); j < sizeof objects[i]; ++j) assert(objects[i][j] == 0xa5);
    }
    assert(((uint32_t (*)(void *))vt[2])(objects[0]) == 0);
    char text8[] = "offline player";
    uint16_t text16[] = {0x73a9, 0x5bb6, 0xd83d, 0xde00, 0};
    uint16_t original16[5]; memcpy(original16, text16, sizeof text16);
    uint32_t masks[] = {99, 99, 99};
    assert(((Result (*)(void *, uint32_t *, unsigned, const char **, uint64_t))vt[3])
           (objects[0], masks, ~0u, NULL, 2) == RES_OK);
    assert(masks[0] == 0 && masks[1] == 0 && masks[2] == 99);
    masks[0] = masks[1] = 99;
    assert(((Result (*)(void *, uint32_t *, unsigned, const uint16_t **, uint64_t))vt[5])
           (objects[0], masks, ~0u, NULL, 2) == RES_OK);
    assert(masks[0] == 0 && masks[1] == 0 && masks[2] == 99);
    int count = 99;
    assert(((Result (*)(void *, int *, char *, unsigned))vt[4])(objects[0], &count, text8, ~0u) == RES_OK);
    assert(!count && !strcmp(text8, "offline player"));
    count = 99;
    assert(((Result (*)(void *, int *, uint16_t *, unsigned))vt[6])(objects[0], &count, text16, ~0u) == RES_OK);
    assert(!count && !memcmp(original16, text16, sizeof text16));
    Result (*mask_alias)(void *, int *, uint16_t *, unsigned) = filter_alias_mask16.fn;
    count = 99;
    assert(mask_alias(objects[0], &count, text16, ~0u) == RES_OK && !count);
    assert(filter_mask16(objects[0], NULL, NULL, 0) == RES_OK);
    assert(filter_check16(objects[0], NULL, 0, NULL, 0) == RES_OK);
    unsigned char work[16]; memset(work, 0x5a, sizeof work);
    filter_construct2(objects[1], work, sizeof work);
    filter_construct3(objects[2], work, sizeof work, 1);
    assert(filter_init2(objects[0], work, sizeof work) == RES_OK);
    for (size_t i = 0; i < sizeof work; ++i) assert(work[i] == 0x5a);
    filter_mode(objects[0], 1); filter_skip(objects[0], 1);
    filter_finalize(objects[0]); filter_finalize(objects[0]);
    ((void (*)(void *))vt[0])(objects[0]);
    assert(!deleted);
    ((void (*)(void *))vt[1])(objects[0]);
    assert(deleted == 1 && deleted_object == objects[0]);
    puts("offline filter: lifecycle, seven virtual slots, ABI aliases and concurrent construction passed");
    return 0;
}
