import '../okf/concept.dart';
import 'chunker.dart';
import 'tokens.dart';

/// Which retrieval strategy ran. `auto` is a *request*, never a result — the
/// router always resolves it to one of the other two before retrieval.
enum RetrievalMode { vector, graph, auto }

extension RetrievalModeLabel on RetrievalMode {
  String get label => switch (this) {
        RetrievalMode.vector => 'RAG',
        RetrievalMode.graph => 'OKF',
        RetrievalMode.auto => 'Auto',
      };
}

/// One retrieved piece of context, whole-file or chunk, with the provenance
/// that lets the model cite it and the user verify it.
class RetrievedItem {
  /// `relpath` for concept content, `memory:<id>` for a memory fact.
  final String source;
  final String? type;
  final String text;

  /// Retrieval score in whatever units the producing mode uses. Only
  /// comparable within one result set.
  final double score;

  const RetrievedItem({
    required this.source,
    required this.text,
    this.type,
    this.score = 0,
  });

  factory RetrievedItem.fromConcept(Concept c, {double score = 0, String? text}) =>
      RetrievedItem(source: c.relpath, type: c.type, text: text ?? c.body, score: score);

  factory RetrievedItem.fromChunk(Chunk chunk, {String? type, double score = 0}) => RetrievedItem(
        source: chunk.conceptPath ?? 'memory:${chunk.memoryId}',
        type: type ?? (chunk.memoryId != null ? 'memory' : null),
        text: chunk.text,
        score: score,
      );

  int get nTokens => estimateTokens(text);
}

class RetrievalResult {
  final RetrievalMode mode;
  final List<RetrievedItem> items;

  /// Seed concepts for a graph walk, for the "why did I get this" UI. Empty
  /// for vector mode.
  final List<String> seeds;

  /// Best raw BM25 score among the candidates, or 0. Unlike a fused rank
  /// score this is an *absolute* relevance signal — "nothing actually matched"
  /// is expressible.
  final double bestLexical;

  /// Best raw cosine among the candidates, or null when no embedding model is
  /// loaded. Also absolute, and the only signal that catches a paraphrase the
  /// lexical index misses.
  final double? bestDense;

  const RetrievalResult({
    required this.mode,
    required this.items,
    this.seeds = const [],
    this.bestLexical = 0,
    this.bestDense,
  });

  bool get isEmpty => items.isEmpty;
  int get totalTokens => items.fold(0, (sum, i) => sum + i.nTokens);
  double get topScore => items.isEmpty ? 0 : items.first.score;
  List<String> get sources => items.map((i) => i.source).toList();

  /// True when the walk found nothing but the bundle's root index — a weak
  /// signal that should trigger the post-retrieval fallback rather than being
  /// served as an answer.
  bool get onlyIndexMd => items.length == 1 && items.first.source == 'index.md';
}
