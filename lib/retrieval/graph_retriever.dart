import 'dart:collection';

import '../okf/concept.dart';
import 'corpus.dart';
import 'keyword_index.dart';
import 'retrieval_result.dart';
import 'tokens.dart';

/// How far from a seed the walk will travel.
const int kMaxDepth = 2;

/// How many neighbours of one concept are queued. Unbounded fan-out on a
/// densely linked bundle drags in the whole corpus.
const int kFanout = 4;

/// Cheap, embedding-free relevance of one link to the query.
///
/// Pure function of its inputs so the walk's ordering is unit-testable without
/// a model, a corpus, or a device.
double linkScore({
  required String query,
  required String anchor,
  required String targetTitle,
  String? targetDescription,
  String? targetType,
}) {
  final queryTerms = tokenize(query).toSet();
  if (queryTerms.isEmpty) return 0;

  double overlap(String text, double weight) {
    final terms = tokenize(text).toSet();
    if (terms.isEmpty) return 0;
    return weight * terms.intersection(queryTerms).length / queryTerms.length;
  }

  var score = overlap(anchor, 1.0) + overlap(targetTitle, 1.0) + overlap(targetDescription ?? '', 0.5);
  // A query that names a type ("the runbook for…") should prefer neighbours of
  // that type over equally-worded ones of another.
  if (targetType != null && queryTerms.contains(targetType.toLowerCase())) score += 0.5;
  return score;
}

/// Picks where the walk starts. Priority order, first non-empty wins.
///
/// Returns `weak: true` when the only seed left is the bundle root, which the
/// caller must treat as a fallback trigger rather than a hit.
({List<Concept> seeds, bool weak, String reason}) seedConcepts(Corpus corpus, String query) {
  final bundle = corpus.bundle;
  if (bundle.concepts.isEmpty) return (seeds: const [], weak: true, reason: 'empty-bundle');

  final lowerQuery = query.toLowerCase();

  // 1. A concept title appearing verbatim in the query. Guarded on length so a
  //    generic two-word title does not match half the questions asked.
  final titleMatches = bundle.concepts
      .where((c) => c.title.length >= 12 && lowerQuery.contains(c.title.toLowerCase()))
      .toList();
  if (titleMatches.isNotEmpty) return (seeds: titleMatches, weak: false, reason: 'title-exact');

  // 2. Query names a type present in the corpus: restrict BM25 to that type.
  final namedType = bundle.types.firstWhere(
    (t) => tokenize(lowerQuery).contains(t.toLowerCase()),
    orElse: () => '',
  );
  if (namedType.isNotEmpty) {
    final ofType = bundle.concepts.where((c) => c.type == namedType).map((c) => c.relpath).toSet();
    final hits = corpus.conceptIndex.search(query, limit: 3, restrictTo: ofType);
    if (hits.isNotEmpty) {
      return (seeds: _resolve(corpus, hits), weak: false, reason: 'type-filter');
    }
  }

  // 3. Plain BM25 over the concept index.
  final hits = corpus.conceptIndex.search(query, limit: 3);
  if (hits.isNotEmpty) return (seeds: _resolve(corpus, hits), weak: false, reason: 'bm25');

  // 4. index.md as the universal progressive-disclosure entry point — a seed,
  //    but explicitly a weak one.
  final index = bundle.indexConcept;
  if (index != null) return (seeds: [index], weak: true, reason: 'index-fallback');
  return (seeds: const [], weak: true, reason: 'no-seed');
}

List<Concept> _resolve(Corpus corpus, List<KeywordHit> hits) =>
    hits.map((h) => corpus.bundle.byPath(h.id)).whereType<Concept>().toList();

/// Budgeted breadth-first walk over the link graph, returning **whole concept
/// files**. Loading whole files rather than fragments is the entire point of
/// this mode — it is what makes definitions, runbooks and relationships hold
/// together.
RetrievalResult graphRetrieve(Corpus corpus, String query, {required int budgetTokens}) {
  final seeded = seedConcepts(corpus, query);
  if (seeded.seeds.isEmpty) {
    return const RetrievalResult(mode: RetrievalMode.graph, items: []);
  }

  final visited = <String>{};
  final out = <RetrievedItem>[];
  var used = 0;

  final frontier = Queue<({Concept concept, int depth})>()
    ..addAll(seeded.seeds.map((c) => (concept: c, depth: 0)));

  while (frontier.isNotEmpty) {
    final (concept: concept, depth: depth) = frontier.removeFirst();
    if (!visited.add(concept.relpath) || depth > kMaxDepth) continue;

    final cost = estimateTokens(concept.body);
    if (used + cost > budgetTokens) {
      // A seed is the direct answer to the question and is never dropped for
      // budget — it is truncated instead. Non-seeds are skipped, but the walk
      // continues: a smaller neighbour further on may still fit.
      if (depth == 0) {
        final room = budgetTokens - used;
        if (room > 0) {
          final text = _truncateToTokens(concept.body, room);
          out.add(RetrievedItem.fromConcept(concept, text: text, score: 1 / (out.length + 1)));
          used += estimateTokens(text);
        }
      }
      continue;
    }

    out.add(RetrievedItem.fromConcept(concept, score: 1 / (out.length + 1)));
    used += cost;

    if (depth == kMaxDepth) continue;

    final neighbours = concept.resolvedLinks
        .map((l) => (link: l, target: corpus.bundle.byPath(l.targetPath!)))
        .where((n) => n.target != null && !visited.contains(n.target!.relpath))
        .map((n) => (
              target: n.target!,
              score: linkScore(
                query: query,
                anchor: n.link.anchor,
                targetTitle: n.target!.title,
                targetDescription: n.target!.description,
                targetType: n.target!.type,
              ),
            ))
        .toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    for (final n in neighbours.take(kFanout)) {
      frontier.add((concept: n.target, depth: depth + 1));
    }
  }

  return RetrievalResult(
    mode: RetrievalMode.graph,
    items: out,
    seeds: seeded.seeds.map((c) => c.relpath).toList(),
  );
}

/// Cuts [text] to [tokens] **including** the marker, preferring a paragraph
/// then a line boundary so a truncated concept still ends on something
/// readable.
///
/// The marker's own cost is subtracted before cutting. It is the only path
/// that can exceed the retrieval budget, and a ceiling that the explanation of
/// the ceiling breaks is not a ceiling.
String _truncateToTokens(String text, int tokens) {
  const marker = '\n\n[truncated to fit the context window]';
  final budgetChars = (tokens * kCharsPerToken).floor();
  if (text.length <= budgetChars) return text;

  final maxChars = budgetChars - marker.length;
  if (maxChars <= 0) return '';

  final para = text.lastIndexOf('\n\n', maxChars);
  final cut = para > maxChars ~/ 2 ? para : text.lastIndexOf('\n', maxChars);
  return '${text.substring(0, cut > maxChars ~/ 2 ? cut : maxChars).trimRight()}$marker';
}
