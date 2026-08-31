import 'dart:math' as math;

/// One embedded chunk.
class VectorEntry {
  /// Index into the corpus chunk list this vector belongs to.
  final int chunkIndex;
  final List<double> vector;
  const VectorEntry(this.chunkIndex, this.vector);
}

/// Flat cosine scan over every stored vector.
///
/// ponytail: O(n) per query, no ANN structure, no vector database. At the
/// stated corpus size (< 5k chunks x 384 dims) that is a few million float
/// multiplies — under 10 ms on a phone, and it removes both `sqlite-vec`
/// (unverified as a loadable SQLite extension on Android) and ObjectBox from
/// the dependency list. If the corpus grows past ~20k chunks, or scan time
/// shows up in `route_log.latency_ms`, replace this class with ObjectBox HNSW
/// behind the same `search` signature.
class VectorIndex {
  final List<VectorEntry> _entries = [];

  int get length => _entries.length;
  bool get isEmpty => _entries.isEmpty;

  void add(int chunkIndex, List<double> vector) => _entries.add(VectorEntry(chunkIndex, vector));
  void clear() => _entries.clear();

  /// (chunkIndex, cosine) pairs for the [limit] closest vectors to [query].
  List<({int chunkIndex, double score})> search(List<double> query, {int limit = 10}) {
    if (_entries.isEmpty || query.isEmpty) return const [];
    final qNorm = _norm(query);
    if (qNorm == 0) return const [];

    final scored = <({int chunkIndex, double score})>[];
    for (final e in _entries) {
      if (e.vector.length != query.length) continue; // stale dimensionality
      final n = _norm(e.vector);
      if (n == 0) continue;
      scored.add((chunkIndex: e.chunkIndex, score: _dot(query, e.vector) / (qNorm * n)));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.length > limit ? scored.sublist(0, limit) : scored;
  }

  List<List<double>> toLists() => _entries.map((e) => e.vector).toList();
  List<int> chunkIndices() => _entries.map((e) => e.chunkIndex).toList();
}

double _dot(List<double> a, List<double> b) {
  var sum = 0.0;
  for (var i = 0; i < a.length; i++) {
    sum += a[i] * b[i];
  }
  return sum;
}

double _norm(List<double> v) => math.sqrt(_dot(v, v));

/// Cosine similarity between two vectors, 0 when either is degenerate.
double cosine(List<double> a, List<double> b) {
  if (a.length != b.length || a.isEmpty) return 0;
  final na = _norm(a), nb = _norm(b);
  if (na == 0 || nb == 0) return 0;
  return _dot(a, b) / (na * nb);
}

/// Reciprocal rank fusion over any number of ranked id lists.
///
/// Preferred over a weighted cosine/BM25 blend: it needs no tuned alpha and no
/// per-list score normalisation, which is exactly the tuning the spec warns is
/// probably wrong for this corpus.
Map<T, double> reciprocalRankFusion<T>(List<List<T>> rankings, {int k = 60}) {
  final fused = <T, double>{};
  for (final ranking in rankings) {
    for (var rank = 0; rank < ranking.length; rank++) {
      fused.update(ranking[rank], (s) => s + 1 / (k + rank + 1), ifAbsent: () => 1 / (k + rank + 1));
    }
  }
  return fused;
}
