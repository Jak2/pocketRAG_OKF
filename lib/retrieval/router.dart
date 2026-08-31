import '../okf/bundle.dart';
import 'keyword_index.dart';
import 'retrieval_result.dart';

/// What the router decided, and why. Every field is surfaced in the UI — a
/// silent router cannot be corrected, and correcting it is the point.
class RouteDecision {
  final RetrievalMode mode;
  final double confidence;

  /// e.g. `heuristic:definitional`, `llm`, `default`, `heuristic:long-query+fallback`.
  final String reason;
  final int latencyMs;

  const RouteDecision({
    required this.mode,
    required this.confidence,
    required this.reason,
    this.latencyMs = 0,
  });

  RouteDecision withFallback() => RouteDecision(
        mode: mode == RetrievalMode.graph ? RetrievalMode.vector : RetrievalMode.graph,
        confidence: confidence,
        reason: '$reason+fallback',
        latencyMs: latencyMs,
      );

  RouteDecision withLatency(int ms) =>
      RouteDecision(mode: mode, confidence: confidence, reason: reason, latencyMs: ms);
}

/// Openers that name a thing and ask what it is — the definitional case graph
/// mode exists for.
const _definitionalOpeners = [
  'what is', "what's", 'what are', 'define', 'definition of', 'meaning of', 'explain the',
];

/// Wording about how things relate, which needs the link graph rather than
/// nearest-neighbour fragments.
const _relationalPhrases = [
  'depends on', 'dependency', 'upstream', 'downstream', 'related to', 'compare',
  'difference between', 'across', 'connected to', 'linked to', 'how does', 'steps to',
];

/// Wording that asks for synthesis or personal recall, where whole structured
/// documents are the wrong unit.
const _synthesisPhrases = [
  'summarise', 'summarize', 'how do i feel', 'remind me', 'did i ever', 'anything about',
  'something about', 'my thoughts', 'brainstorm', 'ideas for',
];

/// Beyond this, a query is a natural-language description rather than a named
/// lookup, and dense retrieval handles it better.
const int kLongQueryWords = 25;

/// Answers `RAG` or `OKF` for a query. Returns null on timeout or an
/// unparseable reply — the caller then falls through to the default.
typedef LlmClassifier = Future<String?> Function(String query);

/// Stage 0: an agent-logic file's routing rules, if one is loaded. Returns the
/// mode the rules force for this query, or null for "no opinion".
/// [AgentLogic.routeFor] has exactly this shape; the typedef keeps retrieval
/// from depending on lib/agents.
typedef ForcedRoute = RetrievalMode? Function(String query);

/// Cheapest-first cascade. Each stage costs strictly more than the last, and
/// the first one that speaks wins.
///
/// [memoryHit] is true when the memory store has a strong lexical hit for this
/// query; memory lives in the vector path, so that shortcuts straight there.
Future<RouteDecision> routeQuery({
  required String query,
  required Bundle bundle,
  bool memoryHit = false,
  LlmClassifier? classify,
  ForcedRoute? forceMode,
  Duration classifyTimeout = const Duration(milliseconds: 800),
}) async {
  final stopwatch = Stopwatch()..start();

  // Stage 0 — an explicit rule the user wrote beats every heuristic we guessed.
  final forced = forceMode?.call(query);
  if (forced != null && forced != RetrievalMode.auto) {
    return RouteDecision(
      mode: forced,
      confidence: 1,
      reason: 'agent-logic',
      latencyMs: stopwatch.elapsedMilliseconds,
    );
  }

  final heuristic = heuristicRoute(query: query, bundle: bundle);
  if (heuristic != null) return heuristic.withLatency(stopwatch.elapsedMilliseconds);

  // Stage 2 — memory hit.
  if (memoryHit) {
    return RouteDecision(
      mode: RetrievalMode.vector,
      confidence: 0.7,
      reason: 'memory-hit',
      latencyMs: stopwatch.elapsedMilliseconds,
    );
  }

  // Stage 3 — one constrained LLM call, hard-capped. A router slower than the
  // retrieval it routes is a failed design, so a timeout falls straight
  // through to the default rather than waiting.
  if (classify != null) {
    try {
      final answer = await classify(query).timeout(classifyTimeout);
      final word = (answer ?? '').trim().toUpperCase();
      if (word.startsWith('OKF')) {
        return RouteDecision(
            mode: RetrievalMode.graph, confidence: 0.6, reason: 'llm', latencyMs: stopwatch.elapsedMilliseconds);
      }
      if (word.startsWith('RAG')) {
        return RouteDecision(
            mode: RetrievalMode.vector, confidence: 0.6, reason: 'llm', latencyMs: stopwatch.elapsedMilliseconds);
      }
    } catch (_) {
      // Timed out or the model returned nothing usable. Fall through.
    }
  }

  // Stage 4 — default.
  return RouteDecision(
    mode: RetrievalMode.vector,
    confidence: 0.3,
    reason: 'default',
    latencyMs: stopwatch.elapsedMilliseconds,
  );
}

