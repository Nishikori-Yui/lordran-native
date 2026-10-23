// Offline profanity filtering: retain text and report no matches. The SDK
// service-backed heap is never initialized, including for virtual dispatch.
#include "hle.h"
#include <stddef.h>
#include <pthread.h>

typedef struct {
    ptrdiff_t offset_to_top;
    const void *typeinfo;
    void (*destroy)(void *);
    void (*delete_object)(void *);
    uint32_t (*version)(void *);
    Result (*check8)(void *, uint32_t *, unsigned, const char **, uint64_t);
    Result (*mask8)(void *, int *, char *, unsigned);
    Result (*check16)(void *, uint32_t *, unsigned, const uint16_t **, uint64_t);
    Result (*mask16)(void *, int *, uint16_t *, unsigned);
} filter_vtable;

static filter_vtable vtable;
static pthread_once_t vtable_once = PTHREAD_ONCE_INIT;
static void (*guest_delete)(void *);

HLE_FORCE("_ZN2nn3ngc15ProfanityFilterD1Ev", "Offline filter destruction", void, filter_destroy, void *self) {
    (void)self;
}
HLE_FORCE("_ZN2nn3ngc15ProfanityFilterD0Ev", "Offline filter deleting destructor", void, filter_delete, void *self) {
    filter_destroy(self);
    guest_delete(self);
}
HLE_FORCE("_ZN2nn3ngc15ProfanityFilter17GetContentVersionEv", "No system word list", uint32_t, filter_version, void *self) {
    (void)self; return 0;
}
HLE_FORCE("_ZN2nn3ngc15ProfanityFilter19CheckProfanityWordsEPjjPPKcm", "Offline UTF-8 word check", Result, filter_check8,
          void *self, uint32_t *out, unsigned patterns, const char **words, uint64_t count) {
    (void)self; (void)patterns; (void)words;
    for (uint64_t i = 0; out && i < count; ++i) out[i] = 0;
    return RES_OK;
}
HLE_FORCE("_ZN2nn3ngc15ProfanityFilter19CheckProfanityWordsEPjjPPKtm", "Offline UTF-16 word check", Result, filter_check16,
          void *self, uint32_t *out, unsigned patterns, const uint16_t **words, uint64_t count) {
    (void)self; (void)patterns; (void)words;
    for (uint64_t i = 0; out && i < count; ++i) out[i] = 0;
    return RES_OK;
}
HLE_FORCE("_ZN2nn3ngc15ProfanityFilter24MaskProfanityWordsInTextEPiPcj", "Offline UTF-8 masking preserves text", Result, filter_mask8,
          void *self, int *out, char *text, unsigned patterns) {
    (void)self; (void)text; (void)patterns;
    if (out) *out = 0;
    return RES_OK;
}
HLE_FORCE("_ZN2nn3ngc15ProfanityFilter24MaskProfanityWordsInTextEPiPtj", "Offline UTF-16 masking preserves text", Result, filter_mask16,
          void *self, int *out, uint16_t *text, unsigned patterns) {
    (void)self; (void)text; (void)patterns;
    if (out) *out = 0;
    return RES_OK;
}

static void filter_vtable_init(void) {
    // Preserve guest RTTI identity and allocator ownership. Do not call host
    // free on an object allocated by the game's operator new.
    const void *source = guest_sym("_ZTVN2nn3ngc15ProfanityFilterE");
    guest_delete = guest_sym("_ZdlPv");
    if (!source || !guest_delete) die("Offline filter SDK ABI symbols missing");
    memcpy(&vtable, source, offsetof(filter_vtable, destroy));
    vtable.destroy = filter_destroy;
    vtable.delete_object = filter_delete;
    vtable.version = filter_version;
    vtable.check8 = filter_check8;
    vtable.mask8 = filter_mask8;
    vtable.check16 = filter_check16;
    vtable.mask16 = filter_mask16;
}

HLE_FORCE("_ZN2nn3ngc15ProfanityFilterC1Ev", "Install offline filter virtual dispatch", void, filter_construct, void *self) {
    pthread_once(&vtable_once, filter_vtable_init);
    // Only replace the vptr; no SDK fields or caller-owned work buffer are used.
    const void *address_point = &vtable.destroy;
    memcpy(self, &address_point, sizeof address_point);
}
HLE_FORCE("_ZN2nn3ngc15ProfanityFilter10InitializeEPvmb", "No service-backed filter heap", Result, filter_init,
          void *self, void *work, uint64_t size, unsigned check) {
    (void)work; (void)size; (void)check;
    filter_construct(self);
    return RES_OK;
}
HLE_FORCE("_ZN2nn3ngc15ProfanityFilter10InitializeEPvm", "No service-backed filter heap", Result, filter_init2,
          void *self, void *work, uint64_t size) {
    return filter_init(self, work, size, 0);
}
HLE_FORCE("_ZN2nn3ngc15ProfanityFilterC1EPvmb", "Construct offline filter with caller work buffer", void, filter_construct3,
          void *self, void *work, uint64_t size, unsigned check) {
    (void)filter_init(self, work, size, check);
}
HLE_FORCE("_ZN2nn3ngc15ProfanityFilterC1EPvm", "Construct offline filter with caller work buffer", void, filter_construct2,
          void *self, void *work, uint64_t size) {
    (void)filter_init2(self, work, size);
}
HLE_FORCE("_ZN2nn3ngc15ProfanityFilter8FinalizeEv", "Offline filter owns no service resources", void, filter_finalize, void *self) {
    (void)self;
}
HLE_FORCE("_ZN2nn3ngc15ProfanityFilter11SetMaskModeENS1_8MaskModeE", "Offline filter ignores mask mode", void, filter_mode,
          void *self, int mode) { (void)self; (void)mode; }
HLE_FORCE("_ZN2nn3ngc15ProfanityFilter15SkipAtSignCheckENS1_8SkipModeE", "Offline filter ignores skip mode", void, filter_skip,
          void *self, int mode) { (void)self; (void)mode; }

#define FILTER_ALIAS(symbol, target, tag) \
    __attribute__((used, section("__DATA,swforce"))) \
    static const hle_force_ent filter_alias_##tag = {symbol, (void *)target, "Offline filter ABI alias"}
FILTER_ALIAS("_ZN2nn3ngc15ProfanityFilterC2Ev", filter_construct, ctor);
FILTER_ALIAS("_ZN2nn3ngc15ProfanityFilterC2EPvm", filter_construct2, ctor2);
FILTER_ALIAS("_ZN2nn3ngc15ProfanityFilterC2EPvmb", filter_construct3, ctor3);
FILTER_ALIAS("_ZN2nn3ngc15ProfanityFilterD2Ev", filter_destroy, dtor);
FILTER_ALIAS("_ZN2nn3ngc15ProfanityFilter19CheckProfanityWordsEPjjPPKDsm", filter_check16, check16);
FILTER_ALIAS("_ZN2nn3ngc15ProfanityFilter24MaskProfanityWordsInTextEPiPDsj", filter_mask16, mask16);
