// AUTO-GENERATED. DO NOT EDIT. Re-run scripts/generate-hsextensions.sh.
//
// Purpose: prevent the static linker from dead-stripping the luaopen_hs_*
// entry points out of libHSExtensions.a. Each symbol is referenced from a
// __used array so the linker keeps the archive object alive.
#import <HSExtensions/HSExtensions+Preload.h>

__attribute__((used))
static void * const _HSExtensionsKeepAlive[] = {
    (void *)&luaopen_hs_libbase64,
    (void *)&luaopen_hs_libmath,
    (void *)&luaopen_hs_libwindow,
};
