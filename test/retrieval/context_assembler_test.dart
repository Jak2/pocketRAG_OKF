// test/retrieval/context_assembler_test.dart
//
// Everything here is about not overspending a context window that is small and
// fixed, and about provenance surviving into the prompt — on an offline model,
// the source attribute is the only defence against confabulation.
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rag_okf/retrieval/context_assembler.dart';
import 'package:pocket_rag_okf/retrieval/retrieval_result.dart';
import 'package:pocket_rag_okf/retrieval/tokens.dart';

/// Text of roughly [tokens] estimated tokens.
String _text(String seed, int tokens) {
  final chars = (tokens * kCharsPerToken).floor();
  final buffer = StringBuffer();
  while (buffer.length < chars) {
    buffer.write('$seed ');
  }
  return buffer.toString().substring(0, chars);
}

RetrievedItem _item(String source, int tokens, {double score = 1}) =>
    RetrievedItem(source: source, text: _text(source.replaceAll(RegExp(r'\W'), ''), tokens), score: score);

void main() {
  group('retrievalBudget', () {
    test('leaves room for the reply, the system prompt and the history', () {
      final budget = retrievalBudget(
        contextTokens: 4096,
        systemPrompt: _text('sys', 100),
        history: [_text('turn', 50)],
      );
      expect(budget, 4096 - kReserveOutput - 100 - 50);
    });

    test('never returns a negative budget, however greedy the prompt', () {
      // A negative budget would be handed straight to a `used + cost > budget`
      // comparison and silently retrieve nothing; zero is at least honest.
      expect(
        retrievalBudget(contextTokens: 512, systemPrompt: _text('sys', 5000), history: const []),
        0,
      );
      expect(retrievalBudget(contextTokens: 0, systemPrompt: '', history: const []), 0);
    });

    test('history is capped at its share of the window no matter how long it is', () {
      final budget = retrievalBudget(
        contextTokens: 4096,
        systemPrompt: '',
        history: List.generate(50, (i) => _text('turn$i', 200)),
      );
      final cap = (4096 * kHistoryShare).floor();
      expect(budget, 4096 - kReserveOutput - cap);
    });

    test('a short history costs only what it actually is', () {
      final short = retrievalBudget(contextTokens: 4096, systemPrompt: '', history: [_text('t', 10)]);
      final none = retrievalBudget(contextTokens: 4096, systemPrompt: '', history: const []);
      expect(none - short, 10);
    });
  });

  group('renderContext', () {
    test('emits a source attribute for every item', () {
      const result = RetrievalResult(mode: RetrievalMode.graph, items: [
        RetrievedItem(source: 'concepts/alpha.md', text: 'alpha body', type: 'concept'),
        RetrievedItem(source: 'memory:m1', text: 'user prefers dart', type: 'memory'),
        RetrievedItem(source: 'notes/no-type.md', text: 'untyped body'),
      ]);

      final rendered = renderContext(result);
      expect('source="'.allMatches(rendered).length, 3);
      expect(rendered, contains('source="concepts/alpha.md"'));
      expect(rendered, contains('source="memory:m1"'));
      expect(rendered, contains('source="notes/no-type.md"'));
    });

    test('omits the type attribute rather than emitting an empty one', () {
      const result = RetrievalResult(
          mode: RetrievalMode.vector, items: [RetrievedItem(source: 'a.md', text: 'body')]);
      expect(renderContext(result), isNot(contains('type=')));
    });

    test('labels the mode the content came from', () {
      const item = RetrievedItem(source: 'a.md', text: 'body');
      expect(renderContext(const RetrievalResult(mode: RetrievalMode.graph, items: [item])),
          contains('mode="okf"'));
      expect(renderContext(const RetrievalResult(mode: RetrievalMode.vector, items: [item])),
          contains('mode="rag"'));
    });

    test('every block is closed', () {
      const result = RetrievalResult(mode: RetrievalMode.vector, items: [
        RetrievedItem(source: 'a.md', text: '  padded  '),
        RetrievedItem(source: 'b.md', text: 'second'),
      ]);
      final rendered = renderContext(result);
      expect('</context>'.allMatches(rendered).length, 2);
      expect(rendered, contains('\npadded\n'));
    });

    test('an empty result renders nothing at all', () {
      expect(renderContext(const RetrievalResult(mode: RetrievalMode.vector, items: [])), isEmpty);
    });
  });

  group('applyMemoryShare', () {
    test('keeps memory that a stronger topical match would otherwise crowd out', () {
      // Without the reservation the two high-scoring knowledge chunks fill the
      // budget and everything the app knows about the user disappears.
      final result = RetrievalResult(mode: RetrievalMode.vector, items: [
        _item('concepts/a.md', 80, score: 0.9),
        _item('concepts/b.md', 80, score: 0.8),
        _item('memory:m1', 10, score: 0.1),
      ]);

      final kept = applyMemoryShare(result, 100);
      expect(kept.sources, contains('memory:m1'));
      expect(kept.totalTokens, lessThanOrEqualTo(100));
    });

    test('restores the fused ranking after the split by category', () {
      final result = RetrievalResult(mode: RetrievalMode.vector, items: [
        _item('concepts/a.md', 20, score: 0.9),
        _item('memory:m1', 5, score: 0.5),
        _item('concepts/b.md', 20, score: 0.1),
      ]);
      final kept = applyMemoryShare(result, 1000);
      expect(kept.sources, ['concepts/a.md', 'memory:m1', 'concepts/b.md']);
    });

    test('with no memory the whole budget goes to knowledge, untouched', () {
      final result = RetrievalResult(mode: RetrievalMode.vector, items: [
        _item('concepts/a.md', 90, score: 0.9),
        _item('concepts/b.md', 90, score: 0.8),
      ]);
      final kept = applyMemoryShare(result, 200);
      expect(kept.sources, ['concepts/a.md', 'concepts/b.md']);
      expect(kept.totalTokens, greaterThan((200 * (1 - kMemoryShare)).floor()));
    });

    test('with no knowledge the memory items are returned as they are', () {
      final result = RetrievalResult(
          mode: RetrievalMode.vector, items: [_item('memory:m1', 500, score: 0.4)]);
      expect(applyMemoryShare(result, 100).sources, ['memory:m1']);
    });

    test('memory beyond its own share is dropped, not allowed to grow', () {
      final result = RetrievalResult(mode: RetrievalMode.vector, items: [
        _item('memory:m1', 10, score: 0.4),
        _item('memory:m2', 10, score: 0.3),
        _item('memory:m3', 10, score: 0.2),
        _item('concepts/a.md', 50, score: 0.9),
      ]);
      // 15% of 100 is 15 tokens: one memory fact fits, the rest do not.
      final kept = applyMemoryShare(result, 100);
      expect(kept.sources.where((s) => s.startsWith('memory:')), ['memory:m1']);
      expect(kept.sources, contains('concepts/a.md'));
    });

    test('a graph result passes through untouched — whole files are not split', () {
      final result = RetrievalResult(mode: RetrievalMode.graph, items: [
        _item('memory:m1', 500),
        _item('concepts/a.md', 500),
      ]);
      expect(identical(applyMemoryShare(result, 10), result), isTrue);
    });

    test('the absolute weakness signals survive the split', () {
      // The signals describe the retrieval, not the subset that survived the
      // memory reservation. Losing them here reports bestLexical 0, which
      // retrieval_service._isWeak reads as "nothing matched" — firing a
      // fallback on every mixed memory+knowledge result that in fact matched
      // well.
      final result = RetrievalResult(
        mode: RetrievalMode.vector,
        items: [_item('memory:m1', 5, score: 0.9), _item('concepts/a.md', 5, score: 0.5)],
        bestLexical: 3.2,
        bestDense: 0.87,
      );

      final kept = applyMemoryShare(result, 1000);
      expect(kept.sources.length, 2, reason: 'both items fit, so only the signals differ');
      expect(kept.bestLexical, 3.2);
      expect(kept.bestDense, 0.87);
    });

    test('the weakness signals survive when the split is skipped', () {
      // The early return hands back the original object, which is the only
      // reason the common single-category case is not affected by the above.
      final result = RetrievalResult(
        mode: RetrievalMode.vector,
        items: [_item('concepts/a.md', 5, score: 0.5)],
        bestLexical: 3.2,
        bestDense: 0.87,
      );
      final kept = applyMemoryShare(result, 1000);
      expect(kept.bestLexical, 3.2);
      expect(kept.bestDense, 0.87);
    });

    test('seeds survive the split so the "why did I get this" UI still works', () {
      final result = RetrievalResult(
        mode: RetrievalMode.vector,
        items: [_item('memory:m1', 5), _item('concepts/a.md', 5)],
        seeds: const ['concepts/a.md'],
      );
      expect(applyMemoryShare(result, 1000).seeds, ['concepts/a.md']);
    });
  });

  group('buildPrompt', () {
    test('carries the system rules, the context and the question', () {
      final prompt = buildPrompt(
        question: 'what is churn',
        retrieved: const RetrievalResult(
            mode: RetrievalMode.graph, items: [RetrievedItem(source: 'a.md', text: 'churn is x')]),
        history: const [],
        contextTokens: 4096,
      );
      expect(prompt, contains('Cite the `source` attribute'));
      expect(prompt, contains('source="a.md"'));
      expect(prompt, contains('User: what is churn'));
      expect(prompt, endsWith('Assistant:'));
    });

    test('keeps the most recent turns and says how many it dropped', () {
      final prompt = buildPrompt(
        question: 'q',
        retrieved: const RetrievalResult(mode: RetrievalMode.vector, items: []),
        history: List.generate(20, (i) => 'User: ${_text('turn$i', 100)}'),
        contextTokens: 1000,
      );
      expect(prompt, contains('earlier message(s) omitted to fit'));
      expect(prompt, contains('turn19'));
      expect(prompt, isNot(contains('turn0 ')));
    });

    test('omits the context section entirely when nothing was retrieved', () {
      final prompt = buildPrompt(
        question: 'q',
        retrieved: const RetrievalResult(mode: RetrievalMode.vector, items: []),
        history: const [],
        contextTokens: 4096,
      );
      expect(prompt, isNot(contains('<context source=')));
      expect(prompt, isNot(contains('Conversation so far')));
    });
  });
}
