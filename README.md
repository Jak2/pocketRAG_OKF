# Pocket RAG / OKF

An offline Android app that answers questions about a folder of interlinked markdown
notes. Two retrieval strategies over **one** corpus, with a switch and an auto-router.

| Mode | Mechanism | Good at |
|---|---|---|
| `RAG` | embed the query, cosine over chunks, fused with BM25 | fuzzy recall, paraphrase, "something about X" |
| `OKF` | walk markdown links from the seed concepts, load **whole files** | definitions, runbooks, relationships, structure |
| `Auto` | route to one of the above, with post-retrieval fallback | the default |

Everything runs on device. No network, no sync, no telemetry upload.

## OKF is a file format, not a retrieval engine

An OKF bundle is a directory of markdown files with YAML frontmatter, cross-linked with
ordinary markdown links. It ships no runtime and no index. `lib/okf/` parses that format;
`lib/retrieval/` is this app's own consumer of it. Both modes read the same bundle —
there is never a second corpus.

```
<bundle>/
  index.md
  concepts/metrics/daily-active-users.md
  concepts/runbooks/restart-ingest.md
```

Nothing is written into that folder. The manifest (`okf_manifest.json`), the
vector cache, memory and the route log all live in the app's own documents
directory — a picked folder is not reliably writable under scoped storage.

## Layout

| Path | What |
|---|---|
| `lib/okf/` | frontmatter + link parser, bundle loader, manifest, non-markdown text extractors |
| `lib/retrieval/` | chunker, BM25 index, flat vector index, both retrievers, router, context assembly |
| `lib/memory/` | durable facts extracted from conversations, with soft-delete and user audit |
| `lib/engine/` | chat inference (`llama_cpp_dart` / cloud) and the separate embedding isolate |
| `lib/agents/` | enabled skills (as slugs), user-defined agents, and the agent-logic markdown parser |
| `lib/ui/` | chat, memory, config, onboarding, routing log, source viewer |
| `lib/theme/` | two palettes (dark/light), the live-palette global, and the shared widget helpers |
| `design/` | the Claude Design canvas the current UI came from — reference, not a build input |

## Beyond markdown — file tools

Config's **File tools** section lets the indexer read more than `.md`. Working today:
`.txt`, `.csv`, `.json`, `.docx`, `.pptx`, `.xlsx` — the OOXML formats are unzipped with
`package:archive` and swept for the handful of tags that carry visible text, rather than
pulling in an Office library.

**`.pdf` and images are not supported.** Both are listed in Config, greyed, labelled
"not supported offline", and cannot be switched on: PDF needs a real parser and image
text needs OCR with a native dependency, neither of which this app carries. A toggle
that silently indexed nothing would be worse than the visible gap.

Two caveats worth knowing before pointing it at a folder:

- `.xlsx` extraction is a flat text stream — row and column structure is lost, so a
  citation can quote a number without its header.
- The enabled set is recorded in the manifest, so switching a format on marks the index
  stale even though nothing on disk changed. Reindex, as usual, is explicit.

## Look and feel

The UI comes from a Claude Design canvas, checked in at `design/Pocket RAG.dc.html`:
near-black or near-white ground, hairline borders, no shadows, pill controls, one blue
accent, Inter for prose and JetBrains Mono for anything machine-generated. **Dark and
light both ship** — the toggle is in Config under Appearance and the choice is persisted,
resolved before the first frame so a light-theme user never sees a dark flash on launch.

`docs/design_theory.md` Part 3 documents the system, including the parts of the old
one still standing.

## Agents, skills and agent logic

- **Agent logic** — point Config at a markdown file inside the bundle and its `Persona`
  section is prefixed to the built-in system prompt (never replacing it, unless the file
  says `prompt: replace`, so the citation rules survive), and its `Routing` section
  becomes hand-written rules that run ahead of the router's own heuristics and are logged
  as `reason: 'agent-logic'`.
- **Skills and custom agents** are persisted and editable in Config, and currently change
  nothing about generation. `docs/status_open_points.md` 7–8 says exactly what is wired
  and what is not — read it before assuming a toggle does something.

## Deliberate simplifications

The spec calls for SQLite with FTS5 and a vector store. At the target corpus size
(< 5k chunks) neither earns its dependency, so:

- **BM25 is an in-memory inverted index** (`lib/retrieval/keyword_index.dart`), not FTS5.
- **Vector search is a flat cosine scan** (`lib/retrieval/vector_index.dart`), not
  `sqlite-vec` (unverified as a loadable extension on Android) or ObjectBox.
- **Memory and the routing log are JSON/JSONL files**, not tables.

Each is marked with a `ponytail:` comment naming its ceiling and the upgrade path.
Grep for `ponytail:` before assuming any of it scales.

## Building

```bash
export PATH="$PATH:/home/asterisk/develop/flutter/bin"
flutter pub get
flutter test
flutter run                       # or: bash android/gradlew assembleDebug on NTFS/exFAT
```

### One-time setup for on-device inference

`llama_cpp_dart` vendors `llama.cpp` as a git submodule that pub.dev's archive omits, and
the pub-cache copy needs two patches or model loading appears to hang for 300 seconds
(see `docs/on_device_load_hang_rootcause.md`). Once per machine:

```bash
git clone https://github.com/ggml-org/llama.cpp.git \
  ~/.pub-cache/hosted/pub.dev/llama_cpp_dart-0.0.9/src/llama.cpp
bash scripts/setup_llama_cpp_dart.sh
```

## Models

Two GGUFs, both picked in Config:

- a **chat model** for generation (and for the router's third stage), and
- a **separate embedding model** (384- or 768-dim sentence transformer) for RAG mode.

A chat model mean-pooled into a vector is a poor embedder, which is why the embedding
model is separate rather than reused. Without one the app still works — RAG mode degrades
to BM25 only, and says so in the header.

## Indexing

Never automatic. The manifest's content hash and embedding-model name decide whether the
built index is stale; a stale index surfaces "Reindex now" in Config. Embedding a few
thousand chunks on a phone CPU is minutes, not seconds, so it is explicit, progress-
reporting and cancellable.

## Why the mode chip matters

Every answer carries the routing decision: which mode ran, why, its confidence, its
latency, and whether a fallback fired — plus a one-tap "wrong mode, retry as X" that
records the override. Those overrides and fallbacks land in `route_log.jsonl`, on device.
After a couple of hundred real queries that file, not intuition, says which heuristics in
`lib/retrieval/router.dart` to keep. If Auto turns out to add nothing over the manual
switch, deleting it is a good outcome.

See `okf-rag-dual-mode-spec.md` for the full design, `docs/claude-design-prompt.md` for
the UI brief and `design/Pocket RAG.dc.html` for the canvas that answered it.
# pocketRAG_OKF
