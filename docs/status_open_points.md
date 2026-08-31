# Status and Open Points — Pocket RAG / OKF

Written against the code as it stands, not against the plan. Where something is
unverified it says unverified; where something is built but unreachable it says
so.

---

## Known good

- **428 tests pass.** `flutter analyze` is clean. The 70 new ones are
  `test/okf/extractors_test.dart` (OOXML sweeps over real in-memory ZIPs, the
  `t="s"` shared-string trap, `loadBundle` with and without file tools),
  `test/agents/` (logic parsing and its degrade cases, slug filtering, the
  registry's dangling-active-id rule), and `test/theme/palette_test.dart`.
- The retrieval core is covered without a model or a device: `test/okf/`,
  `test/retrieval/` (chunker, keyword index, vector index, graph retriever,
  context assembler, router, retrieval service, the memory boost), `test/memory/`.
- `test/retrieval/router_test.dart` asserts the `reason` string, not just the
  chosen mode, so a rule firing for the wrong cause fails the test.
- The parser's defensive cases are tested directly: absent frontmatter,
  unterminated block, BOM, CRLF, unknown keys, `../` escapes, anchors, external
  schemes, dangling targets.
- The memory layer is wired end to end in code: extraction runs every 6 turns
  from `chat_screen.dart:_maybeExtractMemories`, `memoryScore` reaches the
  ranking through `vectorRetrieve`'s `MemoryBoost` callback, and `decay` runs on
  every `KnowledgeService.open` (`decision.md` #36, #37). Read `implementation.md`
  §8 for the shape of it. "In code" is the caveat that matters — see open
  point 2: none of it has run on a device.
- A bundle, embedding model, file-tool set or agent-logic path picked in Config
  takes effect without a restart (`KnowledgeService.isOpenFor` +
  `RootScreen._configRevision` + `ChatScreen.didUpdateWidget`), and staleness is
  visible: `indexStale` is a getter on the service and the chat header renders
  `· index stale`.
- **The theme toggle is wired end to end and verified by test.** `themeMode` is
  persisted, resolved in `main()` before the first frame (#43), and
  `palette_test.dart` asserts both palettes are complete, that `AppColors`
  follows the live palette rather than a captured value, and that `fg`/`bg`
  never collide.
- **File-tool extraction is real for `.txt`, `.csv`, `.json`, `.docx`, `.pptx`
  and `.xlsx`,** tested against ZIPs built in the test itself rather than
  fixtures, and the enabled set is part of the manifest so turning a format on
  marks the index stale with nothing changed on disk.
- **Agent logic reaches the two places it claims to.** The persona reaches
  `buildPrompt` through `KnowledgeService.prepare`; the routing rules reach
  `routeQuery` as stage 0 with `reason: 'agent-logic'`. See open point 6 for the
  third thing it parses.

## Known unverified — the big one first

### 1. No embedding GGUF has ever been run through `Llama.getEmbeddings` on Android

This is the single largest unverified assumption in the app. `lib/engine/
embedding_engine.dart` was written from the `llama_cpp_dart` API surface, not
from a working run. Everything downstream of it — the vector index, RRF, whole-
file promotion, `bestDense`, the dense fallback threshold, memory dedupe — is
untested against a real vector.

Specific unknowns:

- whether `getEmbeddings` on `llama_cpp_dart 0.0.9` returns a usable pooled
  sentence vector for a sentence-transformer GGUF, or something else entirely
- whether `ContextParams..embeddings = true` with `nPredict = 0` is the correct
  configuration for that build
- whether a second `Llama` in a second isolate coexists with the chat model's
  `LlamaParent` without native-side contention or an OOM on a mid-range phone
- what the actual per-chunk embedding latency is, and therefore whether
  indexing a real bundle is two minutes or twenty

If it turns out `getEmbeddings` does not work in this binding, the app still
functions: everything degrades to BM25 and the header says "keyword only". That
is the designed floor, not a fix.

### 2. The app has never been run on a device in this configuration

No bundle has been indexed end to end. Nothing below has been exercised against
real files on real storage:

- the SAF/`file_picker` directory path a user actually picks, and whether
  `Directory.list(recursive: true)` can read it. Writing is no longer part of
  this risk: the manifest moved into app documents (#35), so the picked folder
  is read-only as far as the app is concerned
- whether periodic memory extraction is tolerable in practice — a sixth-turn
  answer paying for a second full generation is a latency the user did not ask
  for, and the cadence is a guess
- indexing wall time, peak RSS, battery delta and thermal behaviour
- the full airplane-mode path

### 3. Three thresholds are guesses awaiting `route_log.jsonl` data

`kMinDenseScore` (0.25), `kMinLexicalScore` (0.5) and `kMinUsefulTokens` (200)
in `retrieval_service.dart` were chosen to be forgiving, not measured. They
control when the post-retrieval fallback fires, so both failure modes are live:
too low and a bad result is served, too high and every query pays for two
retrievals. Tune them from the `fell_back` column against hand-scored answers,
not by feel.

`kCharsPerToken` (3.5), `kWholeFileThreshold` (0.6), `kMaxDepth` (2),
`kFanout` (4) and `kDedupeThreshold` (0.92) are in the same category, with less
at stake.

### 4. The router heuristics are the spec's guesses and are meant to be deleted

Every rule in `router.dart:heuristicRoute` — the opener lists, the phrase lists,
the 25-word threshold, the confidence numbers — came from a spec written without
sight of the corpus. They ship so that `route_log.jsonl` has something to
measure. A rule with a high `fell_back` or `user_override` rate should be
deleted, not tuned; and if Auto as a whole shows no benefit over the manual
switch, deleting Auto is the correct outcome.

Nothing has yet read that log; see the closing list.

### 5. Token counting is an estimate, not a tokenizer

`estimateTokens` is `ceil(length / 3.5)`. It drifts on code blocks, tables, CJK
and heavy punctuation. Every budget is a ceiling so the error direction is
usually safe, but a prompt that overflows the context window on device is this
constant's fault before it is anything else's.

### 6. PDF and image indexing do not exist — the one place the UI cannot deliver what the design promises

`extractors.dart` registers `pdf`, `png`, `jpg` and `jpeg` and **all four return
`null`.** PDF needs a real parser (font maps, content-stream operators,
encodings); image text needs OCR, which offline means ML Kit or Tesseract plus a
platform channel per platform. Neither is a dependency this app carries, and
adding one is a decision, not something to slip into an extractor.

What ships instead: the two rows are visible in Config's FILE TOOLS list, greyed,
subtitled "not supported offline", and not togglable (#45). If a PDF is ever
reached anyway, `loadBundle` records `"<relpath>: no text extracted"` in
`skipped`. **Nothing in `lib/` ever passes that `skipped` list** — `openCorpus`
does not thread it through and no screen renders it, so in the shipped app it is
always null and a `.docx` that extracts nothing is exactly as silent as one that
was never enabled. Only the tests use the parameter. That is the next small
honest fix in this area.

The `.xlsx` ceiling belongs here too: extraction is a flat text stream with row
and column structure lost (#44). A citation can quote a number without the header
that gives it meaning, and nothing detects that.

### 7. `AgentLogic.allowedTools` is parsed and inert

The `Tools` / `Tool permissions` / `Permissions` section of a logic file parses
into a `Set<String>` of extensions, is unit-tested, and **is read by no caller**.
It is not enforced at extraction time, not at retrieval time, and not at citation
time. A logic file that says an agent may read only `md` is describing something
the app does not do. Either wire it into `loadBundle`'s `fileTools` intersection
or delete the section from the parser — shipping a permission that does not
restrict anything is the worst of the three states.

### 8. Skills and custom agents persist, and change nothing

`SkillState` and `AgentRegistry` are imported by `config_screen.dart` and by
nothing else in `lib/`:

- **Enabled skills reach no prompt.** The slugs are saved and restored and the
  dots light up. `buildPrompt` never sees the skill bodies from
  `InstructionLibrary`, so switching a skill on changes the UI and nothing the
  model reads.
- **The active agent is never consulted.** `AgentEntry.modelId` and
  `AgentEntry.logicPath` are stored, but `chat_screen.dart` builds its engine
  from `EngineSettings` and passes `settings.agentLogicPath` — the *global* one.
  Selecting an agent does not switch the model and does not switch the logic
  file.

Both are honest data layers with tests; neither is a feature yet. The remaining
work is small and specific — resolve `activeAgent` in `_loadSettings`, prefer its
`modelId`/`logicPath` over the globals, and concatenate enabled skill bodies into
the system prompt ahead of the persona — but until it is done, this document is
the only place that says so.

---

## Built but not wired

Three things, all new, all listed above in detail: `AgentLogic.allowedTools`
(point 7), enabled skills (point 8), and the active agent's model and logic path
(point 8). `RouteLog.readAll` still backs `route_log_screen.dart`, reached from
Config.

In the theme layer, `appChatBubble`, `appActionChip` and `appIconCircleButton`
now have **no call site in `lib/ui/`** — the design import removed the last of
them. `appActionChip` still has widget tests, which is why the suite exercises a
component the app does not render.

---

## Wiring gaps found by reading `lib/`

1. **`lastIndexedLabel` is session-only.** `root_screen.dart` sets it from
   `DateTime.now()` after a reindex and never reads `manifest.indexedAt`, so
   after a restart the app cannot say when it last indexed even though the
   manifest records it. This is the last one left.

---

## Carried over from the git app and now inert

The git/GitHub layer is gone, but not everything that served it left with it.
These still compile, still have tests in the 359, and no longer participate in
the app's actual pipeline:

- `lib/chat/slash_command.dart` — **no importer in `lib/` at all**, only its
  test. (`prompt_budget.dart` was the other one and has been deleted:
  `context_assembler.dart` supersedes it, and its doc comment described
  budgeting a repository file tree. Its 8 tests went with it.)
- `lib/agent/graph_engine.dart` — a general graph orchestrator; referenced only
  by a Config toggle's description string. Its doc comment now says plainly that
  it is carried over and unwired, kept because it is self-contained and tested,
  and to be deleted if orchestration does not land.
- `lib/instructions/` + `assets/personas/` — seven code-review/debugging personas
  are seeded into the documents directory on **every** cold start
  (`main.dart:seedStarterPersonasIfEmpty`) and are never used by the retrieval
  chat screen.
- `lib/settings/agent_config.dart`, `lib/engine/langchain_chat_model.dart`, and
  Config's LangChain / Graph-orchestration toggles — the toggles persist a
  preference and route nothing.
- `app_theme.dart:appChatBubble`, `appActionChip` and `appIconCircleButton` —
  no longer used by any screen. `app_theme.dart` is **no longer** the git app's
  copy: it was rewritten from `design/Pocket RAG.dc.html` (#40), which is what
  finally made `decision.md` #2's narrow reading obsolete. What survives of the
  old system is `appBorderedField`, `appPrimaryButton` and `appSecondaryButton`
  — 2px `fg` borders and Sora — still used by Config and Onboarding. See
  `design_theory.md` Part 3, "The migration is not finished".

Decide deliberately whether these stay. They are not harmless: they are most of
the difference between the test count and the tested surface of the actual app.

---

## Repository inconsistencies

- `fronten/` is gone — it was the deleted git app's design canvas.
- `research/` holds `pocketpal_apk/` and nothing else.
- `open-webui/` is a full upstream source checkout committed into the repo. It
  is reference material (`decision.md` #2) and should probably not be vendored.
- `design/Pocket RAG.dc.html` + `design/support.js` (~120 KB together) are
  checked in deliberately (#40): the canvas is the reference `design_theory.md`
  Part 3 is written against, and a design system nobody can open drifts silently.
  Nothing in the build reads them.

---

## UI status

The design pass happened. `docs/claude-design-prompt.md` was answered by
`design/Pocket RAG.dc.html`, and the chat screen, the root shell, memory, the
route log and the source viewer are all on the new system.

**The canvas answers three of the six screens it was asked for.** It came back
with CHAT — DARK (INTERACTIVE), CHAT — LIGHT VARIANT and COMPONENT SHEET. Source,
Routing log, Memory and Onboarding exist in code and were restyled by hand from
the same tokens — which is defensible, and also means those four screens have no
designed reference to be checked against. Config was never in the canvas either,
and it is the screen that grew most (file tools, custom agents, agent logic,
appearance, enabled skills) and is the least migrated.

Other UI changes worth recording:

- Bottom nav is **Chat / Config**; memory is a pushed route from the chat header.
- Indexing shows a determinate `LinearProgressIndicator` with a working Cancel —
  `KnowledgeService.cancelIndexing` sets a flag the embed loop checks between
  chunks, so the bar holds its last position until the current chunk finishes.
- The mode chip is a hand-rolled expandable, not an `ExpansionTile`: it needed a
  pill trigger and a separate panel below it, which `ExpansionTile` will not
  give without fighting its own layout.

**There are still no widget tests for any screen** — chat, memory, root,
onboarding, config. The eight `testWidgets` in the suite all live in
`test/theme/` and cover `appStepper`, `appActionChip` (unused) and
`DisposeWithRoute`. Every screen-level claim in this document was established by
reading, not by running. The `_retryAs` transcript-truncation logic
(`_turns.removeRange(indexOf(turn) - 1, ...)`) in particular is the kind of index
arithmetic that wants a test before it wants a device.

---

## What would move this furthest, in order

1. Get one embedding GGUF working through `getEmbeddings` on a device, or find
   out it cannot be done in this binding. Everything dense depends on the answer.
2. Index a real bundle end to end: wall time, peak RSS, thermals, and whether
   the picked folder can be walked at all.
3. Run the spec §10 exercise: 30 real questions, both modes, hand-scored 0–2.
   That matrix is the ground truth for every threshold above, and the evidence
   for or against Auto existing at all.
4. Close the three inert paths (points 6–8), in the cheapest order: surface
   `skipped` in Config so a file that extracted nothing says so, then wire the
   active agent's `modelId`/`logicPath`, then either enforce `allowedTools` or
   delete it. Each is small; each is currently a claim the UI makes and the code
   does not keep.
