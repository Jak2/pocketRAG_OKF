# Design Theory — Pocket RAG / OKF

`decision.md` is the ledger: *what* was decided, one row per call. This file is
the theory behind it — the recurring principles those calls came from, and the
visual system they produced. New work should be derivable from this document. If
a principle here does not explain a choice you need to make, that is a gap worth
filling rather than a licence to improvise.

Cross-references to `decision.md` rows appear as (#n).

---

## Part 1 — The interaction thesis

**Retrieval that cannot be inspected cannot be trusted.**

Everything the user-facing half of this app does follows from that one sentence.
A RAG app is a machine for deciding what the model is allowed to see. When that
decision is invisible, a bad answer is indistinguishable from a bad model, a bad
corpus, or a bad question — and the user has no move except to rephrase and hope.

So the decision is never silent:

- Every answer carries a **mode chip**: which strategy ran, why (`reason`),
  how confident, how long it took, how many items and tokens it pulled, which
  concepts it seeded from, and whether a fallback fired (#21).
- Every answer carries its **sources** — the `relpath`s that went into the
  prompt — and the system prompt requires the model to cite them inline.
  Provenance is not decoration; on a small offline model it is the main defence
  against confabulation, and it turns bad retrieval from invisible into obvious.
- Every chip carries **"wrong mode — retry as X"**. One tap re-runs the same
  question the other way and records the override. This is the highest-value
  control in the app: it converts a wrong routing decision from a dead end into
  a labelled data point.
- Those overrides and fallbacks land in `route_log.jsonl` (#22), on device.
  That file is why Auto was built at all. After a couple of hundred real
  queries it — not intuition — says which heuristics in `router.dart` to keep.

The corollary is uncomfortable and load-bearing: **the router's heuristics are
guesses with a deletion date** (#23). They were written from a spec, without the
corpus. Shipping them is how the log gets populated. If the log eventually shows
Auto adds nothing over the manual switch, deleting Auto is the correct outcome,
not a failure — and the manual positions exist partly to be that control group
(#13).

## Part 2 — Governing principles

### 1. Degraded beats failed

No embedding model → BM25-only retrieval, and the header says "keyword only". A
chunk that fails to embed is skipped; the pass continues. A query that fails to
embed retrieves lexically. A corrupt `memory.json` loads empty. A file that will
not parse is skipped with its path collected, not fatal to the bundle (#29).

Every one of those answers the question worse. None of them refuse to answer it.
The rule is not "swallow errors" — it is that a partial answer with an honest
label beats a blank screen.

### 2. Honesty over comfort

Inherited, and still binding. The app does not fabricate a signal it does not
have: an elapsed-time counter rather than a fake percentage on model load,
because `llama_cpp_dart 0.0.9` exposes no progress callback and an estimate from
file size visibly stalls or overshoots. A confident lie is worse than an honest
unknown.

The same rule now decides how an unsupported file format is presented: PDF and
image rows sit in Config's FILE TOOLS list, greyed, labelled "not supported
offline" (#45). A toggle that indexes nothing is a confident lie the user cannot
detect; hiding the rows is a quieter one. A visible disabled row with a reason
is the only version that does not mislead.

Its hard-won corollary: **a system that hides its errors is worse than one that
fails loudly.** The 300-second "hang" documented in
`on_device_load_hang_rootcause.md` was a three-second error concealed by three
layers of well-meant error handling. Handlers that swallow, mask, or convert
errors into timeouts are bugs here, not robustness — which is why Principle 1's
degrade paths always change something the user can see.

### 3. Do not add a database to avoid writing thirty lines

BM25 is an inverted `Map` (#4). Vector search is a `for` loop over a `List`
(#5). Memory, the route log and the vector cache are files (#6). Frontmatter is
parsed by hand (#7).

At the target corpus size none of the alternatives buys anything but a
dependency, a schema, and a migration story. What makes this a principle rather
than laziness is the second half: **every shortcut names its ceiling and its
upgrade path, in a `ponytail:` comment at the site**, and each keeps the
replacement's signature. Swapping `KeywordIndex` for FTS5 or `VectorIndex` for
ObjectBox HNSW is a one-class change, not a rewrite. Grep `ponytail:` before
assuming any of it scales.

### 4. Prefer removing a parameter to guessing one

RRF instead of a tuned α (#11). Structural nouns read from the corpus's own
`type` vocabulary instead of a hardcoded list (#19). Both replace a number or a
list somebody would have had to invent with something the data supplies.

Where a constant genuinely cannot be avoided — `kMinDenseScore`,
`kMinLexicalScore`, `kMinUsefulTokens`, `kCharsPerToken`, `kDedupeThreshold` —
it is a named top-level constant with a comment saying what evidence would move
it. A magic number buried in an expression cannot be tuned by the person who
finds the evidence.

### 5. Measure with the right instrument

The fallback thresholds against raw BM25 and raw cosine, never against the fused
RRF score (#12), because RRF is rank-only: its top value is `1/61` whether the
corpus answered perfectly or not at all. Thresholding it would measure how many
lists were fused and nothing else.

Generalised: **before thresholding a score, ask what it is a function of.** A
number that moves with something other than the thing you care about is not a
signal, however plausible its range looks.

### 6. Never silently second-guess an explicit instruction

A manual `RAG` or `OKF` choice is obeyed exactly, empty result or not (#13).
Only Auto — the mode that admits it is guessing — is allowed to fall back.

The same shape appears in memory: a candidate fact with no vector is inserted
rather than merged (#27), because the ambiguous case must fail toward keeping
what the user said, not toward tidiness.

It also cuts the other way, and agent logic is where. A routing rule the user
wrote by hand runs as stage 0, ahead of every heuristic this app guessed (#49):
an explicit instruction beats an inference, and it is logged with
`reason: 'agent-logic'` so hand-written rules are measured on the same terms as
ours. But a persona is *prefixed* to the built-in system prompt, not swapped for
it, unless the file says `prompt: replace` (#48) — because dropping the citation
rule is not an instruction the user gave, it is a side effect they would never
see. Obey what was said; do not infer permission to discard what was not
mentioned.

### 7. Expensive work is explicit, cancellable, and reports progress

Indexing never runs on app start (#14). It is offered when the manifest says the
index is stale (#15), it streams `(done, total, stage)` to the UI, and
`shouldCancel` is checked before every chunk. On a phone, minutes of sustained
CPU is a battery and thermal event; deciding to spend it is the user's call.

### 8. Budgets are ceilings, and the ceiling includes its own overhead

Retrieval never gets the whole window: output headroom first, then the system
prompt, then history capped at 20%, and retrieval takes what is left (#28,
`context_assembler.dart:retrievalBudget`). Within a vector-mode budget, memory
keeps a reserved 15% share so a strong topical match cannot crowd out everything
the app knows about the user — and an unused reservation is released back, so
the reservation costs nothing when there is no memory to show.

The detail that makes it a principle: the truncation marker's own token cost is
subtracted before cutting (#18). A ceiling that the explanation of the ceiling
breaks is not a ceiling.

### 9. Priority order is a design decision, written down

The seed cascade stops at the first non-empty stage (title → type-filtered BM25
→ plain BM25 → `index.md`), and the last stage is flagged `weak` so the caller
can treat it as a fallback trigger rather than a hit. The router cascade is
cheapest-first and stops on the first stage with an opinion. The graph walk
never drops a seed for budget (#18).

In each case the ordering *is* the algorithm, and each stage records which one
fired — `reason: 'title-exact' | 'type-filter' | 'bm25' | 'index-fallback'`,
`reason: 'heuristic:definitional' | 'memory-hit' | 'llm' | 'default'` — so the
log can say which stages earn their place.

### 10. A router slower than what it routes is a failed design

Stage 3's LLM classification is capped at 800 ms and falls through on timeout
(#20). The timeout is the contract, not error handling. The same instinct keeps
stages 1 and 2 free: zero-cost string work and one lexical lookup answer most
queries before a model is ever asked.

### 11. "Learning" means something the user can read and delete

Memory is rows of text — no fine-tuning, no weight updates (#24). It is soft
delete only (#25), audited on its own screen, stored in a file that exports by
copying. An agent that accumulates claims about a person and offers no way to
inspect them is a bug, not a feature. This is why `memory_screen.dart` ships
with the memory layer rather than after it.

The write half has its own version of the rule: extraction runs on a turn
cadence the app reliably reaches (#36), never on `dispose`. A phone kills the
process without warning, so a feature that only fires at teardown is a feature
that quietly does not exist. And what memory learns has to reach the ranking,
not only the score field — the recency/usage boost is applied to fused scores
before the sort for exactly that reason (#37).

### 12. One instance of shared state, not two

`RootScreen` holds a single `KnowledgeService` for the whole app: the corpus and
its vectors are the largest thing in memory and a second copy would double it.
`EmbeddingEngineRegistry` and `OnDeviceEngineRegistry` do the same for loaded
models, so the indexer and the query path share one model rather than each
holding its own.

Two independent instances with independent lifecycles is not a shared feature —
it is two features that look like one, and the UI reports a state the app does
not have.

### 13. Trust the file format, not the file

Frontmatter parsing tolerates a missing block, a BOM, CRLF, an unterminated
block, an empty body and unknown keys — and never throws (#7). Unknown keys are
kept verbatim, because OKF is versioned outside this codebase and a key this app
does not recognise today may be the one it needs tomorrow. Link resolution drops
anything escaping the bundle root, which is a path-traversal guard as much as a
correctness one (#31).

The identity of a concept is its `relpath`, never anything from frontmatter: the
citation string has to be something the user can open.

### 14. Scope discipline

Spec §11's non-goals are the boundary: no cloud sync, no telemetry upload, no
Hermes Agent integration, no fine-tuning, no OKF authoring UI. `future_scope.md`
treats them as the frame, not a backlog.

---

## Part 3 — The visual system

Origin: `design/Pocket RAG.dc.html`, the Claude Design canvas built from
`claude-design-prompt.md` and checked into the repo (#40). It replaced the
previous system — pure black/white, 2px borders, no accent — end to end.
Implemented in `lib/theme/app_theme.dart`, which is the single source of truth:
screens compose its helpers and read its colours, and never hardcode a hex.

Read this section against the canvas. Where they disagree, the canvas is the
intent and the code is the truth, and the gap is a bug in one of them.

### The palette is a value, and there are two of them

`AppPalette` is a plain class with eleven colour fields and no defaults, so
**both themes must define every field**. That is the point of the shape: a
colour defined for only one theme renders correctly in the theme it was written
for and invisibly in the other, and nothing catches it.
`test/theme/palette_test.dart` asserts the pairwise difference of every field
for exactly that reason.

```
              kDarkPalette          kLightPalette
bg            #121212               #FAFAF8        page ground
surface       #1E1E1E               #F0EFEC        user bubble, raised panel
surfaceAlt    #17171A               #F5F4F1        composer field, expanded routing panel
fg            #ECECEA               #17171A        primary text
muted         white 55%             black 55%      labels, metadata
faint         white 40%             black 45%      timestamps, counts, disabled
border        white 10%             black 8%       hairlines
borderStrong  white 16%             black 16%      the element with focus
accent        #5B8DEF               #3D6FD9        the one accent
accentText    #8FB3F5               #3D6FD9        accent-coloured *text* on a tinted ground
onAccent      #0B1220               #FAFAF8        foreground on a filled accent surface
```

Neither ground is pure: #121212 rather than #000000, #FAFAF8 rather than
#FFFFFF. Pure black against `fg` at full white is the contrast ratio that makes
long body text buzz, and this app expects long answers to be read.

`accentText` exists separately from `accent` because the retry control is
accent-tinted text on a 12%-accent fill — at that contrast the pure accent is
too dark on the dark theme, so dark lifts it and light leaves it alone. Two
names, because one name used two ways is the bug this table exists to prevent.

### One accent, and still no semantic colour

There is exactly one accent (#42) and it is spent only on **what is active or
what happens next**: the selected mode segment, the send button, the index
progress bar, the mode chip's label, the retry control.

There is still **no red for errors and no green for success**. An error is
words. Nothing in the UI depends on hue to be understood, so it stays legible
under colour-vision deficiency — keep it that way. If a hierarchy problem shows
up, the vocabulary for it is weight, size, surface step, and border strength,
in that order. Reaching for a second accent immediately requires a rule saying
which accent means what, and there is no such rule.

### Structure: hairlines, surface steps, zero elevation

`border` at 8–10% alpha, one logical pixel, is the entire structural language
of the new screens. **No shadows anywhere, no elevation, no gradients.** Depth
is a surface step — `bg` → `surface` → `surfaceAlt` — not a shadow, which is
also why both surfaces are defined per theme rather than derived by alpha.

`borderStrong` (16%) is not "a slightly nicer border". It marks the element
that currently has attention: the composer field, the mode chip, an unselected
mode segment that is still a live target. Using it decoratively erases the
signal.

### Radius: pills and one rounding

```
100  every pill — mode segments, the mode chip, the retry control, theme toggle
20   the composer field and the user's message bubble
12   the expanded routing panel
10   Config rows, cards, text fields
6    source chips
```

Radius no longer encodes prominence the way the old scale did; it encodes
*kind*. A pill is a control. A 20 is a place text lives. A 10–12 is a container
of rows. A source chip is small and nearly square because there may be eight of
them wrapped over three lines.

### Typography: two faces now, three in the legacy helpers

| Face | Role |
|---|---|
| **Inter** (`appHeading`, `appBody`, `appSectionLabel`) | headings, prose, answers, button labels |
| **JetBrains Mono** (`appMono`) | anything machine-generated or machine-meaningful |
| **Sora** | survives in `appPrimaryButton` only, and nowhere else |

The load-bearing rule is unchanged and is the reason `appMono` is used as often
as it is: **anything machine-meaningful is monospaced.** Paths, mode labels,
`reason` strings, confidences, latencies, token counts, seeds, and *every text
input* — inputs hold bundle paths, model paths, endpoints and keys, where
`l`/`1`/`I` ambiguity is a real bug and not an aesthetic worry.

Sora is the one leftover of the old system in live code. `appPrimaryButton`
still renders Sora w700 on a `fg`-filled ground, and Config and Onboarding still
use it. Either it becomes Inter or it stays deliberately; right now it is
neither, just unmigrated.

### The migration is not finished, and here is exactly where

Honest inventory, because "the design was imported" reads as more complete than
it is:

- **Chat, Root, Memory, Route log, Source** are on the new system: hairlines,
  accents, pills.
- **Config and Onboarding are half-migrated.** They use the new section labels,
  the new dot rows, the new pill toggles — and also `appBorderedField`
  (2px `fg` border in all three states), `appPrimaryButton` and
  `appSecondaryButton` (2px `fg` border, Sora), plus six hand-written
  `width: 2` / `width: 3` borders. Those are the old system, still shipping.
- **`appChatBubble`, `appActionChip` and `appIconCircleButton` have no call
  site in `lib/ui/` at all.** They are the old bordered-bubble idiom, kept
  through a design change that removed their reason to exist.

### Components

Defined in `app_theme.dart`; use them rather than restyling raw widgets.

- `appBorderedField` — mono text; **old system**, 2px border in all three
  states, border does not change on focus.
- `appPrimaryButton` / `appSecondaryButton` — full-width, 2px, Sora/Inter;
  **old system**.
- `appStepper` — bounded integer control; arrows are *disabled* at the bounds
  rather than silently ignoring the press, so the bound is visible instead of
  feeling broken.
- `appSectionLabel` — 11px w600 Inter, `faint`, 0.55 tracking. The all-caps
  `MODEL` / `FILE TOOLS` / `APPEARANCE` headers are the only thing giving the
  1200-line Config screen a structure.
- `appHeading` / `appBody` / `appMono` — the three text ramps. Everything else
  is a size and a colour argument, never a new `TextStyle`.

**Component contract — a real crash lives here.** `appPrimaryButton` and
`appSecondaryButton` are `SizedBox(width: double.infinity)`. Placing one
directly in a `Row` without an `Expanded` wrapper throws a `BoxConstraints`
assertion and freezes the frame; it once made a whole screen appear to go blank.

**Dialog controllers.** A `TextEditingController` created for a dialog must be
disposed by `DisposeWithRoute`, not in a `finally` after `await showDialog`. The
future completes at `Navigator.pop`, but the popped route stays mounted through
the close animation, and a focused field re-listening to a disposed controller
throws and cascades into a red screen.

### The theme toggle, and what it cost

`applyThemeMode(bool dark)` swaps one global (#41). It is resolved in `main()`
before `runApp`, from `EngineSettings.themeMode`, because painting dark and
repainting light after the first frame is a visible flash on every cold start
(#43). Config's APPEARANCE section writes the setting and calls
`ThemeScope.of(context)?.onThemeChanged()`, which `setState`s the app root.

Three consequences that are not optional to remember:

1. **Nothing rebuilds on its own.** `AppColors` is not an `InheritedWidget`, so
   a widget that does not rebuild keeps the old colours. Every theme change must
   go through the root.
2. **`const` is gone from styled widgets.** A getter is not a compile-time
   constant, so ~21 expressions across `lib/ui/` lost their `const` — every one
   of them now rebuilds where it used to be canonicalised. At this screen count
   that is invisible; it is still a real cost, and it is why #41 records the
   `Theme.of(context)` upgrade path.
3. **Tests must restore the palette.** It is process-global state.
   `palette_test.dart` does this in `tearDown`; a leaked light theme would make
   an unrelated later test read the wrong colours.

### Layout

- Bottom-tab navigation is **Chat / Config**. Memory moved to a pushed route
  reached from the chat header's icon — it is something you go and audit, not a
  third of the app's surface, and giving it a permanent tab overstated it.
- `IndexedStack` keeps tab state alive across switches — which is why cross-tab
  handoffs use `didUpdateWidget`, not `initState` (`initState` fires once at app
  start and will not see a later handoff).
- **`SafeArea` on every screen.** Three tabs once shipped without it and
  rendered their headers under the status bar and notch.

## Part 4 — Native dependency discipline

Earned from the load-hang investigation; binding on all future work, and it now
applies twice over because the embedding isolate constructs its own
`ModelParams` / `ContextParams` (#9, #10).

1. **The pinned `llama.cpp` commit is part of the source contract.** The
   `llama_cpp_dart 0.0.9` FFI bindings are generated code with no compile-time
   validation against the native structs. A reordered or inserted field in
   `llama_model_params` / `llama_context_params` is a **silent SIGSEGV at
   runtime, not a build error.**
2. **Before bumping it, diff both param structs** against `lib/src/llama_cpp.dart`
   field for field. The method is in `on_device_load_hang_rootcause.md`.
3. **Patches to the pub-cache live in `scripts/setup_llama_cpp_dart.sh`,** never
   only on a developer's disk. Anything applied outside the repo must be
   scripted, idempotent and documented — `dart pub cache repair` erases it.
4. **Restore observability before hypothesising.** Eight black-box experiments
   (RAM, storage speed, mmap, OpenMP, release builds, GPU backends) all failed
   while the actual error message sat suppressed. One log callback ended it.
5. **A `Pointer.fromFunction` FFI callback is a diagnostic, never a shipped
   feature.** Routing llama.cpp's log through one crashed the app once llama.cpp
   logged from its own worker thread. Anything durable needs
   `NativeCallable.listener`.

---

## Where the rest lives

- `decision.md` — the numbered ledger this document explains
- `implementation.md` — how the pipeline works, end to end
- `status_open_points.md` — what is verified, what is guessed, what is unbuilt
- `future_scope.md` — where this could go, and the boundary it stops at
- `on_device_load_hang_rootcause.md` — the investigation behind Part 4
- `claude-design-prompt.md` — the brief the design canvas was built from
- `design/Pocket RAG.dc.html` — the canvas that answers it, and the reference
  Part 3 is written against (#40)
- `../okf-rag-dual-mode-spec.md` — the design spec this was built from
