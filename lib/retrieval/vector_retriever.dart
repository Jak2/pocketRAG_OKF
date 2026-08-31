import 'corpus.dart';
import 'retrieval_result.dart';
import 'tokens.dart';
import 'vector_index.dart';

/// Re-weights one memory chunk's fused score. Returns the adjusted score.
typedef MemoryBoost = double Function(String memoryId, double score);

/// Fraction of a concept that, once retrieved as separate chunks, is better
/// served as the whole file — cheaper in tokens and strictly more coherent.
const double kWholeFileThreshold = 0.6;

/// Hybrid chunk retrieval: dense cosine fused with BM25 via reciprocal rank
/// fusion.
///
/// RRF rather than a weighted blend because it needs no tuned alpha and no
/// per-list score normalisation. Pure cosine from a small on-device embedding
/// model is weak on rare proper nouns, which is exactly where BM25 is strong.
///
/// [queryVector] is null when no embedding model is loaded; retrieval then
/// degrades to BM25 alone rather than returning nothing.
RetrievalResult vectorRetrieve(
  Corpus corpus,
  String query, {
  required int budgetTokens,
  List<double>? queryVector,
  int candidates = 20,
  MemoryBoost? boostMemory,
}) {
  if (corpus.chunks.isEmpty) {
    return const RetrievalResult(mode: RetrievalMode.vector, items: []);
  }

  final lexicalHits = corpus.chunkIndex.search(query, limit: candidates);
  final denseHits = (queryVector != null && corpus.hasEmbeddings)
      ? corpus.vectors.search(queryVector, limit: candidates)
      : const <({int chunkIndex, double score})>[];

  final lexical = lexicalHits.map((h) => int.parse(h.id)).toList();
  final dense = denseHits.map((h) => h.chunkIndex).toList();

  // Kept alongside the fused ranking: RRF orders results well but says nothing
  // about whether anything matched at all, which is exactly what the
  // post-retrieval fallback needs to know.
  final bestLexical = lexicalHits.isEmpty ? 0.0 : lexicalHits.first.score;
  final bestDense = (queryVector != null && corpus.hasEmbeddings)
      ? (denseHits.isEmpty ? 0.0 : denseHits.first.score)
      : null;

  final fused = reciprocalRankFusion<int>([if (dense.isNotEmpty) dense, if (lexical.isNotEmpty) lexical]);
  if (fused.isEmpty) {
    return RetrievalResult(
        mode: RetrievalMode.vector, items: const [], bestLexical: bestLexical, bestDense: bestDense);
  }

  // A fact the user leans on repeatedly should outrank a marginally closer one
  // they have never touched. Applied before ranking so the boost can actually
  // change the order rather than just the reported score.
  if (boostMemory != null) {
    for (final entry in fused.entries.toList()) {
      final memoryId = corpus.chunks[entry.key].memoryId;
      if (memoryId != null) fused[entry.key] = boostMemory(memoryId, entry.value);
    }
  }

  final ranked = fused.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

  // Promote to whole files: two chunks of the same concept that together cover
  // most of it cost more, and read worse, than the file they came from.
  final perConcept = <String, int>{};
  for (final e in ranked) {
    final path = corpus.chunks[e.key].conceptPath;
    if (path != null) perConcept.update(path, (t) => t + corpus.chunks[e.key].nTokens, ifAbsent: () => corpus.chunks[e.key].nTokens);
  }

  final items = <RetrievedItem>[];
  final emittedConcepts = <String>{};
  var used = 0;

  for (final entry in ranked) {
    final chunk = corpus.chunks[entry.key];
    final path = chunk.conceptPath;

    if (path != null) {
      if (emittedConcepts.contains(path)) continue;
      final concept = corpus.bundle.byPath(path);
      final wholeTokens = concept == null ? 0 : estimateTokens(concept.body);
      if (concept != null &&
          wholeTokens > 0 &&
          (perConcept[path] ?? 0) >= wholeTokens * kWholeFileThreshold &&
          used + wholeTokens <= budgetTokens) {
        items.add(RetrievedItem.fromConcept(concept, score: entry.value));
        emittedConcepts.add(path);
        used += wholeTokens;
        continue;
      }
    }

    if (used + chunk.nTokens > budgetTokens) continue;
    items.add(RetrievedItem.fromChunk(
      chunk,
      type: path == null ? 'memory' : corpus.bundle.byPath(path)?.type,
      score: entry.value,
    ));
    used += chunk.nTokens;
  }

  return RetrievalResult(
      mode: RetrievalMode.vector, items: items, bestLexical: bestLexical, bestDense: bestDense);
}