/// Stage 1: zero-cost structural heuristics. Null means "no opinion", which
/// hands the query to the next stage. Split out from [routeQuery] so the whole
/// table can be unit-tested with no model and no async.
RouteDecision? heuristicRoute({required String query, required Bundle bundle}) {
  final lower = query.toLowerCase().trim();
  if (lower.isEmpty) return null;
  final words = lower.split(RegExp(r'\s+'));

  // VECTOR signals are checked first: a long descriptive query that happens to
  // start with "what is" is still a long descriptive query.
  if (words.length > kLongQueryWords) {
    return const RouteDecision(mode: RetrievalMode.vector, confidence: 0.7, reason: 'heuristic:long-query');
  }
  for (final phrase in _synthesisPhrases) {
    if (lower.contains(phrase)) {
      return const RouteDecision(mode: RetrievalMode.vector, confidence: 0.75, reason: 'heuristic:synthesis');
    }
  }

  // An exact concept title inside the query is the strongest signal there is.
  // Length-guarded so a short generic title does not match every question.
  for (final c in bundle.concepts) {
    final title = c.title.toLowerCase();
    if ((title.length >= 12 || title.split(' ').length >= 3) && lower.contains(title)) {
      return const RouteDecision(mode: RetrievalMode.graph, confidence: 0.95, reason: 'heuristic:title-match');
    }
  }

  for (final opener in _definitionalOpeners) {
    if (lower.startsWith(opener)) {
      return const RouteDecision(mode: RetrievalMode.graph, confidence: 0.8, reason: 'heuristic:definitional');
    }
  }

  for (final phrase in _relationalPhrases) {
    if (lower.contains(phrase)) {
      return const RouteDecision(mode: RetrievalMode.graph, confidence: 0.75, reason: 'heuristic:relational');
    }
  }

  // Structural nouns come from the corpus's own `type` vocabulary, never from
  // a hardcoded list — the point is that it adapts to what the user authored.
  final queryTerms = tokenize(lower).toSet();
  for (final type in bundle.types) {
    if (queryTerms.contains(type.toLowerCase())) {
      return const RouteDecision(mode: RetrievalMode.graph, confidence: 0.7, reason: 'heuristic:type-noun');
    }
  }

  return null;
}

/// The Stage 3 prompt. `max_tokens = 4`, temperature 0.
const String kClassifierPrompt = '''
Reply with exactly one word: RAG or OKF.
RAG = fuzzy semantic search over text fragments; use for vague, descriptive, or
      recall-style questions.
OKF = navigate a structured graph of named concepts and read whole documents; use for
      named lookups, definitions, procedures, and relationships between things.
Question: {query}
Answer:''';

String classifierPromptFor(String query) => kClassifierPrompt.replaceFirst('{query}', query);
