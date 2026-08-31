# Future Scope — Pocket RAG / OKF

## The boundary

Spec §11's non-goals are the frame, not a backlog:

- **No cloud sync, no telemetry upload.** `route_log.jsonl` and `memory.json`
  stay on device. The moment either leaves, the offline claim in the README stops
  being true.
- **No Hermes Agent integration.** It is a Linux/macOS/WSL2 daemon and running it
  under Termux is unverified. If it is ever added, it consumes the same OKF
  bundle across a network boundary — **the bundle format is the contract**, not
  this app's internals. Nothing here should assume otherwise.
- **No fine-tuning.** "Learning" means `lib/memory/`, and that is the honest
  scope.
- **No OKF authoring UI.** Bundles are edited as files, with whatever editor the
  user already has.

Everything below stays inside that frame.

## Where it could go

1. **Per-`reason` breakdown in the route log.** `route_log_screen.dart` reports
   overall fallback and override rates. Grouping those *by `reason`* is what
   actually deletes a router heuristic — an aggregate rate says the router is
   wrong somewhere, not which rule to cut. Smallest change with the largest
   effect on the app's own design.

2. **The 30-question scoring matrix as a fixture.** Spec §10's ground-truth
   exercise, checked in: run both modes over a fixed bundle and assert retrieval
   sets. It converts threshold tuning from taste into a diff.

3. **Delete Auto.** A real outcome, on evidence. If the manual switch is as good,
   `router.dart` and half of `retrieval_service.dart` go away and the app gets
   better.

4. **Finish the three inert paths before adding a fourth.** Enabled skills reach
   no prompt, the active agent's model and logic path are never read, and
   `AgentLogic.allowedTools` restricts nothing (`status_open_points.md` 7–8).
   Each is an hour of wiring, and each is currently a control the UI offers that
   changes nothing — the exact failure mode `design_theory.md` Part 2.2 calls
   out. Deleting any of them is an equally good outcome; leaving them half-wired
   is not.

5. **Memory that earns its ranking, measured.** The recency/usage boost is wired
   (`memoryScore` through `MemoryBoost`) and `decay` runs on every open, so the
   store already behaves as the spec describes. What is missing is evidence:
   nobody knows whether `0.1 * ln(1 + hits)`, the 90-day recency half-life or
   the 180-day decay window are the right numbers, and the same `route_log.jsonl`
   discipline that tunes the router should eventually settle them. A per-turn
   record of which memory facts were retrieved would be the instrument.

6. **Graph mode over any linked markdown, not just OKF.** Nothing in
   `graph_retriever.dart` requires frontmatter — `parseConcept` already falls
   back to the filename for a title. A vault of plain interlinked notes (Obsidian,
   Zettelkasten, a docs tree) works today; saying so, and testing it, would widen
   the audience without a line of retrieval code.

7. **PDF text, if a real corpus demands it.** The extractor is registered and
   returns null (#45). Doing it properly means a parser dependency —
   `syncfusion_flutter_pdf` is the obvious candidate and is a large licensed
   package, which is why it is a decision rather than a commit. The honest
   alternative is deleting the row: a format that will never be supported should
   not sit in the list forever. Image OCR is further away still — ML Kit or
   Tesseract plus a platform channel per platform — and would be the app's first
   dependency that is not pure Dart or `llama.cpp`.

8. **`.xlsx` with its structure intact.** Today extraction is a flat text stream
   and a citation can quote a number without its header (#44). `package:xml`
   plus real cell addressing would let a spreadsheet cell cite its row and
   column. Worth doing only when someone actually points the app at a workbook —
   until then the flat stream is a smaller lie than a dependency nobody needs.

9. **A designed Config screen.** The canvas answered three artboards of six
   (#40), and Config was in neither the answer nor, as it turns out, the brief's
   priority. It is now the longest screen in the app, the least migrated off the
   old 2px system, and the one where every new feature lands. It is the next
   design pass, not the next feature.

10. **Scale, when the corpus demands it and not before.** Both storage shortcuts
   name their replacement and keep its signature: `KeywordIndex` → `sqflite` +
   FTS5, `VectorIndex` → ObjectBox HNSW. Neither is worth doing until
   `route_log.latency_ms` says so.

## The honest tradeoff

On-device generation quality on phone hardware (0.5–1.5B models) is weak, and the
`llama_cpp_dart` toolchain around it is brittle — bindings that must match an
exact `llama.cpp` commit with no compile-time check. That is why the cloud engine
stayed (`decision.md` #30): it lets retrieval quality be judged without the
generator being the bottleneck.

The interesting claim in this app is not "an LLM on a phone". It is that a
retrieval strategy which shows its work and can be corrected in one tap beats a
better one that cannot. That claim is testable with either engine, and
`route_log.jsonl` is where it gets settled.
