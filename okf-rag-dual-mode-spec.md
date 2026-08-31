# Implementation Spec: Dual-Mode Retrieval (RAG / OKF / Auto) + Persistent Memory

**Audience:** Claude Code, working inside an existing offline Android LLM app.
**Author context:** This spec was written without access to the codebase. Every section
marked `INSPECT` requires you to read the existing code and adapt, not assume.

---

## 0. Before writing any code — INSPECT

Report back on these before implementing. Do not guess.

1. **Language / framework** — Kotlin native? React Native? Flutter? Compose UI?
2. **Inference binding** — `llama.cpp` JNI, `llama.rn`, MLC-LLM, ONNX Runtime? What is
   the exact function signature used to run a completion, and does it expose an
   **embedding** endpoint (`llama_embed` / `embedding: true`) or only text generation?
3. **Existing retrieval** — is there already a vector index? Which store
   (`sqlite-vec`, ObjectBox, ObjectBox HNSW, a hand-rolled float array + cosine loop)?
   What embedding model, and what dimensionality?
4. **Existing storage** — Room? Raw SQLite? Files in `filesDir`?
5. **Existing chunking** — chunk size, overlap, and whether chunk→source mapping is kept.
6. **Context budget** — what max context length is the loaded GGUF configured for, and
   how many tokens are currently reserved for retrieved content vs. system prompt?

The design below assumes: local SQLite + a vector index + a llama.cpp-family binding
that can produce embeddings. If any of those is false, flag it before proceeding.

---

## 1. What is actually being built

Three retrieval **strategies** over **one** corpus, with a user-facing switch and an
auto-router.

| Mode | Mechanism | Good at | Bad at |
|---|---|---|---|
| `VECTOR` | embed query → top-k chunk cosine → stuff chunks | fuzzy/semantic recall, paraphrase, "something about X" | multi-hop, "what depends on Y", whole-document questions |
| `GRAPH` | walk OKF markdown links from `index.md`, load **whole concept files** | named lookups, definitions, runbooks, relationships, structure | vague queries, corpus with no clean concept boundaries |
| `AUTO` | route to one of the above, with fallback | default UX | nothing, if instrumented properly |

**Critical framing:** OKF is a *file format*, not a retrieval engine. It is a directory of
markdown files with YAML frontmatter, cross-linked with ordinary markdown links. It ships
no runtime and no index. The "OKF mode" is *our* graph-walk consumer of that format. Do
not build it as if OKF provides retrieval.

**Both modes read the same bundle.** Do not maintain two corpora.

> Verification note: OKF v0.1 was published by Google Cloud in June 2026, after my
> knowledge cutoff. Frontmatter fields I believe are defined: `type` (required),
> `title`, `description`, `resource`, `tags`, plus a timestamp; a later revision may add
> `generated`, `verified`, `status`. **Check the current spec in the
> `GoogleCloudPlatform/knowledge-catalog` GitHub repo and treat that as authoritative
> over this document.** Parse defensively — unknown frontmatter keys must not crash.

---

## 2. Data layer

### 2.1 Bundle on disk

```
filesDir/
  okf/
    <bundle-name>/
      index.md
      concepts/
        metrics/
          daily-active-users.md
        runbooks/
          restart-ingest.md
      log.md            # optional, chronological
      .okf-manifest.json  # OUR file, not part of the spec
```

`.okf-manifest.json` is app-local bookkeeping:

```json
{
  "bundle_id": "personal-kb",
  "content_hash": "sha256 of sorted (relpath, filehash) pairs",
  "indexed_at": 1756600000,
  "embed_model": "<model id>",
  "embed_dim": 384,
  "file_count": 212
}
```

Reindex trigger = `content_hash` mismatch **or** `embed_model` mismatch. Never reindex on
app start unconditionally; on a phone that is a battery and thermal problem.

### 2.2 Schema

Extend the existing schema rather than creating a parallel one. Target shape:

