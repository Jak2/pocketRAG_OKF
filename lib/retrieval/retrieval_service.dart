import 'context_assembler.dart';
import 'corpus.dart';
import 'graph_retriever.dart';
import 'retrieval_result.dart';
import 'route_log.dart';
import 'router.dart';
import 'vector_retriever.dart';

/// Below this, a graph walk found so little it is not worth answering from.
const int kMinUsefulTokens = 200;

/// Below this cosine, the closest chunk is not actually about the query.
///
/// Used only when an embedding model is loaded. Deliberately forgiving: a small
/// on-device embedding model produces flatter similarities than a hosted one.
const double kMinDenseScore = 0.25;

/// Below this raw BM25 score, no query term matched anything worth having.
///
/// This is the fallback signal when there are no embeddings. Note it is a raw
/// BM25 score, not the fused RRF score: RRF is rank-only, so its top score is
/// `1/61` whether the corpus answered the question perfectly or not at all, and
/// thresholding it can only ever measure how many lists were fused.
const double kMinLexicalScore = 0.5;

/// One turn's retrieval: what ran, what came back, and what it cost.
class RetrievalOutcome {
  final RouteDecision decision;
  final RetrievalResult result;
  final bool fellBack;

  const RetrievalOutcome({required this.decision, required this.result, this.fellBack = false});

  RouteLogEntry toLogEntry(String query, {String? userOverride}) => RouteLogEntry(
        ts: DateTime.now().millisecondsSinceEpoch,
        query: query,
        chosenMode: result.mode.name,
        reason: decision.reason,
        confidence: decision.confidence,
        fellBack: fellBack,
        nResults: result.items.length,
        ctxTokens: result.totalTokens,
        latencyMs: decision.latencyMs,
        userOverride: userOverride,
      );
}

/// Runs one retrieval, honouring the user's mode switch or routing for them.
///
/// [requested] is what the switch says. `auto` routes; `vector`/`graph` are
/// obeyed exactly — a manual switch that silently second-guesses the user is
/// worse than no switch.
///
/// The post-retrieval fallback is not optional. The router will be wrong; this
/// is what makes being wrong cheap, and every fallback is logged so a
/// heuristic with a high fallback rate can be deleted on evidence.
Future<RetrievalOutcome> retrieve({
  required Corpus corpus,
  required String query,
  required RetrievalMode requested,
  required int budgetTokens,
  List<double>? queryVector,
  bool memoryHit = false,
  LlmClassifier? classify,
  ForcedRoute? forceMode,
  MemoryBoost? boostMemory,
}) async {
  final decision = requested == RetrievalMode.auto
      ? await routeQuery(query: query, bundle: corpus.bundle, memoryHit: memoryHit, classify: classify, forceMode: forceMode)
      : RouteDecision(mode: requested, confidence: 1, reason: 'manual');

  RetrievalResult run(RetrievalMode mode) => switch (mode) {
        RetrievalMode.graph => graphRetrieve(corpus, query, budgetTokens: budgetTokens),
        RetrievalMode.vector || RetrievalMode.auto => applyMemoryShare(
            vectorRetrieve(corpus, query,
                budgetTokens: budgetTokens, queryVector: queryVector, boostMemory: boostMemory),
            budgetTokens,
          ),
      };

  var result = run(decision.mode);

  // A manual choice is never overridden — the user asked for that mode and
  // gets it, empty or not. Only the router's own guesses are second-guessed.
  if (requested == RetrievalMode.auto && _isWeak(result)) {
    final alternative = run(decision.mode == RetrievalMode.graph ? RetrievalMode.vector : RetrievalMode.graph);
    if (!alternative.isEmpty && !_isWeak(alternative)) {
      return RetrievalOutcome(decision: decision.withFallback(), result: alternative, fellBack: true);
    }
  }

  return RetrievalOutcome(decision: decision, result: result);
}

bool _isWeak(RetrievalResult result) => switch (result.mode) {
      RetrievalMode.graph =>
        result.isEmpty || result.totalTokens < kMinUsefulTokens || result.onlyIndexMd,
      // Dense similarity is the better signal and wins when it exists; BM25
      // stands in when it does not, so degraded (no-embedding) mode still has
      // a real notion of "nothing matched".
      RetrievalMode.vector || RetrievalMode.auto => result.isEmpty ||
          (result.bestDense != null
              ? result.bestDense! < kMinDenseScore
              : result.bestLexical < kMinLexicalScore),
    };
