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
 * `EXCEPTION_CONTINUE_SEARCH` (== 0) lets unhandled exceptions fall
 * through to the OS default handler. `__mingw_oldexcpt_handler` is a
 * backup of the previous SetUnhandledExceptionFilter result; leaving it
 * null is safe.
 *
 * This stub is compiled with the Lean toolchain's `clang` (which does
 * not have MSYS2 headers on its search path), so it deliberately avoids
 * `#include <windows.h>` — it declares only what the linker needs to
 * see and matches the WIN64 ABI (where `WINAPI` is a no-op).
 *
 * Compiled by `stageMingwLibs` in lakefile.lean during the Windows
 * build and dropped next to the staged MSYS2 archives in
 * `vendor/mingw-libs/`. The link-args block in this package and the
 * mirror copies in `leanprover/lp-backend-soplex-ffi` and
 * `leanprover/lp` name the resulting `.o` so the link resolves the two
 * `crt2.o` references.
 */

/* `PEXCEPTION_POINTERS` is a pointer-to-struct; an opaque `void*`
   matches the ABI for argument passing. `LONG` is `long` on every
   mingw-w64 target. */
void *__mingw_oldexcpt_handler = 0;

long _gnu_exception_handler(void *info) {
    (void)info;
    return 0L; /* EXCEPTION_CONTINUE_SEARCH */
}