```sql
-- one row per OKF concept file
CREATE TABLE concept (
  id            INTEGER PRIMARY KEY,
  bundle_id     TEXT NOT NULL,
  relpath       TEXT NOT NULL,          -- 'concepts/metrics/daily-active-users.md'
  type          TEXT,                   -- frontmatter 'type'
  title         TEXT,
  description   TEXT,
  tags          TEXT,                   -- JSON array, denormalised
  frontmatter   TEXT,                   -- full raw YAML as JSON, forward-compatible
  body          TEXT NOT NULL,
  body_tokens   INTEGER NOT NULL,
  file_hash     TEXT NOT NULL,
  UNIQUE(bundle_id, relpath)
);

-- resolved markdown links between concepts: the graph
CREATE TABLE concept_link (
  src_id     INTEGER NOT NULL REFERENCES concept(id) ON DELETE CASCADE,
  dst_id     INTEGER REFERENCES concept(id) ON DELETE CASCADE,  -- NULL = dangling
  dst_raw    TEXT NOT NULL,            -- original href, keep for debugging
  anchor     TEXT,                     -- link text
  PRIMARY KEY (src_id, dst_raw)
);
CREATE INDEX idx_link_src ON concept_link(src_id);
CREATE INDEX idx_link_dst ON concept_link(dst_id);

-- chunks for VECTOR mode
CREATE TABLE chunk (
  id          INTEGER PRIMARY KEY,
  concept_id  INTEGER REFERENCES concept(id) ON DELETE CASCADE,
  memory_id   INTEGER REFERENCES memory_fact(id) ON DELETE CASCADE,
  ord         INTEGER NOT NULL,
  text        TEXT NOT NULL,
  n_tokens    INTEGER NOT NULL,
  CHECK ((concept_id IS NULL) != (memory_id IS NULL))   -- exactly one owner
);

-- FTS5 for lexical prefilter + exact-title lookup
CREATE VIRTUAL TABLE concept_fts USING fts5(
  title, description, tags, body, content='concept', content_rowid='id'
);
```

Embeddings: keep in whatever store already exists. If none exists,
`sqlite-vec` is the natural fit — **but I have not verified it loads as a SQLite
extension on Android**; test that in a scratch build before committing to it. ObjectBox
has documented on-device vector search and is the safer fallback. If the corpus is under
~5k chunks, a flat `FloatArray` cosine scan in memory is genuinely fine and removes a
dependency; measure before adding a vector DB.

### 2.3 Indexing pipeline

```
for each *.md under bundle root:
    raw = read(file)
    (fm, body) = split_frontmatter(raw)      # tolerate missing '---' block
    upsert concept row
for each concept:
    for each markdown link (regex: \[([^\]]*)\]\(([^)]+)\))
        if href is external (http/https/mailto) -> skip
        strip #anchor, resolve relative to concept's dir, normalise
        insert concept_link (dst_id NULL if unresolved)
rebuild concept_fts
for each concept: chunk(body) -> chunk rows -> embed -> vector store
write .okf-manifest.json
```

Run on a `WorkManager` job (or framework equivalent), chunked with progress, cancellable,
and **only on charge or explicit user request** if the bundle is large. Embedding a few
thousand chunks on a phone CPU is minutes, not seconds.

Frontmatter parsing must be defensive: missing block, malformed YAML, unknown keys, and
`type` absent must all degrade to "treat body as plain text," never throw.

---

## 3. GRAPH mode (the OKF consumer)

Budgeted breadth-first walk. Whole files, not chunks — that is the entire point of the
mode.

```
fun graphRetrieve(query, budgetTokens): List<Concept>

  seeds = seedConcepts(query)              // §3.1
  if seeds.isEmpty(): return emptyList()   // caller falls back to VECTOR

  visited = mutableSetOf<Int>()
  out = mutableListOf<Concept>()
  used = 0
  frontier = ArrayDeque(seeds.map { it to 0 })   // (conceptId, depth)

  while (frontier.isNotEmpty()):
      (id, depth) = frontier.removeFirst()
      if id in visited || depth > MAX_DEPTH: continue
      visited += id
      c = loadConcept(id)

      if used + c.bodyTokens > budgetTokens:
          if depth == 0: out += truncateToFit(c, budgetTokens - used)  // never drop a seed
          continue                                                     // skip, keep walking
      out += c; used += c.bodyTokens

      if depth < MAX_DEPTH:
          neighbours = linksFrom(id).filter { it.dstId != null }
                                    .sortedByDescending { linkScore(it, query) }
                                    .take(FANOUT)
          frontier += neighbours.map { it.dstId!! to depth + 1 }

  return out
```

