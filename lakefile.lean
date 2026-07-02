import Lake
open System Lake DSL

/-! # `SoplexFFI` build configuration

  This package owns the direct SoPlex binding: the vendored SoPlex
  build, the C++ bridge, and the thin Lean API in `SoplexFFI`.

  The shared LP type vocabulary (`Problem`, `Options`, `Solution`,
  `Certificate`, `SolveError`) and the pure-Lean validators live in
  `leanprover/lp-core` and are re-exported by the top-level
  `SoplexFFI` module.
-/

require LPCore from git "https://github.com/leanprover/lp-core" @ "f5a81cfad47fce9cb6b8d99484bb5da3ad27b645"

def macSdkPath : String :=
  "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"

def packageRoot : FilePath := __dir__

/-! ## Sanitizer (ASan/UBSan) opt-in.

    Pass `-Ksanitize=1` to `lake build` to instrument SoPlex, the
    bridge, and final executables consistently.
-/
def sanitizerEnabled : Bool :=
  match get_config? sanitize with
  | some s => s != "0" && s != "false"
  | none => false

def sanitizerArgs : Array String :=
  if sanitizerEnabled then
    #["-fsanitize=address", "-fsanitize=undefined",
      "-fno-sanitize=vptr,function",
      "-fno-omit-frame-pointer", "-g"]
  else
    #[]

/-- The Lean toolchain's own `lib` directory, passed by CI as
    `-KleanLibDir=...` (`$(lean --print-prefix)/lib`). Only the sanitizer
    lane needs it now (to put the toolchain `libc++` ahead of Ubuntu's
    on the `-L/usr/lib*` paths the ASan runtime link pulls in); the
    default Linux block resolves GMP from this package's own
    vendor-built `build-gmp/.libs/libgmp.a` and does not consult any
    system or toolchain `libgmp`. -/
def leanLibDirArgs : Array String :=
  match get_config? leanLibDir with
  | some d => #[s!"-L{d}"]
  | none => #[]

/-- Path to the vendored, statically-linkable, PIC `libgmp.a` produced
    by `scripts/build-gmp.sh` (see `gmpObjectsTarget`). Used at config-eval
    time to build absolute paths into the Linux link block; the path is
    a pure string concatenation, with the file's existence enforced at
    build time by the `gmpReadyFile` marker target. -/
def gmpVendorLib : FilePath :=
  packageRoot / "build-gmp" / "libgmp.a"

