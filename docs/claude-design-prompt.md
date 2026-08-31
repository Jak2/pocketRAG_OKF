# Claude Design prompt — Pocket RAG / OKF (Android, Flutter)

Paste everything below the line into Claude Design.

---

Design the mobile UI for **Pocket RAG**, an offline Android knowledge assistant.
It answers questions about a folder of interlinked markdown notes, entirely on-device,
with no network. Target a **single phone-width artboard set** (393 × 852 dp), dark
theme first.

## Design language

Follow **open-webui**'s interface language, adapted to a phone:

- Near-black background, very low-chroma greys, one high-contrast foreground.
  Colour appears only as small accents, never as fills.
- Generous vertical rhythm. A centred single-column message list, comfortable line
  length, wide side gutters.
- Messages are not bubbles on both sides: the **user's turn is a soft rounded pill on
  the right**, the **assistant's turn is unboxed body text on the left** running the
  full column width, the way open-webui renders a response.
- Hairline dividers, 1px, no drop shadows, no gradients, no glassmorphism.
- Sans-serif for prose, monospace for anything machine-generated: file paths, mode
  labels, counts, latencies, token numbers.
- Every control is a bordered pill or a bare icon. No filled buttons except the single
  primary action per screen.

## Screens

### 1. Chat (primary)

Top to bottom:

- **Header** — title "Knowledge", and under it a monospace status line reading e.g.
  `212 concepts · 1,431 chunks` — or, when no folder is picked, `No bundle — pick a
  folder in Config`. A settings icon on the right.
- **Message list** — alternating user pills and assistant responses as described above.
- **Empty state** — a headline and one sentence explaining the three modes.
- **Answer metadata**, which is the part that matters most. Under every assistant
  answer:
  - a small **mode chip**, monospace, in a hairline pill: `RAG`, `OKF`, or
    `auto → OKF` when the router chose. When a fallback fired, the word `fallback`
    sits next to it, dimmed.
  - the chip is **tappable and expands** to reveal: the routing reason
    (`heuristic:definitional`), a confidence number, the router's latency in ms, item
    and token counts, and the seed documents a graph walk started from.
  - inside that expansion, one text action: **"Wrong mode — retry as RAG"** (or OKF).
    Design this so it reads as a first-class, inviting control — it is the single most
    valuable interaction in the app, and it must not look like a debug affordance.
  - a **sources row**: small monospace chips holding file paths like
    `concepts/metrics/daily-active-users.md`, wrapping to multiple lines, tappable to
    open the raw markdown.
- **Composer**, pinned to the bottom, in two rows:
  - Row 1: a **three-position segmented switch** — `RAG | OKF | Auto`. Exactly one is
    active; the active segment is a solid fill with inverted text, the others are
    hairline outlines. Full width, equal thirds.
  - Row 2: a bordered multi-line text field ("Ask your knowledge base…") and a circular
    send button.
- **Transient status line** between the list and the composer during a request:
  a tiny spinner plus monospace text (`retrieving…`, `generating (48 tokens)`).

### 2. Source viewer

Pushed when a source chip is tapped. Renders one markdown file: its path as a monospace
title, its frontmatter (type, title, description, tags) as a small metadata block, then
the rendered body. Links inside the body to other concepts are tappable and push another
source view.

### 3. Memory

A list of durable facts the app has stored about the user. Each row: the fact text, then
a dim monospace meta line (`preference · 3 hits`, and `· retired` when soft-deleted).
Edit and retire icons on the right. A header toggle: "Show retired" / "Hide retired".
Empty state: "Nothing remembered yet."

Design this to feel like an audit log the user is in charge of, not a settings page.

### 4. Config

Sectioned settings. Sections, in order:

1. **Knowledge base** — the OKF folder path + "Choose folder"; the embedding model path
   + "Choose .gguf"; a "Last indexed" line; a "Reindex now" button. During indexing the
   button is replaced by a **determinate progress bar** with `embedding 412/1431` in
   monospace beside it and a cancel affordance.
2. **Model** — cloud vs on-device toggle, endpoint, API key (obscured), model name,
   on-device .gguf picker with load/unload state.
3. **Personas** — a list of saved system prompts, one selectable.
4. **Diagnostics** — RAM and CPU readouts, and a "Routing log" row showing how many
   queries have been logged and what share fell back.

### 5. Routing log

Reached from Diagnostics. A dense monospace table of past routing decisions: timestamp,
truncated query, chosen mode, reason, whether it fell back, whether the user overrode
it. Above it, three summary stats: total queries, fallback rate, override rate. This is
a tuning instrument — design for density and scannability, not comfort.

### 6. Onboarding

Two steps, with a step indicator. Step 1: pick the knowledge folder, then show the count
of markdown files found as confirmation. Step 2: choose cloud or on-device model. Both
skippable.

## Hard constraints

- Everything must work with **zero network**. Do not design anything that implies
  syncing, sharing, accounts, or cloud storage.
- No avatars, no user profiles, no chat-history sidebar (single conversation for now).
- The mode chip and sources row must be legible at a glance without expanding —
  retrieval that cannot be inspected cannot be trusted.
- Deliver a component sheet alongside the screens: the mode chip in all its states, the
  three-position switch, a source chip, the expanded metadata block, and a message pair.

## Output

Artboards for each screen above plus the component sheet, laid out on one canvas. Dark
theme is primary; include a light-theme variant of the Chat screen only.