Constants to start with, then tune on real queries:
`MAX_DEPTH = 2`, `FANOUT = 4`, `budgetTokens` = whatever §6 allocates.

`linkScore` — cheap, no embeddings: term overlap between query and the link **anchor
text** + destination `title`/`description`, plus a small bonus if destination `type`
matches a type mentioned in the query. Keep it a pure function so it is unit-testable.

### 3.1 Seed selection

In priority order, stop at first non-empty:

1. **Exact/near-exact title match** via FTS5 on `concept.title` — handles "what is the
   daily-active-users metric".
2. **Type + tag filter** when the query names a `type` present in the corpus
   ("show me the runbook for…") → FTS restricted to that type.
3. **FTS5 BM25 top-3** over `title, description, tags`.
4. **Vector top-3 at concept level** (mean-pooled chunk vectors per concept), if
   embeddings are available.
5. **`index.md`** as the universal root — progressive-disclosure entry point.

If steps 1–4 all miss and only `index.md` is left, that is a weak signal: return it but
have the caller treat it as a fallback trigger (§5.3).

---

## 4. VECTOR mode

Presumably already built. Two changes:

1. **Include memory chunks.** Memory facts (§7) live in the same `chunk` table and the
   same index, so retrieval surfaces them alongside knowledge with no separate path.
2. **Hybrid scoring.** Pure cosine on a small on-device embedding model is weak on rare
   proper nouns. Blend with FTS5:

```
score = α * cosine_normalised + (1-α) * bm25_normalised
α ≈ 0.7   // tune
```

Normalise each list to [0,1] within the candidate set before blending, or use reciprocal
rank fusion — RRF is more robust and needs no α:

```
rrf(d) = Σ over lists  1 / (60 + rank_in_list(d))
```

Prefer RRF unless there is a reason not to.

Dedupe: if two retrieved chunks come from the same `concept_id` and together exceed ~60%
of that concept's `body_tokens`, replace both with the whole concept file. Cheaper in
tokens and strictly more coherent.

---

## 5. AUTO router

### 5.1 Contract

```
data class RouteDecision(
  val mode: Mode,              // VECTOR | GRAPH
  val confidence: Float,       // 0..1
  val reason: String,          // 'heuristic:definitional' | 'llm' | 'default'
  val latencyMs: Long
)
```

Every decision is logged (§8) and surfaced in the UI (§9). Never silent.

### 5.2 Cascade — cheapest first, stop on hit

**Stage 1 — structural heuristics (0 ms, no model).**

Route `GRAPH` on:
- definitional openers: `what is`, `what's`, `define`, `meaning of`
- structural nouns present in the corpus's `type` vocabulary: `runbook`, `playbook`,
  `schema`, `table`, `metric`, `api`, `dataset` — **build this list from
  `SELECT DISTINCT type FROM concept`, do not hardcode my guesses**
- relational: `depends on`, `upstream`, `downstream`, `related to`, `compare`, `across`,
  `difference between`
- an exact `concept.title` appears as a substring of the query (case-insensitive, ≥3 words
  or ≥12 chars to avoid false hits on short generic titles)

Route `VECTOR` on:
- query length > ~25 words (long natural-language descriptions)
- no FTS5 hit on any title/tag whatsoever
- interrogatives that imply synthesis over recall: `summarise`, `how do i feel about`,
  `remind me`, `did i ever`

**Stage 2 — memory-hit shortcut.** If FTS5 over `memory_fact` returns a strong hit, route
`VECTOR` (memory lives in the vector path).

