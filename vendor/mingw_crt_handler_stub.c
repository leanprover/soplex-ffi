/*
 * MinGW CRT compatibility stub for MSYS2 runner drift.
 *
 * The Lean toolchain (v4.31.0-rc1, Windows) ships a `crt2.o` startup
 * object built against an older mingw-w64 where `_gnu_exception_handler`
 * and `__mingw_oldexcpt_handler` were exported by `libmingw32.a`.
 * Recent MSYS2 packages no longer export those symbols (upstream made
 * `_gnu_exception_handler` a static function in `crtexe.c`), so linking
 * any Lean-built executable on Windows now fails with:
 *
 *   ld.lld: error: undefined symbol: _gnu_exception_handler
 *   ld.lld: error: undefined symbol: __mingw_oldexcpt_handler
 *
 * See https://github.com/leanprover/soplex-ffi/issues/18 and
 * https://github.com/leanprover/lp/issues/170.
 *
 * Pass-through definitions are enough: `_gnu_exception_handler` was the
 * mingw-w64 SEH-to-POSIX-signal translator; returning
 * `EXCEPTION_CONTINUE_SEARCH` lets unhandled exceptions fall through to
 * the OS default handler, which is the right behaviour for downstream
 * consumers that do not install their own handlers. `__mingw_oldexcpt_handler`
 * is a backup of the previous SetUnhandledExceptionFilter result that
 * the CRT only uses if it runs the old handler's tail; it is safe to
 * leave NULL.
 *
 * This file is compiled by `stageMingwLibs` in lakefile.lean during the
 * Windows build and dropped next to the staged MSYS2 archives in
 * `vendor/mingw-libs/`. The link-args block in this package and in the
 * mirror copies in `leanprover/lp-backend-soplex-ffi` and `leanprover/lp`
 * names the resulting `.o` so the link resolves the two crt2.o symbols.
 */

#include <windows.h>

LPTOP_LEVEL_EXCEPTION_FILTER __mingw_oldexcpt_handler = NULL;

LONG WINAPI _gnu_exception_handler(EXCEPTION_POINTERS *info) {
    (void)info;
    return EXCEPTION_CONTINUE_SEARCH;
}
