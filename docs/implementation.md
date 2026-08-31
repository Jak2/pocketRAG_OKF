# Implementation — Pocket RAG / OKF

How the app actually works, from a folder of markdown on disk to a generated
answer with citations. Everything here is traceable to a symbol; where it says
`file.dart:symbol`, that is where to read next.

`decision.md` says why each of these calls was made; this document says what
they do.

---

## 1. Module layout

| Path | Responsibility |
|---|---|
| `lib/okf/` | The file format. `concept.dart` (data), `parser.dart` (frontmatter + links), `bundle.dart` (directory load, content hash, manifest), `extractors.dart` (plain text out of non-markdown files). Knows nothing about retrieval. |
| `lib/retrieval/` | Everything that turns a bundle into context. Indexes, both retrievers, the router, budgeting, the log, and the service that wires them together. |
| `lib/memory/` | `memory_fact.dart` — the fact model, the extraction prompt and parser, and the JSON store. |
| `lib/engine/` | Inference. `on_device_llama_engine.dart` and `cloud_api_engine.dart` for chat, `embedding_engine.dart` for vectors, `engine_factory.dart` to pick one. |
| `lib/agents/` | `skill_state.dart` (which skills are on, as slugs), `agent_registry.dart` (user-defined agents), `agent_logic.dart` (a markdown file parsed into persona / routing rules / tool permissions). |
| `lib/ui/` | `root_screen.dart` (two tabs, owns the service), `chat_screen.dart`, `memory_screen.dart` (pushed route), `config_screen.dart`, `onboarding_screen.dart`, `route_log_screen.dart`, `source_screen.dart`. |
| `lib/theme/` | `app_theme.dart` — two palettes, one live global, the widget helpers. See `design_theory.md` Part 3. |

The dependency direction is one-way: `ui → retrieval → okf`, with `engine`
injected into `retrieval` as function types (`Corpus.Embedder`,
`router.LlmClassifier`) rather than imported concretely, which is what keeps the
retrieval tests model-free.