def soplexRuntimeLinkArgs : Array String :=
  if System.Platform.isOSX then
    #[s!"-Wl,-syslibroot,{macSdkPath}",
      "-L/opt/homebrew/lib",
      "-L/usr/local/lib",
      "-lgmpxx", "-lgmp",
      "-lc++"]
  else if System.Platform.isWindows then
    let mingwLibDir := packageRoot / "vendor" / "mingw-libs"
    -- The Lean toolchain's `crt2.o` references `_gnu_exception_handler` and
    -- `__mingw_oldexcpt_handler` — mingw-w64 CRT compatibility symbols that
    -- recent MSYS2 packages (mid-2026) stopped exporting from `libmingw32.a`,
    -- so `ld.lld` reports them as undefined when linking any Lean executable
    -- on Windows. `stageMingwLibs` compiles a tiny pass-through stub
    -- (`vendor/mingw_crt_handler_stub.c`) to `mingw_crt_handler_stub.o` and
    -- drops it next to the staged MSYS2 archives; naming it here resolves
    -- the link. See https://github.com/leanprover/soplex-ffi/issues/18 and
    -- https://github.com/leanprover/lp/issues/170.
    #["-Wl,--allow-multiple-definition",
      s!"-L{mingwLibDir}",
      (mingwLibDir / "mingw_crt_handler_stub.o").toString,
      "-Wl,--start-group",
      (mingwLibDir / "libstdc++.a").toString,
      (mingwLibDir / "libgmpxx.a").toString,
      (mingwLibDir / "libgmp.a").toString,
      "-lmingw32",
      "-lgcc_s",
      "-lmingwex",
      "-lmsvcrt",
      "-Wl,--end-group"]
  else if sanitizerEnabled then
    -- Sanitizer lane: the ASan/UBSan runtime link needs the
    -- `-L/usr/lib*` dirs to find libresolv and friends, but those dirs
    -- also hold Ubuntu's `libc++.so` and a command-line `-L` is searched
    -- before the toolchain's own lib dir. Put the toolchain `lib` dir
    -- (`-KleanLibDir`, set by CI) FIRST via `leanLibDirArgs` so `-lc++`
    -- still binds to the toolchain's libc++ — Ubuntu's libc++ 18 lacks
    -- the C++20 symbols (`std::__1::__hash_memory`, `__atomic_wait_native`)
    -- that the toolchain's `libleanrt.a` / `libleancpp.a` reference, and
    -- the wrong libc++ surfaces as "undefined symbol" link failures with
    -- `precompileModules` on v4.31. GMP is still resolved from the
    -- vendored archive (see the default-lane comment below).
    leanLibDirArgs ++
    #[gmpVendorLib.toString,
      "-Wl,--exclude-libs,libgmp.a",
      "-L/usr/lib/x86_64-linux-gnu",
      "-L/usr/lib/aarch64-linux-gnu",
      "-L/usr/lib64",
      "-L/usr/lib"] ++ sanitizerArgs
  else
    -- Default Linux lane: GMP is resolved out of the vendored, PIC,
    -- statically-built archive at `build-gmp/libgmp.a` (see
    -- `gmpObjectsTarget`), referenced by absolute path. The bridge's
    -- `__gmpz_*` and `__gmpq_*` calls bind to this single archive at
    -- link time and `--exclude-libs` hides its symbols from the dynsym
    -- table, so when `libsoplexffi.so` is dlopen'd into `lean` the
    -- dynamic loader cannot interpose any GMP symbol from Lean's
    -- bundled GMP (which would let `__gmpz_*` and `__gmpq_*` resolve
    -- against different GMP versions and crash inside `mpq_init`'s
    -- lazy mpz-field initialiser — see soplex-ffi#18). No toolchain or
    -- system `libgmp` is consulted; nothing in the link depends on
    -- which Linux distribution we run on, which version of GMP the
    -- Lean toolchain bundles, or whether either was compiled with
    -- `-fPIC`.
    --
    -- No `-L/usr/lib*` paths are added: that mirrors `lp` and
    -- `lp-backend-soplex-ffi`, and prevents Ubuntu's `libc++.so` from
    -- shadowing the toolchain's via `-lc++`. libm resolves through
    -- clang's default search dirs.
    #[gmpVendorLib.toString,
      "-Wl,--exclude-libs,libgmp.a"]

package SoplexFFI where
  moreLinkArgs := soplexRuntimeLinkArgs

def soplexObjsDir (pkgDir : FilePath) : FilePath :=
  pkgDir / defaultBuildDir / "soplex-objs"

def soplexBuildDir (pkgDir : FilePath) : FilePath :=
  pkgDir / if sanitizerEnabled then "build-soplex-sanitize" else "build-soplex"

def soplexReadyFile (pkgDir : FilePath) : FilePath :=
  soplexObjsDir pkgDir / ".ready"

def soplexBuildLockFile (pkgDir : FilePath) : FilePath :=
  soplexObjsDir pkgDir / ".build.lock"

def soplexReadyModified? (pkgDir : FilePath) : IO (Option IO.FS.SystemTime) := do
  let marker := soplexReadyFile pkgDir
  if (← marker.pathExists) then
    return some (← marker.metadata).modified
  else
    return none

def soplexReadyChangedSince (pkgDir : FilePath) (before? : Option IO.FS.SystemTime) : IO Bool := do
  match before?, (← soplexReadyModified? pkgDir) with
  | none, some _ => return true
  | some before, some after => return before != after
  | _, _ => return false

def procSilentUnlessError (args : IO.Process.SpawnArgs) : LogIO Unit := do
  let out ← rawProc args (quiet := true)
  if out.exitCode != 0 then
    logOutput out logInfo
    error s!"external command '{args.cmd}' exited with code {out.exitCode}"

