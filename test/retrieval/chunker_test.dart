// test/retrieval/chunker_test.dart
//
// Chunk boundaries decide what vector retrieval can ever find, so the two
// things that matter are that nothing is silently dropped and that the overlap
// really exists.
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rag_okf/retrieval/chunker.dart';
import 'package:pocket_rag_okf/retrieval/tokens.dart';

/// A paragraph of [chars] characters made of distinct words, so an overlap can
/// be located by content rather than guessed at.
String _paragraph(String prefix, int chars) {
  final buffer = StringBuffer();
  var i = 0;
  while (buffer.length < chars) {
    buffer.write('$prefix$i ');
    i++;
  }
  return buffer.toString().substring(0, chars).trim();
}

void main() {
  group('chunkText', () {
    test('empty and whitespace-only input produce no chunks at all', () {
      expect(chunkText(''), isEmpty);
      expect(chunkText('   \n\n \t '), isEmpty);
    });

    test('text under the target is returned as a single trimmed chunk', () {
      final chunks = chunkText('\n  A short concept body.\n\nWith two paragraphs.  \n');
      expect(chunks.length, 1);
      expect(chunks.single, 'A short concept body.\n\nWith two paragraphs.');
    });

    test('long text splits on paragraph boundaries rather than mid-sentence', () {
      final a = _paragraph('alpha', 400);
      final b = _paragraph('bravo', 400);
      final c = _paragraph('charlie', 400);
      final chunks = chunkText('$a\n\n$b\n\n$c');

      expect(chunks.length, greaterThan(1));
      // Each paragraph survives intact somewhere; a boundary split never cuts
      // one in half.
      expect(chunks.any((ch) => ch.contains(a)), isTrue);
      expect(chunks.any((ch) => ch.contains(b)), isTrue);
      expect(chunks.any((ch) => ch.contains(c)), isTrue);
    });

    test('overlap repeats the tail of the previous chunk into the next', () {
      // A fact written across a boundary has to be retrievable from either
      // side, which only works if the repetition is real.
      final a = _paragraph('alpha', 400);
      final b = _paragraph('bravo', 400);
      final chunks = chunkText('$a\n\n$b');

      expect(chunks.length, 2);
      expect(chunks[1], contains(a.substring(a.length - 100)));
      expect(chunks[1], contains(b));
    });

    test('a single paragraph longer than the target is hard-cut, never dropped', () {
      final huge = _paragraph('word', 3000);
      final chunks = chunkText(huge);

      expect(chunks.length, greaterThan(1));
      expect(chunks.first, isNotEmpty);
      // The opening and the closing text both have to still be somewhere.
      expect(chunks.first, contains('word0 '));
      expect(chunks.last, contains(huge.substring(huge.length - 20)));
    });

    test('a hard cut also overlaps, so a term on the cut point survives', () {
      final huge = _paragraph('word', 3000);
      final chunks = chunkText(huge);
      expect(chunks[0], contains(chunks[1].substring(0, 40)));
    });

    test('every chunk of a long body stays near the target size', () {
      final chunks = chunkText(List.generate(20, (i) => _paragraph('p$i', 300)).join('\n\n'));
      for (final chunk in chunks) {
        // The overlap is added on top of the target, so allow for it rather
        // than asserting an exact ceiling.
        expect(estimateTokens(chunk), lessThanOrEqualTo(220 + 40));
      }
    });

    test('honours a custom target and overlap', () {
      final chunks = chunkText(_paragraph('tiny', 2000), targetTokens: 20, overlapTokens: 5);
      expect(chunks.length, greaterThan(10));
      for (final chunk in chunks) {
        expect(chunk.length, lessThanOrEqualTo((20 * kCharsPerToken).floor()));
      }
    });
  });

  group('Chunk', () {
    test('a chunk has exactly one owner', () {
      expect(() => Chunk(ord: 0, text: 'x'), throwsA(isA<AssertionError>()));
      expect(() => Chunk(ord: 0, text: 'x', conceptPath: 'a.md', memoryId: 'm1'),
          throwsA(isA<AssertionError>()));
    });

    test('survives a json round trip', () {
      const chunk = Chunk(ord: 3, text: 'hello', conceptPath: 'a.md');
      final back = Chunk.fromJson(chunk.toJson());
      expect(back.ord, 3);
      expect(back.text, 'hello');
      expect(back.conceptPath, 'a.md');
      expect(back.memoryId, isNull);
    });
  });
}
