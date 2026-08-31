# Pocket RAG / OKF — Master Prompt

Give this file to an agent (or a human) that needs full context to build, rebuild, or
extend this app without re-deriving everything from scratch.

## What this app is

An offline Android app that answers questions about a folder of interlinked markdown
notes. Three retrieval strategies over **one** corpus, with a user-facing switch:

- **RAG** — embed the query, cosine over chunks, fused with BM25. Good at fuzzy recall
  and paraphrase; bad at multi-hop and whole-document questions.
- **OKF** — walk markdown links out from seed concepts and load **whole files**. Good at
  definitions, runbooks, and relationships; bad at vague queries.
- **Auto** — route to one of the above, then fall back if the result comes back weak.

Everything runs on device. No network, no sync, no telemetry upload.

It is not a note-taking app, not a general chat app, and not an agent framework.

## OKF is a file format, not a retrieval engine

This is the single most important framing, and getting it wrong will send you down a
wrong path. An OKF bundle is a directory of markdown files with YAML frontmatter,
cross-linked with ordinary markdown links. It ships **no runtime and no index**.
`lib/okf/` parses the format; `lib/retrieval/` is this app's own consumer of it. Do not
look for an OKF library to call — there isn't one, and there isn't meant to be.

OKF v0.1 was published by Google Cloud in June 2026. Treat the current spec in the
`GoogleCloudPlatform/knowledge-catalog` repo as authoritative over anything written here,
and parse frontmatter defensively — unknown keys must never crash.

## History

This codebase was `git_agent_app`, an Android GitHub-repo assistant. The entire git layer
(`git2dart`, clone/commit/push, the GitHub API, the file tree, the file-proposal flow)
was deleted and replaced with the retrieval stack. What survived: the engine abstraction,
the settings/LLM-library/personas layer, the theme, and device metrics. If you find a
reference to repos, PATs, or `structure.md`, it is a leftover — remove it.

## Stack

- Flutter 3.47 / Dart ^3.13
- `llama_cpp_dart` 0.0.9 — on-device `.gguf` inference **and** embeddings (see gotcha below)
- `dio` — cloud LLM HTTP calls
- `crypto` — bundle content hashing
- `flutter_secure_storage` — the cloud API key
- `shared_preferences`, `file_picker`, `path_provider`, `path`, `google_fonts`
- No database. See "Deliberate simplifications".

## Module map

| Path | What |
|---|---|
| `lib/okf/` | `parser.dart` (frontmatter + links), `bundle.dart` (load, hash, manifest), `concept.dart` |
| `lib/retrieval/` | chunker, BM25 index, flat vector index, both retrievers, router, context assembly, `knowledge_service.dart` (the façade the UI talks to) |
| `lib/memory/` | durable facts, extraction, dedupe, soft-delete decay |
| `lib/engine/` | chat inference (cloud + on-device) and `embedding_engine.dart` |
| `lib/ui/` | chat, memory, config, onboarding |

## The two-model requirement

Two GGUFs, both picked in Config:

- a **chat model** for generation, and for the router's third stage;
- a **separate embedding model** (384- or 768-dim sentence transformer) for RAG mode.

They are separate because a chat model mean-pooled into a vector is a poor embedder, and
retrieval quality is the entire point of the vector path. Without an embedding model the
app still works — RAG degrades to BM25 only and the header says so.

`llama_cpp_dart` exposes `getEmbeddings` **only on the synchronous FFI `Llama` class**,
not on the isolate-based `LlamaParent` used for chat. That is why
`lib/engine/embedding_engine.dart` runs its own isolate; without one, embedding a few
thousand chunks blocks the UI thread for minutes.

## Deliberate simplifications

The spec calls for SQLite with FTS5 plus a vector store. At the target corpus size
(< 5k chunks) none of it earns its dependency:

| Spec says | This does | Ceiling |
|---|---|---|
| FTS5 virtual table | in-memory BM25 (`keyword_index.dart`) | ~5k docs, or when it stops fitting in RAM → sqflite + FTS5 behind the same `search` signature |
| `sqlite-vec` / ObjectBox | flat cosine scan (`vector_index.dart`) | ~20k chunks, or when scan time shows up in `route_log.latency_ms` → ObjectBox HNSW |
| `memory_fact` / `route_log` tables | JSON and JSONL files | when aggregate queries outgrow reading the file |

`sqlite-vec` was also avoided because it is unverified as a loadable SQLite extension on
Android. Every simplification carries a `ponytail:` comment naming its ceiling and the
upgrade path — `grep -rn 'ponytail:' lib/` before assuming any of it scales.

## Things that are not obvious from the code

- **Manual mode is never overridden.** The post-retrieval fallback only second-guesses
  the router's own choices. A switch that silently reroutes the user is worse than no
  switch.
- **The RRF score cannot measure relevance.** It is rank-only: its top score is `1/61`
  whether retrieval nailed the question or missed entirely. Weakness is judged on raw
  cosine (`bestDense`) when embeddings exist, raw BM25 (`bestLexical`) when they don't.
  Do not reintroduce a threshold on the fused score.
- **Indexing never runs automatically.** The manifest's content hash and embedding-model
  name decide staleness; a stale index surfaces "Reindex now". Embedding a bundle on a
  phone CPU is minutes and a thermal event.
- **The router's heuristics are guesses.** They came from the spec, and several are
  probably wrong for any given corpus. `route_log.jsonl` records every decision, fallback
  and user override so they can be deleted on evidence. That log, not intuition, is the
  tuning input — and if Auto turns out to add nothing over the manual switch, deleting
  Auto is a good outcome.
- **Type vocabulary is built from the corpus**, via `SELECT DISTINCT type` equivalent
  (`Bundle.types`), never hardcoded. It adapts to whatever the user authored.
- **Token counts are estimates** (`kCharsPerToken = 3.5`), not tokenizer output. Every
  budget is a ceiling, and a conservative overshoot beats a tokenizer round-trip per
  chunk on a phone.

## How to build it

```bash
export PATH="$PATH:/home/asterisk/develop/flutter/bin"   # wherever the Flutter SDK lives
flutter pub get
flutter test          # 365 tests
flutter analyze
flutter run           # or: flutter build apk --debug
```

### Required one-time setup for on-device inference

`llama_cpp_dart` vendors `llama.cpp` as a git submodule that pub.dev's archive doesn't
include, and the pub-cache copy needs two bug patches or model loading silently "hangs"
for 300 seconds (it doesn't actually hang — see `docs/on_device_load_hang_rootcause.md`).
Run once per machine, and again after any `dart pub cache repair`:

```bash
git clone https://github.com/ggml-org/llama.cpp.git \
  ~/.pub-cache/hosted/pub.dev/llama_cpp_dart-0.0.9/src/llama.cpp   # full clone, not --depth 1
bash scripts/setup_llama_cpp_dart.sh
```

### Environment gotcha

This project lives on an NTFS/exFAT mount where `chmod +x` is a no-op, so Flutter's
tooling cannot exec `android/gradlew` directly. Build via `bash android/gradlew
assembleDebug` rather than `flutter build apk` in that case.

## Where the design lives

- `okf-rag-dual-mode-spec.md` — the spec this was built from, including the parts
  deliberately not followed (see "Deliberate simplifications").
- `docs/decision.md` — the ledger: what was decided and why.
- `docs/design_theory.md` — the principles and the visual system.
- `docs/implementation.md` — how it works end to end.
- `docs/status_open_points.md` — what is done and what is genuinely unverified.
- `docs/claude-design-prompt.md` — the UI brief for a design pass.