`lib/agents/` sits beside that, not inside it. `knowledge_service.dart` imports
`agent_logic.dart` because it owns resolving the file, but `router.dart` does
**not** — routing rules reach it through `typedef ForcedRoute =
RetrievalMode? Function(String)` (#49), so the router tests still need nothing
but a string. `skill_state.dart` and `agent_registry.dart` are imported only by
`config_screen.dart`; see `status_open_points.md` for what that means.

---

## 2. Bundle on disk

```
<bundle root>/
  index.md
  concepts/metrics/daily-active-users.md
  concepts/runbooks/restart-ingest.md

<app documents dir>/
  okf_manifest.json         # app-local bookkeeping, not part of OKF
  okf_vectors.json          # the embedding cache
  memory.json               # durable facts
  route_log.jsonl           # one line per query
```

**Nothing is written into the user's folder.** The spec puts
`.okf-manifest.json` next to the content; this app keeps it in app storage
instead (`decision.md` #35), because a directory picked through the system
picker is not reliably writable under scoped storage and a manifest that fails
to write means re-embedding the whole bundle on every launch. The bundle
directory is read-only as far as this app is concerned.

`bundle.dart:loadBundle` walks the root recursively, sorts the files by path for
determinism, parses each, and accumulates `sha256("<relpath>:<file sha256>\n")`
per file into `Bundle.contentHash`. A file that throws on read or parse is
skipped and its path collected into the optional `skipped` list — one broken
file must not make a bundle unusable.

What it picks up is `.md` **always**, plus any extension in the `fileTools` set
it was given. `fileTools` empty — the default — is markdown only, which is the
app's original behaviour exactly.

### File tools — `okf/extractors.dart`

`extractText(file, enabled)` looks the extension up in `textExtractors`, a
`Map<String, Future<String?> Function(File)>`. Every extractor returns `null`
rather than throwing, because `loadBundle`'s contract is that one bad file never
costs the bundle.

| Extension | Extractor | What it does |
|---|---|---|
| `txt` `md` `csv` `json` | `_plainText` | `readAsString`, `null` on a decode failure (binary mislabelled as text). |
| `docx` | `_docx` | unzip → `word/document.xml` → newline per `</w:p>` → sweep `<w:t>` runs. Paragraph structure survives. |
| `pptx` | `_pptx` | unzip → every `ppt/slides/slideN.xml` in numeric order → sweep `<a:t>`. |
| `xlsx` | `_xlsx` | unzip → `xl/sharedStrings.xml` (`<t>`) → every sheet's `<c>` cells, **skipping `t="s"` cells** whose `<v>` is an index into the shared table, not text. |
| `pdf` | `_unsupportedPdf` | **returns null.** Needs a real PDF parser; not a dependency this app carries. |
| `png` `jpg` `jpeg` | `_unsupportedImage` | **returns null.** OCR needs ML Kit/Tesseract plus a platform channel. |

Decoding is `package:archive` plus a regex tag sweep, not `package:xml` and not
an Office library (#44). Only a handful of tags in OOXML carry visible text.
**The `.xlsx` ceiling is the one to know:** the output is a flat text stream with
row and column structure lost, so a citation can quote a number without the
header that gives it meaning.

A non-markdown file that extracts becomes a `Concept` with no frontmatter, the
filename-derived title `parseConcept` falls back to, and the **extension as its
`type`** — which feeds the router's corpus-type vocabulary (#19) for free. One
that extracts nothing (a PDF, an image, an empty document) lands in `skipped`
as `"<relpath>: no text extracted"`, which is what makes "the toggle is on and
this file produced nothing" visible rather than silent.

`Bundle` exposes three things the rest of the app depends on: `byPath` (identity
is `relpath`, always), `indexConcept` (the `index.md` root, the universal
last-resort seed), and `types` — the set of distinct frontmatter `type` values,
which is the router's structural-noun vocabulary.

---

## 3. Parse

`parser.dart:parseConcept` is the whole per-file pipeline.

**`splitFrontmatter`** strips a BOM, normalises CRLF, and requires the file to
start with `---\n`. An unterminated block returns the whole file as body:
treating it as frontmatter would silently drop the content, which is the worse
failure.

**`parseFrontmatter`** handles `key: value`, `key: [a, b]`, and `- item` blocks,
unquoting scalars. Unknown keys are kept verbatim in `Concept.frontmatter` —
OKF is versioned outside this codebase. Anything unparseable is skipped, never
raised.

**Title fallback:** with no frontmatter `title`, the filename is used with
hyphens turned into spaces, so title-based seeding still works on a bare
markdown file.

**`extractLinks`** matches `[anchor](href)` (optionally followed by a quoted
title), then for each href:

- a leading `#` → self-link, unresolved
- a URI scheme (`http:`, `mailto:`, …) → external, unresolved
- otherwise: strip the `#anchor`, URL-decode, join against the source file's
  directory, `p.url.normalize`, and reject anything that normalises to `..` or
  `.` — a path-traversal guard and a correctness rule in the same expression.

An unresolved link still becomes a `ConceptLink` with `targetPath == null` and
its `rawHref` kept, so dangling links are debuggable rather than invisible.
`Concept.resolvedLinks` is what the walk actually traverses.

---

## 4. Index

`corpus.dart:Corpus.build` is cheap and synchronous — no embeddings.

For each concept it:

1. Adds a row to `conceptIndex` keyed by `relpath`, with title, description,
   tags and body.
2. Splits the body with `chunker.dart:chunkText` (220 target tokens, 40
   overlap), adds each chunk to `chunkIndex` keyed by its **position in the
   `chunks` list as a string**, and appends a `Chunk` carrying `conceptPath`.

Those positional keys are load-bearing: `VectorIndex` stores `chunkIndex` as an
`int` into the same list, so lexical and dense hits are directly fusible.

**`chunkText`** splits on blank lines so a chunk is a paragraph boundary rather
than a sentence fragment. A paragraph longer than the target is hard-cut, then
resumed `overlapChars` earlier so the split point is covered twice. When a new
paragraph would overflow, the buffer is flushed and its trailing overlap is
carried into the next chunk — a fact spanning a boundary is retrievable from
either side.

**`keyword_index.dart:KeywordIndex`** is BM25 (`k1 = 1.5`, `b = 0.75`) over an
inverted `Map<term, Map<docId, tf>>`. Fields are weighted by repetition at add
time — title ×3, description ×2, tags ×2, body ×1 — which is the cheapest way to
get field weighting out of a single-field BM25. IDF is floored at zero so a term
present in every document contributes nothing rather than a negative score.
`search` takes an optional `restrictTo` set, which is what the seed cascade's
type filter uses. `tokenize` lowercases, splits on non-alphanumerics, drops
tokens of ≤2 characters and a small stopword set, and does **not** stem: on a
mixed technical corpus a stemmer merges `metric`/`metrics` but mangles
identifiers.

**`vector_index.dart:VectorIndex`** is a `List<VectorEntry>` and a cosine loop.
Entries whose dimensionality does not match the query are skipped rather than
crashing — that is the guard against a half-migrated index after an embedding
model change.

### Embedding

`Corpus.embedAll(Embedder, onProgress, shouldCancel)` walks the chunk list in
order, checking `shouldCancel` before each. A chunk that throws is skipped: it
stays retrievable through BM25, whereas aborting the pass over one bad chunk
would lose the rest. Progress is reported as `(done, total, 'embedding')`.

The `Embedder` is `embedding_engine.dart:EmbeddingEngine.embed`. That class
spawns an isolate holding a synchronous FFI `Llama` configured with
`embeddings = true`, `nPredict = 0`, `nCtx/nBatch/nUbatch = 512`, and
`nGpuLayers = 0`. Requests are `(int id, String text)` and replies are
`(id, List<double>)` or `(id, String error)`, correlated through `_pending`.
`EmbeddingEngineRegistry` keeps one engine per model path so the indexer and the
query path share a loaded model instead of each holding a copy in RAM.

### Manifest and staleness

`corpus.dart:openCorpus` is the entry point:

1. `loadBundle` → `Corpus.build` (always; lexical indexes are cheap).
2. Read the manifest file if present — the caller supplies it, and
   `knowledge_service.dart:_manifestFile` points at `okf_manifest.json` in app
   documents (#35).
3. `stale = manifest == null || manifest.isStaleFor(contentHash, embedModel,
   fileTools)` — content hash mismatch, a different embedding model name, **or**
   a different enabled file-tool set. The third one matters because enabling
   `.docx` changes what belongs in the index while nothing on disk changed:
   `BundleManifest.fileTools` records the set the index was built with, sorted by
   `normaliseFileTools` so `{pdf,docx}` and `{docx,pdf}` compare equal.
4. If not stale, try `loadVectorCache`. That validates the cached chunk list
   against the freshly built one length-wise **and text-wise**, plus
   `indices.length == vecs.length`, and returns false on any mismatch. A false
   here means re-embed; serving misaligned vectors would fail silently.
5. Return `needsEmbedding`, which is `true` when the cache did not load and the
   corpus has chunks.

Nothing in that path embeds anything. `knowledge_service.dart:reindex` is the
only thing that does, and it is called only from `root_screen.dart:_reindex`,
behind Config's "Reindex now". On success it writes `okf_vectors.json` and then
the manifest — in that order, so a crash between them leaves a stale manifest
and a re-embed, not a manifest claiming vectors that were never saved.

`KnowledgeService.open` keeps the result rather than returning it and forgetting
it: `indexStale` is a getter on the service (true when `needsEmbedding` and an
embedding model is configured), set in `open` and cleared by `reindex`, and the
chat header renders `· index stale` from it. It is owned by the service so that
one reindex clears it for every screen.

`open` is also guarded by `isOpenFor(bundlePath:, embedModelPath:, fileTools:,
agentLogicPath:)`, which is what makes anything picked in Config take effect
without an app restart and without re-reading the bundle on every rebuild — see
§9. All four are part of the open configuration: a new file tool changes what
the corpus contains, and a new logic file changes the prompt and the routing.

---

## 5. Route

`router.dart:routeQuery` is the four-stage cascade. Each stage costs strictly
more than the last and the first one with an opinion wins. A `Stopwatch` runs
across all of it and the elapsed ms lands in `RouteDecision.latencyMs`.

**Stage 0 — `forceMode`.** An optional `ForcedRoute` callback, supplied by
`KnowledgeService.prepare` as `AgentLogic.routeFor` when a logic file is loaded.
The first rule whose pattern matches the query wins — file order is precedence.
A match returns immediately with `confidence: 1` and `reason: 'agent-logic'`; a
rule resolving to `auto`, or no match at all, is "no opinion" and falls through
to stage 1. A hand-written rule beats a heuristic this app guessed (#49), and
the `reason` string means the route log measures both on the same terms.

**Stage 1 — `heuristicRoute`.** Pure, synchronous, no model; split out from
`routeQuery` so the whole table is unit-testable. Returns `null` for "no
opinion". Order matters:

| Check | Route | Confidence | `reason` |
|---|---|---|---|
| `> 25` words | vector | 0.70 | `heuristic:long-query` |
| a synthesis phrase (`summarise`, `remind me`, `did i ever`, …) | vector | 0.75 | `heuristic:synthesis` |
| a concept title appears verbatim in the query (≥12 chars or ≥3 words) | graph | 0.95 | `heuristic:title-match` |
| a definitional opener (`what is`, `define`, …) | graph | 0.80 | `heuristic:definitional` |
| a relational phrase (`depends on`, `difference between`, …) | graph | 0.75 | `heuristic:relational` |
| a query term equals a corpus `type` | graph | 0.70 | `heuristic:type-noun` |

The vector checks come first deliberately: a long descriptive query that happens
to start with "what is" is still a long descriptive query. The title check is
length-guarded so a short generic title does not match every question asked.

**Stage 2 — memory shortcut.** `memoryHit` is computed by
`knowledge_service.dart:_hasMemoryHit`: a memory chunk in the lexical top 3.
Anything looser routes half the corpus down the memory path. Memory lives in the
vector index, so a hit routes `vector`, confidence 0.70, `reason: 'memory-hit'`.

**Stage 3 — LLM classify.** Only if 1 and 2 were silent, and only if a
classifier was supplied. `classifierPromptFor` asks for exactly one word;
the reply is uppercased and matched with `startsWith('OKF')` / `startsWith('RAG')`
so a chatty model's first token still parses. Hard 800 ms timeout; any timeout
or unparseable reply falls through silently. Confidence 0.60, `reason: 'llm'`.

**Stage 4 — default.** `vector`, confidence 0.30, `reason: 'default'`.

(The cascade is five stages now; "four-stage" above describes the shape, and
stage 0 exists only when a logic file is loaded.)

`chat_screen.dart` passes `classifierEngine` **only** when the requested mode is
`auto` — the model is never loaded to classify a query the user already routed
by hand.

---

## 6. Retrieve

`retrieval_service.dart:retrieve` is the single entry point for one turn.

```
decision = requested == auto ? routeQuery(...) : RouteDecision(requested, 1.0, 'manual')
result   = run(decision.mode)
if requested == auto && _isWeak(result):
    alternative = run(other mode)
    if alternative is non-empty and not weak: use it, reason += '+fallback'
```

A manual choice is obeyed exactly, empty or not. Only Auto is second-guessed.

### Graph mode — `graph_retriever.dart:graphRetrieve`

**Seeds (`seedConcepts`)** — priority order, first non-empty wins, and the
winning stage is reported:

1. `title-exact` — every concept whose title (≥12 chars) appears verbatim in the
   lowercased query. Multiple matches all become seeds.
2. `type-filter` — if a query term equals a corpus `type`, BM25 top-3 restricted
   to concepts of that type.
3. `bm25` — plain BM25 top-3 over `conceptIndex`.
4. `index-fallback` — `index.md`, returned with `weak: true`.

Stage 4's weakness is expressed downstream by `RetrievalResult.onlyIndexMd`,
which `_isWeak` treats as a fallback trigger rather than an answer.

**The walk** is a breadth-first `Queue` of `(concept, depth)` with:

- `kMaxDepth = 2`, `kFanout = 4`
- a `visited` set keyed by `relpath`, so cycles terminate
- **whole files**, never chunks — that is the entire point of the mode
- budget rule: if `used + cost > budgetTokens`, a **depth-0 seed is truncated to
  fit** via `_truncateToTokens` and kept; anything deeper is skipped and the
  walk continues, because a smaller neighbour further out may still fit
- neighbours are `resolvedLinks` whose target exists and is unvisited, sorted by
  `linkScore` descending, `take(kFanout)`
- score on each emitted item is `1 / (position + 1)` — walk order, not relevance

`_truncateToTokens` subtracts the `[truncated to fit the context window]`
marker's own length from the budget before cutting, then prefers the last
paragraph break, then the last line break, and only hard-cuts if neither lands
past the halfway point.

`linkScore(query, anchor, targetTitle, targetDescription, targetType)` is a pure
function: term-overlap fraction against the query for anchor (×1.0), target
title (×1.0) and description (×0.5), plus 0.5 if the query names the target's
`type`. No embeddings, so ordering is testable without a model or a device.

### Vector mode — `vector_retriever.dart:vectorRetrieve`

1. BM25 top-20 over `chunkIndex`, ids parsed back to chunk positions.
2. Cosine top-20 over `vectors`, if a `queryVector` exists and the corpus has
   embeddings. Otherwise this list is empty and retrieval is BM25-only.
3. `bestLexical` = the top raw BM25 score; `bestDense` = the top raw cosine, or
   `null` when there are no embeddings. These are kept **alongside** the fused
   ranking because RRF says nothing about whether anything matched at all.
4. `reciprocalRankFusion([dense, lexical], k = 60)`.
5. **Memory boost, before the sort.** If a `MemoryBoost` callback was supplied
   (`typedef MemoryBoost = double Function(String memoryId, double score)`),
   every fused entry whose chunk carries a `memoryId` has its score replaced by
   `boostMemory(id, score)`. `KnowledgeService._boostMemory` supplies
   `memory_fact.dart:memoryScore`. Applied here rather than after ranking so the
   boost reaches the ordering and not just the number on the item (#37).
   Then sort descending.
6. **Whole-file promotion:** sum the retrieved tokens per `conceptPath`; if that
   sum is ≥ `kWholeFileThreshold` (0.6) of the concept's whole body and the body
   fits the remaining budget, emit the whole concept once and skip its other
   chunks. Otherwise emit the chunk.
7. Anything that would exceed `budgetTokens` is skipped, not truncated.

Memory chunks have `conceptPath == null`, so they never promote and always
render with `type: 'memory'` and a `memory:<id>` source.

### Weakness and fallback — `_isWeak`

| Mode | Weak when |
|---|---|
| graph | empty, or `totalTokens < kMinUsefulTokens` (200), or `onlyIndexMd` |
| vector | empty, or — if embeddings exist — `bestDense < kMinDenseScore` (0.25); otherwise `bestLexical < kMinLexicalScore` (0.5) |

Dense similarity is the better signal and wins when it exists; BM25 stands in so
that degraded, no-embedding mode still has a real notion of "nothing matched".
Neither threshold is applied to the RRF score — see `decision.md` #12.

---

## 7. Assemble

`context_assembler.dart`.

**Budget** (`retrievalBudget`):

```
retrieval = contextTokens
          - kReserveOutput (512)
          - estimateTokens(systemPrompt)
          - min(sum(estimateTokens(history)), 0.20 * contextTokens)
```

floored at 0. `contextTokens` comes from the caller —
`kOnDeviceContextTokens` for the on-device engine, 8192 for cloud.

**Memory share** (`applyMemoryShare`, vector mode only): memory items fill up to
`0.15 * budget`, then knowledge items fill the rest of the budget. If either
side is empty the result passes through untouched, so the reservation costs
nothing when there is no memory to show. The kept list is re-sorted by score to
restore the fused ranking, and `bestLexical` / `bestDense` are carried through
deliberately — dropping them would reset the weakness signals and fire a
fallback on a mixed result that matched perfectly well.

**Render** (`renderContext`): one block per item.

```
<context source="concepts/metrics/daily-active-users.md" type="metric" mode="okf">
{text}
</context>
```

**Prompt** (`buildPrompt`): system prompt, then context, then history trimmed
from the newest backwards to the 20% cap (with an explicit
`[N earlier message(s) omitted to fit]` line when anything was dropped), then
`User: …` / `Assistant:`. `kSystemPrompt` instructs the model to answer only
from the `<context>` blocks, cite `source` inline as `[source: path]`, and say
plainly when the context does not contain the answer.

**The system prompt is not always `kSystemPrompt`.** `buildPrompt` takes it as a
parameter, and `KnowledgeService.prepare` passes
`AgentLogic.systemPrompt()` when a logic file is in force: the persona followed
by a blank line followed by `kSystemPrompt`, or the persona alone when the file's
frontmatter says `prompt: replace` (#48). Whichever it is, it is the string
`retrievalBudget` charges for, so a long persona costs retrieval tokens rather
than silently overflowing the window.

Token counts everywhere are `tokens.dart:estimateTokens` — `length / 3.5`
rounded up, not a tokenizer. Every budget is a ceiling, and a conservative
overestimate costs a little context where an exact count would cost a tokenizer
round-trip per chunk.

---

## 8. Memory

`memory_fact.dart` plus the read/write wiring in `knowledge_service.dart`.

**Read path.** `_rebuildMemoryChunks` removes every chunk with a `memoryId` and
re-appends one chunk per active fact, registering each in `chunkIndex` under its
new position. Memory therefore lives in the same chunk list and the same lexical
index as knowledge — vector mode retrieves it natively, with no separate lookup.
It runs on `open()` and after every extraction.

After retrieval, `_recordMemoryHits` increments `hits` and stamps `lastUsed` on
every fact that made it into the context.

**Ranking.** `KnowledgeService.prepare` passes `_boostMemory` down through
`retrieve` into `vectorRetrieve`, which applies it to the fused score of every
memory chunk before ranking (§6, #37). `_boostMemory` looks the fact up by id in
`MemoryStore.active` and returns `memoryScore(score, fact)`; an unknown id
returns the score unchanged, so a fact retired between retrieval and boosting
degrades to no boost rather than an error. `hits` and `lastUsed` are therefore
recorded *and* read: a fact the user leans on outranks a marginally closer one
they have never touched.

**Write path.** `chat_screen.dart:_maybeExtractMemories(engine)` runs after
every completed answer and calls `extractMemories` once every `_extractEvery`
(6) turns, with a per-session `_sessionId` as the `source` (#36). It is
deliberately **not** on `dispose`: a phone kills the process without warning, so
anything deferred to teardown is a fact the app quietly forgets. The whole call
is wrapped in a `try`/`catch` that swallows — a missed extraction is invisible
to the user and must never surface as an error on a turn that succeeded.

`extractMemories(engine, conversation, sessionId)`:

1. One generation with `kMemoryExtractionPrompt` asking for 0–5 durable facts as
   a JSON array of `{text, kind}`.
2. `parseExtraction` takes the outermost `[` … `]` (models wrap JSON in prose
   and fences regardless of instructions), decodes, keeps entries with non-empty
   text, coerces `kind` through `memoryKindFrom` (unknown → `fact`), caps at 5.
   Anything that does not parse yields `[]` — a failed extraction writes nothing.
3. `_warmMemoryVectors` embeds every existing active fact once, so the dedupe
   check has something to compare against on the session's first extraction.
4. Each candidate is embedded and passed to `MemoryStore.upsert` with an
   `isDuplicate` predicate: cosine `> kDedupeThreshold` (0.92) against a cached
   fact vector, or exact lowercased text equality when no vector is available.
   A fact with no cached vector is never a duplicate — merging on a guess loses
   a genuinely new fact, the worse of the two failures.
5. A duplicate updates the existing row's `lastUsed`; anything else inserts.

**Store.** `MemoryStore` is a `List<MemoryFact>` over a JSON file, saved on
every mutation. `update` edits text/kind/active. `recordHit` bumps hits and
`lastUsed`. `decay` deactivates active facts with `hits == 0` and
`lastUsed ?? created` older than `kDecayDays` (180) — soft only, nothing is ever
hard-deleted. `load` swallows a corrupt file into an empty store rather than
blocking the app.

`decay` runs on every `KnowledgeService.open`, immediately after the store
loads. Retiring stale facts is cheap and bounded, and app open is the one moment
a session reliably reaches; a background job would be more faithful to spec §7
and buy nothing.

`memoryScore(similarity, fact)` is the recency/usage boost `_boostMemory`
applies: `similarity * (1 + 0.1 * ln(1 + hits)) * recency`, where recency is
`1 / (1 + ageDays/90)` clamped to `[0.25, 1.0]` so an old fact is demoted, not
erased.

**Audit.** `memory_screen.dart` lists every active fact with its kind and hit
count, edits text in a dialog, and toggles `active` with one tap. "Show retired"
reveals soft-deleted rows and the same tap restores them.

---

## 8b. Agent logic — `agents/agent_logic.dart`

A markdown file inside the bundle, pointed at by `EngineSettings.agentLogicPath`
(bundle-relative; empty means no file, which behaves exactly as before).

**Resolution.** `KnowledgeService.open` calls
`AgentLogicResolver.resolve(bundlePath:, logicPath:)`, which joins the two,
reads the file, parses it, and caches the result — including a cached `null`, so
a missing file is not re-stat'ed per turn. A missing, unreadable or empty-parsing
file all resolve to `null`, and `null` means "the built-in prompt and the
router's own cascade". `prepare` uses the field resolved at `open` unless a
caller passes an explicit `logic:`.

**Parsing** follows `parser.dart`'s rules deliberately: never throws, skips what
it cannot read, and swallows the body of any heading it does not recognise
rather than letting stray prose leak into the persona.

| Section heading | Aliases | Becomes |
|---|---|---|
| `Persona` | `System prompt`, `System` | `AgentLogic.persona`, prefixed to `kSystemPrompt` (#48) |
| `Routing` | `Routing rules`, `Routes` | `List<RoutingRule>`, first match wins |
| `Tools` | `Tool permissions`, `Permissions` | `Set<String>` of extensions — **parsed and inert** |

A routing line is `pattern -> mode`, also accepting `=>` or `:`, with an
optional list bullet. `pattern` is either `/a regex/` or plain text matched as a
case-insensitive substring; `mode` is `okf`/`graph`, `rag`/`vector`, or `auto`.
A line that does not parse — including a regex that does not compile — is
dropped on its own, because one bad line must not cost the other rules.

**What actually takes effect:** the persona reaches `buildPrompt` (§7), the
routing rules reach `routeQuery` as stage 0 (§5). `allowedTools` is parsed,
tested, and **wired to nothing** — no caller reads it. `status_open_points.md`
carries that as an open point rather than this document implying otherwise.

---

## 8c. Theme

`app_theme.dart` holds two `AppPalette` constants and one mutable
`_palette` global; `AppColors` is a class of static getters over it (#41).

`main()` awaits `EngineSettings.load` before `runApp` and calls
`applyThemeMode(themeMode != 'light')`, so the first frame is already correct
(#43). Config's APPEARANCE toggle writes `themeMode`, calls `applyThemeMode`,
then `ThemeScope.of(context)?.onThemeChanged()` — an `InheritedWidget` whose
only job is to `setState` the app root, because nothing below re-reads a global
on its own.

---

## 9. One turn, end to end

`chat_screen.dart:_send`:

1. `buildEngine(_settings)` — cloud or on-device; a null engine posts a "no LLM
   configured" turn and stops.
2. Append the user turn; status → `retrieving…`.
3. Build `history` from the transcript *excluding* the question just added,
   which is passed separately.
4. `KnowledgeService.prepare(question, requested, history, contextTokens,
   classifierEngine)`:
   - compute the retrieval budget
   - embed the query, if embeddings exist; a failure here degrades to BM25-only
     rather than failing the turn
   - `retrieve(...)` with `memoryHit` and the classifier
   - `_recordMemoryHits`
   - `buildPrompt(...)`
   - with no corpus at all, it returns an empty result with
     `reason: 'no-bundle'` and still builds a prompt, so the app answers as a
     plain chat model instead of refusing
5. Append the outcome to `route_log.jsonl` via `RetrievalOutcome.toLogEntry`,
   with `user_override` set when this run came from the retry button.
6. Append the assistant turn and stream `engine.generateStream(prompt)`,
   handling `GenerationStatus` / `Token` / `Done` / `Error`.
7. The mode chip and source chips render from the `RetrievalOutcome` stored on
   the turn.
8. `_maybeExtractMemories(engine)` — every sixth answered turn this harvests
   durable facts from the transcript into the memory store (§8, #36). It is the
   last thing `_send` does, after the UI has settled, and it cannot fail the
   turn.

Two screens hang off that outcome rather than off the turn loop. Tapping a
source chip pushes `source_screen.dart` with the `Concept` looked up by
relpath — frontmatter, then the raw markdown the model was actually given, not a
rendered view; its resolved links push further sources. Memory citations
(`memory:<id>`) have no file behind them and are a no-op. Config reaches
`route_log_screen.dart`, which reads the whole JSONL through `RouteLog.readAll`
and reports query count, fallback rate and override rate above the per-decision
rows.

Settings arrive through two paths, because the tabs are an `IndexedStack` and a
screen that is never rebuilt from scratch cannot notice a change in `initState`:
`_loadSettings` runs once from `initState`, and again from `didUpdateWidget`
whenever `RootScreen`'s `_configRevision` changes — which `_switchTab`
increments on leaving the Config tab. `_loadSettings` then reopens the corpus
only when `knowledge.isOpenFor(bundlePath, embedModelPath, fileTools,
agentLogicPath)` says one of those four actually changed.

`_retryAs(turn, mode)` truncates the transcript back to before the question and
re-runs `_send(turn.question, mode)`, which sets `userOverride` on the new log
line.

---

## 10. Tests

428 tests, all passing; `flutter analyze` clean.

The retrieval suite is model-free by construction — `Embedder` and
`LlmClassifier` are function types, so `test/retrieval/` builds fixture bundles
in memory and stubs both. `test/okf/parser_test.dart` covers the defensive cases
(absent block, unterminated block, BOM, CRLF, unknown keys, `../` escapes,
anchors, external schemes, dangling targets). `test/retrieval/router_test.dart`
asserts the `reason` string, not just the mode, so a rule that fires for the
wrong cause fails.

`test/retrieval/vector_retriever_boost_test.dart` covers the memory boost, and
is written around an awkward fixture honestly: the memory chunk already wins on
fused rank there, because BM25 length normalisation favours the shorter
document. Asserting only that a boosted fact ranks first would pass with the
boost deleted, so the test drives the callback in both directions — suppressing
demotes the fact, boosting keeps it on top — and separately asserts the callback
is never invoked for a concept chunk.

`test/okf/extractors_test.dart` builds real ZIPs in memory and asserts the OOXML
sweeps, including that a `t="s"` cell contributes its shared string once and not
its index. `test/agents/` covers the logic parser's degrade cases, slug filtering
on load, and the registry's dangling-active-id rule. `test/theme/palette_test.dart`
asserts both palettes define every field, that `AppColors` follows the live
palette rather than a captured value, and that `fg`/`bg` never collide in either
theme — and restores the palette in `tearDown`, because it is process-global
state.

What the suite does not cover is in `status_open_points.md`, and the gaps are
the interesting part — starting with the screens. The only widget tests in the
suite are `test/theme/`'s eight, over `appStepper`, `appActionChip` and
`DisposeWithRoute`; no screen in `lib/ui/` is ever built by a test.
