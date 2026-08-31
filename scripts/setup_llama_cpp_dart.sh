#!/usr/bin/env bash
# Patches the llama_cpp_dart 0.0.9 pub-cache checkout so on-device model
# loading works. Everything this touches lives outside the repo, so it must be
# re-run after `dart pub cache repair` or on a fresh machine.
#
# Idempotent: safe to run repeatedly.
set -euo pipefail

PKG="${PUB_CACHE:-$HOME/.pub-cache}/hosted/pub.dev/llama_cpp_dart-0.0.9"
# The commit whose llama_model_params AND llama_context_params structs match
# this package's generated FFI bindings field-for-field. Older (the 42ae10bb
# from the package changelog) lacks llama_model_get_vocab; newer reorders the
# structs, so params land at the wrong offsets and the loader segfaults.
LLAMA_COMMIT="ab1401982"

[ -d "$PKG" ] || { echo "not found: $PKG (run 'flutter pub get' first)" >&2; exit 1; }

echo "==> pinning llama.cpp to $LLAMA_COMMIT"
git -C "$PKG/src/llama.cpp" fetch --quiet origin || true
git -C "$PKG/src/llama.cpp" checkout --quiet "$LLAMA_COMMIT"

echo "==> forcing optimized native build"
python3 - "$PKG" <<'PY'
import sys, pathlib
g = pathlib.Path(sys.argv[1]) / "android/build.gradle"
s = g.read_text()
if "-O3" in s:
    print("   build.gradle already patched")
else:
    old = """        minSdkVersion 23
        targetSdkVersion 31"""
    new = """        minSdkVersion 23
        targetSdkVersion 31

        externalNativeBuild {
            cmake {
                // A debug APK builds native code with CMAKE_BUILD_TYPE=Debug,
                // i.e. -O0. llama.cpp at -O0 runs roughly 10-30x slower: on a
                // vivo V2231 that measured 0.43 tokens/sec for gemma-3-1b-Q4,
                // which reads as "the app is frozen". These flags are appended
                // after the build-type flags, and the last -O wins, so the
                // inference library stays optimized in debug builds too.
                cFlags "-O3", "-DNDEBUG"
                cppFlags "-O3", "-DNDEBUG"
            }
        }"""
    if old not in s:
        raise SystemExit("build.gradle defaultConfig not found; package version changed?")
    g.write_text(s.replace(old, new, 1))
    print("   patched android/build.gradle with -O3")
PY

echo "==> patching Dart sources"
python3 - "$PKG" <<'PY'
import sys, pathlib
pkg = pathlib.Path(sys.argv[1])

def patch(relpath, subs):
    p = pkg / relpath
    s = orig = p.read_text()
    for old, new in subs:
        if new in s:
            continue
        if old not in s:
            raise SystemExit(f"pattern not found in {relpath}; package version changed?")
        s = s.replace(old, new, 1)
    if s != orig:
        p.write_text(s)
        print(f"   patched {relpath}")
    else:
        print(f"   {relpath} already patched")

# 1. dispose() runs on the failure path and reads these fields. As `late` they
#    throw LateInitializationError over the top of the real error, hiding it.
patch("lib/src/llama.dart", [
    ("""  late Pointer<llama_model> model;
  late Pointer<llama_context> context;
  late Pointer<llama_vocab> vocab;
  late llama_batch batch;""",
     """  Pointer<llama_model> model = nullptr;
  Pointer<llama_context> context = nullptr;
  Pointer<llama_vocab> vocab = nullptr;
  late llama_batch batch;
  bool _batchInitialized = false;"""),
    ("        batch = lib.llama_batch_init(contextParams.n_batch, 0, 1);",
     "        batch = lib.llama_batch_init(contextParams.n_batch, 0, 1);\n        _batchInitialized = true;"),
    ("    lib.llama_batch_free(batch); // Free the batch",
     "    if (_batchInitialized) lib.llama_batch_free(batch);"),
])

# 2. An error from the child isolate never completes the pending operation, so
#    a load failure surfaces as a 300s timeout instead of the actual error.
patch("lib/src/isolate_parent.dart", [
    ("""    // Handle operation completion
    if (data.isDone) {""",
     """    if (data.status == LlamaStatus.error) {
      final err = LlamaException(
          data.errorDetails ?? "Unknown error in child isolate");
      if (_operationCompleter != null && !_operationCompleter!.isCompleted) {
        _operationCompleter!.completeError(err);
      }
      if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
        _readyCompleter!.completeError(err);
      }
    }

    // Handle operation completion
    if (data.isDone) {"""),
])
PY

echo "==> done. Run a clean native rebuild:"
echo "    rm -rf \"$PKG/android/.cxx\" build/llama_cpp_dart build/app/.cxx"