**Stage 3 — LLM classify.** Only if Stages 1–2 are silent. One call, `max_tokens = 4`,
temperature 0, on the already-loaded model. Constrain output to a single token if the
binding supports a grammar / logit bias — if it doesn't, parse the first word and default
on parse failure.

```
Reply with exactly one word: RAG or OKF.
RAG = fuzzy semantic search over text fragments; use for vague, descriptive, or
      recall-style questions.
OKF = navigate a structured graph of named concepts and read whole documents; use for
      named lookups, definitions, procedures, and relationships between things.
Question: {query}
```

**Stage 4 — default `VECTOR`, `confidence = 0.3`, `reason = 'default'`.**

Add a hard timeout on Stage 3 (~800 ms). On a phone, a router that is slower than the
retrieval it routes is a failed design. If it times out, fall through to Stage 4.

### 5.3 Post-retrieval fallback (do not skip this)

The router will be wrong. Make wrongness cheap:

```
result = retrieve(mode)
if mode == GRAPH && (result.isEmpty()
                     || result.totalTokens < MIN_USEFUL_TOKENS      // ~200
                     || result.onlyContains(indexMd)):
    result = retrieve(VECTOR); decision.reason += "+fallback"

if mode == VECTOR && result.topScore < MIN_SCORE:                   // tune empirically
    graph = retrieve(GRAPH)
    if graph.isNotEmpty(): result = graph; decision.reason += "+fallback"
```

Log every fallback. A high fallback rate for one heuristic is your signal to delete that
heuristic.

---

## 6. Context assembly

Fixed budget, allocated in priority order. Do not let retrieval consume the whole window.

```
total        = model context length
reserve_out  = 512                        // generation headroom
system       = tokens(system prompt)
history      = min(tokens(recent turns), 0.20 * total)
retrieval    = total - reserve_out - system - history      // hard cap
```

Within `retrieval`, split by mode:

- `GRAPH`: 100% concept files, ordered seeds-first then by walk order.
- `VECTOR`: 85% chunks, 15% reserved for memory facts (so memory is never fully crowded
  out by a strong topical match).

Render retrieved content with provenance so the model can cite and the user can verify:

```
<context source="concepts/metrics/daily-active-users.md" type="metric" mode="okf">
{body}
</context>
```

Instruct the model in the system prompt to cite `source` paths. On an offline app with a
small model this is the main defence against confabulation, and it makes bad retrieval
visible instead of invisible.

---

## 7. Memory

Deliberately boring. No fine-tuning, no LoRA, no weight updates.

```sql
CREATE TABLE memory_fact (
  id         INTEGER PRIMARY KEY,
  text       TEXT NOT NULL,
  kind       TEXT,          -- 'preference' | 'fact' | 'project' | 'correction'
  source     TEXT,          -- session id
  created    INTEGER NOT NULL,
  last_used  INTEGER,
  hits       INTEGER NOT NULL DEFAULT 0,
  active     INTEGER NOT NULL DEFAULT 1
);
CREATE VIRTUAL TABLE memory_fts USING fts5(text, content='memory_fact', content_rowid='id');
```

**Write path.** At session end (or every N turns), one extraction call:

```
From the conversation below, extract 0-5 durable facts worth remembering
across future sessions. Durable = stable preferences, ongoing projects,
corrections the user made to you, personal context.
NOT durable = one-off questions, transient state, anything already obvious.
Output a JSON array of {"text": "...", "kind": "preference|fact|project|correction"}.
Output [] if nothing qualifies. Output only JSON.
```

Parse strictly; on malformed JSON, write nothing and log. Never let a failed extraction
corrupt the store.

**Dedupe before insert.** Embed the candidate, cosine against existing active facts; if
`> 0.92`, update the existing row's `last_used` instead of inserting. Without this the
table fills with fifty rephrasings of the same preference within a week.

**Read path.** Memory facts are chunked into the same `chunk` table with `memory_id` set,
so `VECTOR` mode retrieves them natively. Apply a small recency/usage boost:

```
final = similarity * (1 + 0.1 * log1p(hits)) * recencyDecay(last_used)
```