def soplexSubmoduleHelp (srcDir : FilePath) : String :=
  s!"SoPlex submodule not found at {srcDir}.\n" ++
  "Run `git submodule update --init --recursive`, or clone with " ++
  "`git clone --recurse-submodules`."

def isSoplexInput (path : FilePath) : Bool :=
  match path.extension with
  | some "c" | some "cc" | some "cpp" | some "h" | some "hh" | some "hpp" => true
  | some "cmake" | some "txt" => true
  | _ => false

def soplexCxxFlags : IO String := do
  let base ← IO.getEnv "CXXFLAGS"
  let isLinux := !(System.Platform.isOSX || System.Platform.isWindows)
  let base := base.getD <| if isLinux then "-stdlib=libc++" else ""
  let san := " ".intercalate sanitizerArgs.toList
  pure <| if san.isEmpty then base else if base.isEmpty then san else base ++ " " ++ san

def soplexBuildEnv : JobM (Array (String × Option String)) := do
  let mut env : Array (String × Option String) := #[]
  if !(System.Platform.isOSX || System.Platform.isWindows) then
    if (← IO.getEnv "CC").isNone then
      env := env.push ("CC", some "clang")
    if (← IO.getEnv "CXX").isNone then
      env := env.push ("CXX", some "clang++")
  let cxxFlags ← soplexCxxFlags
  if !cxxFlags.isEmpty then
    env := env.push ("CXXFLAGS", some cxxFlags)
  pure env

