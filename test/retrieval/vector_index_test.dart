// test/retrieval/vector_index_test.dart
//
// A flat cosine scan has few places to hide bugs; the ones it does have are
// degenerate vectors and a stale cache with the wrong dimensionality, which
// must be skipped rather than crash a query mid-flight.
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rag_okf/retrieval/vector_index.dart';

void main() {
  group('cosine', () {
    test('identical vectors are 1', () {
      expect(cosine([1, 2, 3], [1, 2, 3]), closeTo(1.0, 1e-12));
    });

    test('a scaled copy is still 1 — magnitude carries no meaning', () {
      expect(cosine([1, 2, 3], [10, 20, 30]), closeTo(1.0, 1e-12));
    });

    test('orthogonal vectors are 0', () {
      expect(cosine([1, 0], [0, 1]), closeTo(0.0, 1e-12));
    });

    test('opposed vectors are -1', () {
      expect(cosine([1, 0], [-1, 0]), closeTo(-1.0, 1e-12));
    });

    test('degenerate input scores 0 instead of producing NaN', () {
      // A zero vector out of a failed embed would otherwise poison every
      // comparison with NaN, which sorts unpredictably.
      expect(cosine([0, 0], [1, 1]), 0);
      expect(cosine([], []), 0);
      expect(cosine([1, 2], [1, 2, 3]), 0);
    });
  });

  group('VectorIndex.search', () {
    test('ranks by cosine, closest first', () {
      final index = VectorIndex()
        ..add(0, [1, 0, 0])
        ..add(1, [0.9, 0.1, 0])
        ..add(2, [0, 1, 0]);

      final hits = index.search([1, 0, 0]);
      expect(hits.map((h) => h.chunkIndex), [0, 1, 2]);
      expect(hits.first.score, closeTo(1.0, 1e-12));
    });

    test('entries with the wrong dimensionality are skipped, not crashed on', () {
      // This is what a vector cache left over from a different embedding model
      // looks like at query time.
      final index = VectorIndex()
        ..add(0, [1, 0, 0])
        ..add(1, [1, 0])
        ..add(2, [1, 0, 0, 0]);

      final hits = index.search([1, 0, 0]);
      expect(hits.map((h) => h.chunkIndex), [0]);
    });

    test('zero-magnitude entries are skipped', () {
      final index = VectorIndex()
        ..add(0, [0, 0, 0])
        ..add(1, [1, 0, 0]);
      expect(index.search([1, 0, 0]).map((h) => h.chunkIndex), [1]);
    });

    test('an empty index, an empty query and a zero query all return nothing', () {
      expect(VectorIndex().search([1, 0]), isEmpty);
      final index = VectorIndex()..add(0, [1, 0]);
      expect(index.search(const []), isEmpty);
      expect(index.search([0, 0]), isEmpty);
    });

    test('limit caps the result count', () {
      final index = VectorIndex();
      for (var i = 0; i < 10; i++) {
        index.add(i, [1, i.toDouble()]);
      }
      expect(index.search([1, 0], limit: 3).length, 3);
    });

    test('clear empties the index', () {
      final index = VectorIndex()..add(0, [1, 0]);
      expect(index.isEmpty, isFalse);
      index.clear();
      expect(index.isEmpty, isTrue);
      expect(index.length, 0);
    });

    test('toLists and chunkIndices stay aligned for the cache', () {
      final index = VectorIndex()
        ..add(7, [1, 0])
        ..add(9, [0, 1]);
      expect(index.chunkIndices(), [7, 9]);
      expect(index.toLists(), [
        [1, 0],
        [0, 1],
      ]);
    });
  });

  group('reciprocalRankFusion', () {
    test('a document ranked highly in both lists beats one ranked highly in only one', () {
      // This is the whole reason RRF is used instead of a tuned score blend.
      final fused = reciprocalRankFusion<String>([
        ['both', 'lexical-only'],
        ['dense-only', 'both'],
      ]);
      expect(fused['both'], greaterThan(fused['dense-only']!));
      expect(fused['both'], greaterThan(fused['lexical-only']!));
    });

    test('within one list, earlier ranks score higher', () {
      final fused = reciprocalRankFusion<String>([
        ['a', 'b', 'c'],
      ]);
      expect(fused['a'], greaterThan(fused['b']!));
      expect(fused['b'], greaterThan(fused['c']!));
    });

    test('a single top hit scores 1/(k+1), which is small by construction', () {
      // kMinVectorScore is calibrated against this number, so it is worth
      // pinning rather than leaving implicit.
      final fused = reciprocalRankFusion<String>([
        ['a'],
      ]);
      expect(fused['a'], closeTo(1 / 61, 1e-12));
    });

    test('no rankings, and empty rankings, fuse to nothing', () {
      expect(reciprocalRankFusion<String>([]), isEmpty);
      expect(reciprocalRankFusion<String>([[], []]), isEmpty);
    });

    test('k flattens the difference between ranks as it grows', () {
      final tight = reciprocalRankFusion<String>([
        ['a', 'b'],
      ], k: 1);
      final loose = reciprocalRankFusion<String>([
        ['a', 'b'],
      ], k: 1000);
      expect(tight['a']! - tight['b']!, greaterThan(loose['a']! - loose['b']!));
    });
  });
}
