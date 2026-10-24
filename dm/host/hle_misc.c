// Offline services referenced by the Dark Souls modules: shop, error applet,
// profanity filter and server name resolution. Software keyboard: hle_swkbd.c.
#include "hle.h"

// Return from the unavailable shop applet as though the player closed it.
HLE_FORCE("_ZN2nn2ec30ShowShopApplicationInformationENS_13ApplicationIdE", "商店小程序，排除范围；剪口：空操作", void, h_ec_AppInfo1, void) { LOG("ec::ShowShopApplicationInformation unavailable; host has no shop service"); }

// ---------- err error applet: printed by the host ----------
HLE_FORCE("_ZN2nn3err9ShowErrorENS_6ResultE", "错误显示小程序；宿主打印模块 / 描述号", void, h_err_ShowError, Result r) {
    LOG("Guest error display requested: result=%#x module=%u description=%u", r, r & 0x1ff, (r >> 9) & 0x1fff);
}

// Server name resolution is unavailable in the offline port.
HLE_FORCE("_ZN2nn3nsd9ResolveExEPNS0_4FqdnERKS1_", "服务器名解析，联网排除；剪口", Result, h_nsd_ResolveEx, void *out, const void *in) { (void)out; (void)in; return RES_FAIL; }