/-! ## Vendored GMP build.

  GMP is built from the upstream tarball into `<pkgDir>/build-gmp/` by
  `scripts/build-gmp.sh`. The script handles download (with SHA-256
  verification), extraction, `./configure --with-pic --disable-shared
  --enable-static`, and `make`. The resulting `build-gmp/.libs/libgmp.a`
  is linked into `libsoplexffi.so` by absolute path
  (`soplexRuntimeLinkArgs`), so the bridge never picks up any system or
  toolchain `libgmp`. This sidesteps two problems in one go:

  * GMP-version interposition when the bridge is dlopen'd into `lean`
    (soplex-ffi#18) — the vendored archive provides a single, hidden
    GMP across the whole `libsoplexffi.so`.

  * Non-PIC objects in system / toolchain `libgmp.a` on x86_64 — the
    vendored build is forced PIC, so `ld.lld` never sees an
    `R_X86_64_PC32` relocation that can't appear in a shared object.

  Only Linux uses the vendored build. macOS keeps `-lgmp` (Homebrew
  GMP, dynamic, no flat-namespace interposition issue) and Windows
  keeps the staged MSYS2 `libgmp.a` (always PIC by MSYS2 convention). -/

def gmpBuildDir (pkgDir : FilePath) : FilePath :=
  pkgDir / "build-gmp"

def gmpReadyFile (pkgDir : FilePath) : FilePath :=
  gmpBuildDir pkgDir / ".ready"

def gmpLibFile (pkgDir : FilePath) : FilePath :=
  gmpBuildDir pkgDir / "libgmp.a"

/-- Bumping this forces a clean rebuild via the target's pure trace. The
    SHA-256 baked into `scripts/build-gmp.sh` must match. -/
def gmpVersion : String := "6.3.0"

def buildGmpObjects (pkgDir : FilePath) : JobM Unit := do
  IO.FS.createDirAll (gmpBuildDir pkgDir)
  let buildScript := pkgDir / "scripts" / "build-gmp.sh"
  if !(← buildScript.pathExists) then
    error s!"build-gmp script not found at {buildScript}"
  procSilentUnlessError {
    cmd := buildScript.toString,
    args := #[pkgDir.toString],
    cwd := some pkgDir,
    env := #[("GMP_VERSION", some gmpVersion)]
  }
  if !(← gmpLibFile pkgDir |>.pathExists) then
    error s!"GMP build did not produce {gmpLibFile pkgDir}"

private def gmpObjectsTarget (pkg : Package) : FetchM (Job FilePath) := do
  let buildScriptPath := pkg.dir / "scripts" / "build-gmp.sh"
  let srcTarget ← inputTextFile buildScriptPath
  buildFileAfterDep (gmpReadyFile pkg.dir) srcTarget fun _ => do
    addPlatformTrace
    addPureTrace gmpVersion "gmp-version"
    buildGmpObjects pkg.dir

def stageMingwLibs (pkgDir : FilePath) : JobM Unit := do
  if System.Platform.isWindows then
    let some mingwPrefix ← IO.getEnv "MINGW_PREFIX"
      | error "MINGW_PREFIX is not set; run Lake from an MSYS2 MINGW64 shell."
    let srcDir := FilePath.mk mingwPrefix / "lib"
    let outDir := pkgDir / "vendor" / "mingw-libs"
    IO.FS.createDirAll outDir
    for lib in #[
      "libstdc++.a", "libstdc++.dll.a",
      "libgmp.a", "libgmp.dll.a", "libgmpxx.a", "libgmpxx.dll.a",
      "libgcc_s.a", "libwinpthread.a", "libwinpthread.dll.a",
      "libmingw32.a", "libmingwex.a", "libmsvcrt.a", "libmsvcrt-os.a",
      "libstdc++exp.a", "libstdc++fs.a"
    ] do
      let src := srcDir / lib
      if (← src.pathExists) then
        proc {cmd := "cp", args := #[src.toString, (outDir / lib).toString]}
    for lib in #["libstdc++.a", "libgmpxx.a", "libgmp.a", "libmingw32.a"] do
      if !(← (outDir / lib).pathExists) then
        error s!"missing required MSYS2 archive: {srcDir / lib}"
    -- Compile the mingw-w64 CRT compatibility stub (see
    -- `vendor/mingw_crt_handler_stub.c`). The Lean toolchain's `crt2.o` still
    -- references `_gnu_exception_handler` and `__mingw_oldexcpt_handler`,
    -- which recent MSYS2 packages no longer export from `libmingw32.a`.
    let stubSrc := pkgDir / "vendor" / "mingw_crt_handler_stub.c"
    let stubObj := outDir / "mingw_crt_handler_stub.o"
    if !(← stubSrc.pathExists) then
      error s!"missing CRT compatibility stub source: {stubSrc}"
    proc {cmd := "clang",
          args := #["-c", "-O2", stubSrc.toString, "-o", stubObj.toString]}
    if !(← stubObj.pathExists) then
      error s!"CRT compatibility stub did not compile to {stubObj}"

def removeOldSoplexObjs (dir : FilePath) : IO Unit := do
  if (← dir.pathExists) then
    for e in (← dir.readDir) do
      let n := e.fileName
      if n.endsWith ".o" || n.endsWith ".obj" then
        IO.FS.removeFile e.path

def listObjectFiles (dir : FilePath) : IO (Array FilePath) := do
  let entries ← dir.readDir
  let mut out : Array FilePath := #[]
  for e in entries do
    let n := e.fileName
    if n.endsWith ".o" || n.endsWith ".obj" then
      out := out.push e.path
  pure out

def ensureSoplexSubmodule (pkgDir : FilePath) : JobM Unit := do
  let srcDir := pkgDir / "vendor" / "soplex"
  let cmakeFile := srcDir / "CMakeLists.txt"
  if !(← cmakeFile.pathExists) then
    let gitmodules := pkgDir / ".gitmodules"
    if (← gitmodules.pathExists) then
      logVerbose "SoPlex submodule missing; running `git submodule update --init --recursive`."
      procSilentUnlessError {
        cmd := "git",
        args := #["submodule", "update", "--init", "--recursive"],
        cwd := some pkgDir
      }
  if !(← cmakeFile.pathExists) then
    logWarning <| soplexSubmoduleHelp srcDir
    error <| soplexSubmoduleHelp srcDir

def buildSoplexObjects (pkgDir : FilePath) : JobM Unit := do
  let readyBefore? ← soplexReadyModified? pkgDir
  -- Lake may replay this target's log through multiple dependents. The lock
  -- keeps any duplicate jobs from rerunning CMake after one has produced
  -- fresh objects for the same build wave.
  Lake.withLockFile (soplexBuildLockFile pkgDir) do
  if (← soplexReadyChangedSince pkgDir readyBefore?) then
    return
  ensureSoplexSubmodule pkgDir
  let srcDir := pkgDir / "vendor" / "soplex"
  stageMingwLibs pkgDir
  let buildDir := soplexBuildDir pkgDir
  let objsDir := soplexObjsDir pkgDir
  IO.FS.createDirAll objsDir
  let env ← soplexBuildEnv
  let cmakeArgs := #[
    "-S", srcDir.toString,
    "-B", buildDir.toString,
    "-DCMAKE_BUILD_TYPE=Release",
    "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
    "-DBOOST=ON",
    "-DGMP=ON",
    "-DPAPILO=OFF",
    "-DMPFR=OFF",
    "-DBUILD_TESTING=OFF",
    "-DZLIB=OFF"
  ]
  procSilentUnlessError {cmd := "cmake", args := cmakeArgs, cwd := some pkgDir, env := env}
  let buildArgs := #["--build", buildDir.toString, "--target", "libsoplex", "--parallel"]
  procSilentUnlessError {cmd := "cmake", args := buildArgs, cwd := some pkgDir, env := env}
  let lib := buildDir / "lib" / "libsoplex.a"
  if !(← lib.pathExists) then
    error s!"SoPlex archive was not produced at {lib}"
  removeOldSoplexObjs objsDir
  proc {cmd := (← getLeanAr).toString, args := #["x", lib.toString], cwd := some objsDir}
  let objs ← listObjectFiles objsDir
  if objs.size < 5 then
    error s!"expected SoPlex archive to contain many objects, found {objs.size}"
  IO.FS.writeFile (soplexReadyFile pkgDir) "ready\n"

def listSoplexObjs (pkgDir : FilePath) : IO (Array FilePath) := do
  let dir := soplexObjsDir pkgDir
  let marker := soplexReadyFile pkgDir
  if !(← marker.pathExists) then
    throw <| IO.userError <|
      s!"SoPlex objects were not built at {dir}."
  listObjectFiles dir

private def soplexObjectsTarget (pkg : Package) : FetchM (Job FilePath) := do
  let srcDir := pkg.dir / "vendor" / "soplex"
  let cmakeFile := srcDir / "CMakeLists.txt"
  let srcTarget ←
    if (← cmakeFile.pathExists) then
      inputDir srcDir (text := false) isSoplexInput
    else
      (← inputTextFile (pkg.dir / ".gitmodules")).mapM fun p => pure #[p]
  buildFileAfterDep (soplexReadyFile pkg.dir) srcTarget fun _ => do
    addPlatformTrace
    addPureTrace sanitizerEnabled "sanitize"
    buildSoplexObjects pkg.dir

def bridgeSrcs : Array String := #["lean_soplex.cpp", "lean_soplex_bridge.cpp"]

def systemIncludeArgs : Array String :=
  if System.Platform.isOSX then
    #["-I/opt/homebrew/include", "-I/usr/local/include"]
  else if System.Platform.isWindows then
    #["-IC:/msys64/mingw64/include"]
  else
    #["-I/usr/include"]

def bridgeCxxDriver : String :=
  if System.Platform.isOSX ∨ System.Platform.isWindows then "c++" else "clang++"

def bridgeStdlibArgs : Array String :=
  if System.Platform.isOSX ∨ System.Platform.isWindows then #[]
  else #["-stdlib=libc++"]

private def bridgeOTarget (pkg : Package) (soplexReady : Job FilePath) (src : String) :
    FetchM (Job FilePath) := do
  let stem := src.dropEnd 4
  let oFile := pkg.dir / defaultBuildDir / "ffi" / s!"{stem}.o"
  let srcTarget ← inputTextFile <| pkg.dir / "ffi" / src
  let deps := Job.collectArray #[srcTarget, soplexReady] "bridge inputs"
  buildFileAfterDep oFile deps fun depFiles => do
    let srcFile := depFiles[0]!
    let leanInc        := (← getLeanIncludeDir).toString
    let ffiInc         := (pkg.dir / "ffi").toString
    let soplexSrcInc   := (pkg.dir / "vendor" / "soplex" / "src").toString
    let soplexBuildInc := (soplexBuildDir pkg.dir).toString
    compileO oFile srcFile (#[
      "-O2", "-fPIC", "-std=c++17",
      "-I", leanInc,
      "-I", ffiInc,
      "-I", soplexSrcInc,
      "-I", soplexBuildInc
    ] ++ bridgeStdlibArgs ++ systemIncludeArgs ++ sanitizerArgs) bridgeCxxDriver

extern_lib soplexffi (pkg) := do
  let name := nameToStaticLib "soplexffi"
  let outLib := pkg.staticLibDir / name
  let soplexReady ← soplexObjectsTarget pkg
  let bridgeOJobs ← bridgeSrcs.mapM (bridgeOTarget pkg soplexReady)
  let bridgeOsJob := Job.collectArray bridgeOJobs "bridge objs"
  -- The static lib must relink whenever the SoPlex objects OR a bridge `.o`
  -- changes. `buildArtifactUnlessUpToDate` keys on the ambient job trace
  -- (`getTrace`), so the artifact job must depend on the bridge objects too —
  -- mapping over `soplexReady` alone left the `.a` stale when only a bridge
  -- source changed (the `.o` rebuilt but the archive was replayed from cache).
  --
  -- The vendored GMP build is wired in as an additional input on Linux so
  -- that `build-gmp/.libs/libgmp.a` exists by the time Lake links
  -- `libsoplexffi.so` (whose `moreLinkArgs` names it by absolute path). On
  -- macOS / Windows the dependency is harmless: `buildGmpObjects` is only
  -- consulted there if a build of the Linux link path is requested.
  let isLinux := !(System.Platform.isOSX || System.Platform.isWindows)
  let extraDeps ←
    if isLinux then do let g ← gmpObjectsTarget pkg; pure #[g] else pure #[]
  let inputsJob :=
    Job.collectArray (#[soplexReady] ++ bridgeOJobs ++ extraDeps) "soplexffi inputs"
  inputsJob.mapM fun _ => do
    let soplexOs ← listSoplexObjs pkg.dir
    let bridgeOs ← bridgeOsJob.await
    let art ← buildArtifactUnlessUpToDate outLib (ext := "a") (restore := true) do
      compileStaticLib outLib (soplexOs ++ bridgeOs) (← getLeanAr)
    return art.path

@[default_target]
lean_lib SoplexFFI where
  roots := #[`SoplexFFI]
  globs := #[`SoplexFFI, `SoplexFFI.Basic]
  precompileModules := !sanitizerEnabled
  moreLinkArgs := soplexRuntimeLinkArgs

/-- End-to-end FFI runtime check (SoPlex version, throw/catch ABI,
    small LP solve). Doubles as the `lake test` driver. -/
@[test_driver]
lean_exe «ffi-check» where
  root := `Main

/-- Marshalling benchmark (`lake exe bench [n]`); see `Bench.lean`. -/
lean_exe bench where
  root := `Bench

/-- In-elaborator FFI smoke check; see `Tests/InElaborator.lean`. The
    executable test driver (`ffi-check`) links the bridge statically,
    so it cannot catch regressions that only surface when
    `libsoplexffi.so` is dlopen'd into `lean`. Building this lib runs
    the bridge inside the elaborator, matching the usage shape that
    downstream consumers (notably `by lp`) hit. Kept out of the
    sanitizer lane because precompiled-module elaboration with
    sanitizers is not the configuration the regression hides in;
    `precompileModules := false` to match the toolchain mode the
    crash reproduces under. -/
lean_lib InElaboratorTest where
  roots := #[`Tests.InElaborator]
  globs := #[`Tests.InElaborator]
  precompileModules := !sanitizerEnabled
