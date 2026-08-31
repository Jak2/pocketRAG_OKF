import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rag_okf/okf/bundle.dart';
import 'package:pocket_rag_okf/okf/concept.dart';
import 'package:pocket_rag_okf/retrieval/chunker.dart';
import 'package:pocket_rag_okf/retrieval/corpus.dart';
import 'package:pocket_rag_okf/retrieval/vector_retriever.dart';
import 'dart:io';

/// A corpus holding one concept chunk and one memory chunk that both match the
/// query, so only the boost can decide which ranks first.
Corpus _corpusWithMemory() {
  final bundle = Bundle(
    id: 'test',
    root: Directory('/nonexistent'),
    contentHash: 'hash',
    concepts: const [
      Concept(relpath: 'a.md', title: 'Coffee notes', body: 'coffee brewing grind ratio'),
    ],
  );
  final corpus = Corpus.build(bundle);
  corpus.chunkIndex.add('${corpus.chunks.length}', body: 'coffee brewing grind ratio');
  corpus.chunks.add(const Chunk(memoryId: 'm1', ord: 0, text: 'coffee brewing grind ratio'));
  return corpus;
}

void main() {
  group('memory boost', () {
    test('the boost changes the ranking, not just the reported score', () {
      final corpus = _corpusWithMemory();

      // The memory chunk already wins on fused rank here — BM25 length
      // normalisation favours the shorter document — so the decisive check is
      // that suppressing it demotes it and boosting it keeps it on top.
      final suppressed = vectorRetrieve(
        corpus,
        'coffee brewing grind',
        budgetTokens: 4000,
        boostMemory: (id, score) => score * 0.01,
      );
      final boosted = vectorRetrieve(
        corpus,
        'coffee brewing grind',
        budgetTokens: 4000,
        // Stands in for memoryScore's recency/usage multiplier.
        boostMemory: (id, score) => score * 10,
      );

      expect(suppressed.items.first.source, 'a.md',
          reason: 'a demoted memory fact must fall below the concept chunk');
      expect(boosted.items.first.source, 'memory:m1',
          reason: 'the boost has to reach the ordering, not only the score field');
    });

    test('the boost never touches concept chunks', () {
      final corpus = _corpusWithMemory();
      var called = <String>[];

      vectorRetrieve(
        corpus,
        'coffee brewing grind',
        budgetTokens: 4000,
        boostMemory: (id, score) {
          called.add(id);
          return score;
        },
      );

      expect(called, ['m1'], reason: 'only memory chunks carry a memoryId to boost');
    });
  });
}
