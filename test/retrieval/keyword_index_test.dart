// test/retrieval/keyword_index_test.dart
//
// BM25 here is hand-rolled, so the two properties worth pinning are the field
// weighting (a title hit must beat a body hit) and the IDF floor (a word in
// every document must not decide a ranking).
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rag_okf/retrieval/keyword_index.dart';

/// Filler that shares no terms with any query in this file, used to give
/// documents a realistic length so the length normalisation is exercised.
String _filler(int words) => List.generate(words, (i) => 'filler$i').join(' ');

void main() {
  group('tokenize', () {
    test('lowercases and splits on non-alphanumerics', () {
      expect(tokenize('Daily-Active_Users (2024)'), ['daily', 'active', 'users', '2024']);
    });

    test('drops one- and two-character tokens', () {
      // Two-letter tokens are almost all noise and blow up the postings list.
      expect(tokenize('a bc def gh ijkl'), ['def', 'ijkl']);
    });

    test('drops stopwords', () {
      expect(tokenize('the and for what when your about'), isEmpty);
    });

    test('a query of nothing but stopwords tokenizes to nothing', () {
      expect(tokenize('what are the'), isEmpty);
    });
  });

  group('KeywordIndex.search', () {
    test('a title match outranks the same term buried in a body', () {
      final index = KeywordIndex()
        ..add('titled.md', title: 'zebra migration', body: _filler(60))
        ..add('bodied.md', title: 'unrelated heading', body: 'zebra ${_filler(60)}');

      final hits = index.search('zebra');
      expect(hits.first.id, 'titled.md');
      expect(hits.first.score, greaterThan(hits.last.score));
    });

    test('description and tag matches also outrank a plain body match', () {
      final index = KeywordIndex()
        ..add('described.md', title: 'heading', description: 'zebra herds', body: _filler(60))
        ..add('tagged.md', title: 'heading', tags: 'zebra', body: _filler(60))
        ..add('bodied.md', title: 'heading', body: 'zebra ${_filler(60)}');

      final hits = index.search('zebra');
      expect(hits.last.id, 'bodied.md');
    });

    test('restrictTo narrows the candidate set to the given ids', () {
      final index = KeywordIndex()
        ..add('a.md', title: 'zebra', body: _filler(20))
        ..add('b.md', title: 'zebra', body: _filler(20))
        ..add('c.md', title: 'zebra', body: _filler(20));

      final hits = index.search('zebra', restrictTo: {'b.md'});
      expect(hits.map((h) => h.id), ['b.md']);
    });

    test('restrictTo with no overlap returns nothing rather than everything', () {
      final index = KeywordIndex()..add('a.md', title: 'zebra', body: _filler(20));
      expect(index.search('zebra', restrictTo: {'nope.md'}), isEmpty);
    });

    test('a term present in every document contributes far less than a rare one', () {
      // The IDF floor is what stops a corpus-wide word like the project name
      // from dominating every ranking.
      final index = KeywordIndex();
      for (var i = 0; i < 5; i++) {
        index.add('doc$i.md', title: 'ubiquitous heading', body: 'ubiquitous ${_filler(20)}');
      }
      index.add('rare.md', title: 'ubiquitous heading', body: 'ubiquitous quokka ${_filler(20)}');

      final common = index.search('ubiquitous').first.score;
      final rare = index.search('quokka').first.score;
      expect(common, lessThan(rare / 4));
    });

    test('a term in literally every document never scores below zero', () {
      final index = KeywordIndex();
      for (var i = 0; i < 3; i++) {
        index.add('doc$i.md', title: 'shared', body: 'shared');
      }
      for (final hit in index.search('shared')) {
        expect(hit.score, greaterThanOrEqualTo(0));
      }
    });

    test('an empty query returns nothing', () {
      final index = KeywordIndex()..add('a.md', title: 'zebra', body: 'zebra');
      expect(index.search(''), isEmpty);
      expect(index.search('   '), isEmpty);
    });

    test('a query of only stopwords and short tokens returns nothing', () {
      final index = KeywordIndex()..add('a.md', title: 'the and for', body: 'the and for');
      expect(index.search('the and of it'), isEmpty);
    });

    test('an empty index returns nothing', () {
      expect(KeywordIndex().search('zebra'), isEmpty);
      expect(KeywordIndex().documentCount, 0);
    });

    test('a term that appears in no document returns nothing', () {
      final index = KeywordIndex()..add('a.md', title: 'zebra', body: 'zebra');
      expect(index.search('quokka'), isEmpty);
    });

    test('limit caps the number of hits', () {
      final index = KeywordIndex();
      for (var i = 0; i < 10; i++) {
        index.add('doc$i.md', title: 'zebra', body: _filler(i + 1));
      }
      expect(index.search('zebra', limit: 3).length, 3);
    });

    test('a document with no indexable terms is counted but never retrieved', () {
      final index = KeywordIndex()
        ..add('empty.md', title: 'a of', body: '')
        ..add('real.md', title: 'zebra', body: 'zebra');
      expect(index.documentCount, 2);
      expect(index.search('zebra').map((h) => h.id), ['real.md']);
    });

    test('multiple query terms accumulate, so a document matching both wins', () {
      final index = KeywordIndex()
        ..add('both.md', title: 'zebra quokka', body: _filler(20))
        ..add('one.md', title: 'zebra herd', body: _filler(20));
      expect(index.search('zebra quokka').first.id, 'both.md');
    });
  });
}