**Decay.** Monthly job: `active = 0` where `last_used` is older than ~180 days and
`hits = 0`. Soft delete, never hard — the user must be able to see and restore.

**User control is non-negotiable.** A screen listing every stored fact, with edit and
delete. An agent that silently accumulates claims about the user and cannot be audited is
a bug, not a feature.

---

## 8. Telemetry (local only)

```sql
CREATE TABLE route_log (
  id           INTEGER PRIMARY KEY,
  ts           INTEGER,
  query        TEXT,
  chosen_mode  TEXT,
  reason       TEXT,
  confidence   REAL,
  fell_back    INTEGER,
  n_results    INTEGER,
  ctx_tokens   INTEGER,
  latency_ms   INTEGER,
  user_override TEXT      -- set if user flips the switch and re-asks
);
```

This table is the entire point of building AUTO. After ~200 real queries, the override and
fallback columns tell you which heuristics to keep. Tune from this data, not from the
guesses in §5.2 — several of them are probably wrong for the specific corpus.

Stays on device. No network.

---

## 9. UI

- **Three-position control** in the composer: `RAG | OKF | Auto`. Persist last choice.
- **When Auto fires, show which mode ran** — a small inline chip on the response
  (`auto → OKF`). Tappable to expand: seeds used, files walked, fallback y/n.
- **One-tap "wrong mode, retry as X"** on that chip. Writes `user_override` and re-runs.
  This is the single highest-value piece of UI in the whole feature.
- **Sources list** under each answer: retrieved `relpath`s, tappable to open the raw
  markdown.
- Indexing progress + "reindex now" in settings, with last-indexed timestamp.

---

## 10. Test plan

**Unit**
- frontmatter parser: absent block, malformed YAML, unknown keys, CRLF, BOM, empty body
- link resolver: relative `../`, anchors, external URLs, dangling targets, self-links,
  URL-encoded paths
- graph walk: cycles terminate, budget respected, seeds never dropped, `MAX_DEPTH` honoured
- router: table-driven, ~40 labelled queries, assert the *reason* not just the mode

**Integration**
- Build a fixture bundle of ~20 concepts with known link topology. Assert exact retrieval
  sets for both modes on ~30 questions.

**The one that matters**
- Write 30 real questions you actually want to ask. Run each in `VECTOR` and `GRAPH`, hand
  score answers 0–2. That matrix is the ground truth for tuning §5.2 and for deciding
  whether AUTO earns its complexity at all.

**Device**
- Cold-start index of the full bundle: wall time, peak RSS, battery delta, thermal
  throttle behaviour.
- Airplane mode end-to-end. Every path must work with zero network.

---

## 11. Non-goals

- No cloud sync, no telemetry upload.
- No Hermes Agent integration in this phase. It is a Linux/macOS/WSL2 daemon; running it
  under Termux is unverified. Keep this codebase independent of it. If Hermes is added
  later, it consumes the same OKF bundle over a network boundary — design the bundle
  format as the contract, not the app internals.
- No model fine-tuning. "Learning" here means §7, and that is the honest scope.
- No OKF *authoring* UI in this phase. Bundles are edited as files.

---

## 12. Suggested order

1. Schema migration + frontmatter/link parser + fixture bundle. Tests green.
2. `GRAPH` retrieval behind a hidden dev toggle. No router.
3. Manual `RAG | OKF` switch shipped to the UI. Use it yourself for a week.
4. `route_log` table + the 30-question scoring matrix.
5. AUTO router built **from that data**.
6. Memory layer.
7. Post-retrieval fallback + the override chip.

Steps 1–3 deliver value alone. If AUTO turns out to add nothing over the manual switch,
step 5 gets deleted and that is a good outcome, not a failure.

---

## 13. Open questions for the human

1. Roughly how many concept files and total MB is the intended bundle? Changes the
   vector-store decision (flat scan vs. real ANN index) materially.
2. Is the corpus authored by you in OKF form, or generated from something else? If
   generated, the link graph may be sparse and `GRAPH` mode will underperform.
3. What model and context length is loaded on device? §6's budget math needs real numbers.
