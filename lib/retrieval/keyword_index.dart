import 'dart:math' as math;

/// One scored hit from [KeywordIndex.search].
class KeywordHit {
  final String id;
  final double score;
  const KeywordHit(this.id, this.score);
}

/// In-memory BM25 over a small document set.
///
/// ponytail: this replaces the spec's SQLite FTS5 table. At the stated corpus
/// size (< 5k documents) a Dart inverted index is a few hundred microseconds
/// per query and removes the sqflite dependency entirely. Above ~5k documents,
/// or once the index no longer fits comfortably in RAM, swap this for
/// `sqflite` + an FTS5 virtual table behind the same `search` signature.
class KeywordIndex {
  static const _k1 = 1.5;
  static const _b = 0.75;

  /// term -> {docId: term frequency}
  final Map<String, Map<String, int>> _postings = {};
  final Map<String, int> _docLength = {};
  double _avgDocLength = 0;

  int get documentCount => _docLength.length;

  /// Adds a document. [fields] are weighted by repetition count — a term in the
  /// title should outrank the same term buried in a body.
  void add(String id, {String title = '', String description = '', String tags = '', String body = ''}) {
    final terms = <String>[
      ...tokenize(title), ...tokenize(title), ...tokenize(title), // title x3
      ...tokenize(description), ...tokenize(description),          // description x2
      ...tokenize(tags), ...tokenize(tags),                        // tags x2
      ...tokenize(body),
    ];
    if (terms.isEmpty) {
      _docLength[id] = 0;
    } else {
      for (final t in terms) {
        (_postings[t] ??= {}).update(id, (n) => n + 1, ifAbsent: () => 1);
      }
      _docLength[id] = terms.length;
    }
    _recomputeAverage();
  }

  void _recomputeAverage() {
    if (_docLength.isEmpty) {
      _avgDocLength = 0;
      return;
    }
    _avgDocLength = _docLength.values.fold(0, (a, b) => a + b) / _docLength.length;
  }

  /// BM25-ranked ids for [query], best first, at most [limit].
  ///
  /// [restrictTo] narrows the candidate set — used for the spec's "type + tag
  /// filter" seeding stage.
  List<KeywordHit> search(String query, {int limit = 10, Set<String>? restrictTo}) {
    final terms = tokenize(query);
    if (terms.isEmpty || _docLength.isEmpty) return const [];

    final n = _docLength.length;
    final scores = <String, double>{};

    for (final term in terms.toSet()) {
      final posting = _postings[term];
      if (posting == null) continue;
      // Standard BM25 IDF, floored at zero so a term present in every document
      // contributes nothing rather than a negative score.
      final idf = math.max(0.0, math.log((n - posting.length + 0.5) / (posting.length + 0.5) + 1));

      posting.forEach((id, tf) {
        if (restrictTo != null && !restrictTo.contains(id)) return;
        final len = _docLength[id] ?? 0;
        final norm = tf * (_k1 + 1) / (tf + _k1 * (1 - _b + _b * len / (_avgDocLength == 0 ? 1 : _avgDocLength)));
        scores.update(id, (s) => s + idf * norm, ifAbsent: () => idf * norm);
      });
    }

    final hits = scores.entries.map((e) => KeywordHit(e.key, e.value)).toList()
      ..sort((a, b) => b.score.compareTo(a.score));
    return hits.length > limit ? hits.sublist(0, limit) : hits;
  }
}

final _tokenPattern = RegExp(r'[a-z0-9]+');

/// Lowercases, splits on non-alphanumerics, and drops one- and two-character
/// tokens plus a small stopword set. No stemming: on a mixed technical corpus
/// a stemmer merges `metric`/`metrics` but also mangles identifiers, and the
/// win does not pay for the dependency.
List<String> tokenize(String text) {
  return _tokenPattern
      .allMatches(text.toLowerCase())
      .map((m) => m.group(0)!)
      .where((t) => t.length > 2 && !_stopwords.contains(t))
      .toList();
}

const _stopwords = {
  'the', 'and', 'for', 'are', 'but', 'not', 'you', 'all', 'can', 'her', 'was',
  'one', 'our', 'out', 'day', 'get', 'has', 'him', 'his', 'how', 'its', 'new',
  'now', 'see', 'two', 'who', 'did', 'yes', 'this', 'that', 'with', 'from',
  'have', 'they', 'what', 'when', 'were', 'been', 'into', 'your', 'about',
};
