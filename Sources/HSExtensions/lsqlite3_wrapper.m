// Wrapper that compiles lsqlite3.c as Objective-C so it can include
// <LuaSkin/LuaSkin.h> (which transitively imports Cocoa). The original
// extension's Xcode target tagged lsqlite3.c with explicitFileType
// sourcecode.c.objc; SPM doesn't have per-file file-type overrides so we
// re-include the file from a .m so clang treats the translation unit as
// Objective-C.
#include "sqlite3/lsqlite3.c"
