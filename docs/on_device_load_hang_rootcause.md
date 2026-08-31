# On-device model load: the 300-second "hang" — root cause and fix

**Status:** RESOLVED. A qwen2.5-0.5B gguf now loads in ~2.2s on the vivo V2231.

## The symptom

Tapping **Load** in Config → On-device (.gguf) appeared to hang. The elapsed
counter climbed past 100s, 166s, 273s, and eventually failed with
`Operation "model loading" timed out`. No crash, no log output, near-zero CPU,
near-zero RSS growth for the whole 300 seconds.

## What it actually was

**There was never a hang.** The model loaded successfully in about three
seconds every single time. What followed was an error — `undefined symbol:
llama_model_get_vocab` — that three separate layers hid, the last of which
converted a 3-second failure into a 300-second timeout.

### Layer 1 — the log was thrown away

`Llama._initializeLlama` installs a *no-op* log callback
(`llama_log_set(llamaLogCallbackNull, ...)`) whenever `verbos` is false, and
`LlamaChild._handleLoad` constructs `Llama(...)` without ever passing `verbos`.
On top of that, llama.cpp writes to stderr, which Android discards. So
llama.cpp's own detailed load progress was unreachable through both routes.

This is why every diagnostic looked like "nothing is happening": we were blind,
not stuck. Routing the callback into Dart's `print()` (which Flutter forwards to
logcat) made the entire load visible immediately and ended the guesswork.

### Layer 2 — `dispose()` masked the real exception

`model`, `context`, and `vocab` were declared `late`. The constructor's
`catch` block calls `dispose()`, which reads `context.address`. On the failure
path `context` was never assigned, so `dispose()` threw
`LateInitializationError: Field 'context' has not been initialized` **over the
top of** the original error — the real cause was destroyed before anyone saw it.

### Layer 3 — an error was never delivered, so the caller waited out the timeout

`LlamaResponse.error` is built with `isConfirmation: false`, but
`LlamaParent._onData` only completes the pending `_operationCompleter` when
`isConfirmation` is true. A load *error* therefore completed nothing: the
`_sendCommand("model loading")` future simply sat until its 300s timeout and
reported a hang. **This is the entire mechanism behind the "hang".**

### The underlying bug — an ABI mismatch we introduced ourselves

The original SIGSEGV was fixed twice over: correctly by forcing
`nGpuLayers = 0` (the build has no GPU backend linked in), and *redundantly* by
pinning `src/llama.cpp` to commit `42ae10bb`. That pin came from the package's
own changelog, which says "0.0.8: compatible with llama.cpp 42ae10bb" — but
**0.0.9 regenerated its FFI bindings against a much newer llama.cpp and never
updated that note.** The package ships internally inconsistent guidance.

`llama_model_get_vocab` was introduced on 2025-01-12 (`afa8a9ec9`), roughly two
months *after* `42ae10bb` (2024-11-20). Our pin was older than the bindings, so
the symbol did not exist. Gemma 3 support (2025-03-12) was likewise missing,
which is why a second model failed with a different message,
`Could not load model at ...`.

Moving to `master` (2026-08) failed the other way, with a SIGSEGV on a
`DartWorker` thread, because the structs had drifted:

| | bindings expect | master has |
|---|---|---|
| `llama_model_params` | `… n_gpu_layers, split_mode, main_gpu … vocab_only, use_mmap, use_mlock, check_tensors` | `load_mode` inserted after `split_mode`; `use_mmap`/`use_mlock` **removed**; 3 new trailing fields |
| `llama_context_params` | 29 fields | same 29 plus a trailing `kv_unified` |

Every field written by the bindings landed at the wrong offset — hence the
segfault during load.

## The fix

Pin llama.cpp to **`ab1401982` (2025-07-16)**, the newest commit whose
`llama_model_params` *and* `llama_context_params` match the 0.0.9 bindings
field-for-field. It has `llama_model_get_vocab`, Gemma 3, and the still-present
`llama_load_model_from_file`.

Plus two upstream-bug patches so a future failure reports itself honestly
instead of pretending to hang:

1. `model`/`context`/`vocab` changed from `late` to `= nullptr` (with a
   `_batchInitialized` guard on `llama_batch_free`), so `dispose()` on the
   failure path no longer destroys the real exception.
2. `LlamaParent._onData` now completes `_operationCompleter` and
   `_readyCompleter` with an error when the child reports
   `LlamaStatus.error`, so load failures surface in seconds rather than at the
   300s timeout.

All of this lives in `~/.pub-cache`, **outside the repo**, so it is applied by
`scripts/setup_llama_cpp_dart.sh` (idempotent; re-run after
`dart pub cache repair` or on a new machine), followed by a clean native
rebuild.

## Hypotheses tested and ruled out

Recorded so nobody re-runs them: RAM/swap pressure (disproven by a reboot
test — our app still failed on a *smaller* model than PocketPal loaded fine on
the same freshly-booted device); storage read speed (434 MB/s measured raw,
never a bottleneck); debug vs release build (both behaved identically); model
size or vocab size; GPU backend probing (`GGML_VULKAN`/`CUDA`/`METAL` are all
`OFF` in the generated `CMakeCache.txt`, so no GPU code is even linked);
mmap vs regular read (`useMemorymap = false` changed nothing); and the OpenMP
thread-pool startup barrier (`-DGGML_OPENMP=OFF` was built, verified in
`CMakeCache.txt`, and made no difference — since reverted).

Every one of these was a guess made while the actual error message was sitting
right there, suppressed. **The lesson: restore observability before forming the
next hypothesis.** One log callback ended an investigation that eight
black-box experiments could not.

## Watch out for

- A **`Pointer.fromFunction` log callback is not safe here.** Routing
  llama.cpp's log into Dart crashed the app with a SIGSEGV in `[anon:dart-code]`
  on a `DartWorker` thread once llama.cpp logged from its own worker threads. It
  is an excellent temporary diagnostic; do not leave it installed. A permanent
  version needs `NativeCallable.listener`.
- **Do not bump `src/llama.cpp` without re-checking both param structs**
  against `lib/src/llama_cpp.dart`. A field inserted or removed produces a
  silent segfault, not a build error, because the bindings are generated code
  that nothing validates at compile time.
