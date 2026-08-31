import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rag_okf/chat/transcript_export.dart';

void main() {
  final at = DateTime.utc(2026, 8, 31, 14, 5);

  const conversation = [
    TranscriptTurn(fromUser: true, text: 'What is the payments retry budget?'),
    TranscriptTurn(
      fromUser: false,
      text: 'Three attempts with exponential backoff.',
      mode: 'OKF',
      sources: ['services/payments/retry-policy.md'],
    ),
    TranscriptTurn(fromUser: true, text: 'And the checkout timeout?'),
  ];

  group('renderTranscript', () {
    test('questions-only keeps every question and no answer', () {
      final out = renderTranscript(turns: conversation, at: at, questionsOnly: true);

      expect(out, contains('1. What is the payments retry budget?'));
      expect(out, contains('2. And the checkout timeout?'));
      expect(out, isNot(contains('exponential backoff')),
          reason: 'the answers are exactly what questions-only exists to drop');
    });

    test('a full transcript keeps answers, the mode, and cited sources', () {
      final out = renderTranscript(turns: conversation, at: at);

      expect(out, contains('## What is the payments retry budget?'));
      expect(out, contains('exponential backoff'));
      expect(out, contains('Answered via OKF'));
      // A markdown link, not bare text: an export dropped into the bundle then
      // links back into the concepts it cited, so the graph walk can follow it.
      expect(out, contains('- [services/payments/retry-policy.md](services/payments/retry-policy.md)'));
    });

    test('the frontmatter is parseable by the app that wrote it', () {
      final out = renderTranscript(turns: conversation, at: at, questionsOnly: true);
      final lines = out.split('\n');

      expect(lines.first, '---');
      expect(lines, contains('type: questions'));
      expect(out, contains('created: 2026-08-31T14:05:00.000Z'));
    });

    test('a title containing a colon is quoted so the frontmatter still splits', () {
      // The app's own parser splits on the first colon, so an unquoted title
      // like "Bug: retries" would parse as key "Bug".
      final out = renderTranscript(
        turns: conversation,
        at: at,
        title: 'Bug: retries fire twice',
      );
      expect(out, contains('title: "Bug: retries fire twice"'));
    });

    test('a multi-line question collapses to one heading', () {
      final out = renderTranscript(
        turns: const [TranscriptTurn(fromUser: true, text: 'Why does\n  this fail?')],
        at: at,
      );
      expect(out, contains('## Why does this fail?'));
    });

    test('an empty session says so rather than emitting a bare header', () {
      expect(renderTranscript(turns: const [], at: at), contains('This session is empty'));
      expect(renderTranscript(turns: const [], at: at, questionsOnly: true),
          contains('No questions were asked'));
    });

    test('an answer-only session produces no questions list', () {
      final out = renderTranscript(
        turns: const [TranscriptTurn(fromUser: false, text: 'Orphan answer.')],
        at: at,
        questionsOnly: true,
      );
      expect(out, contains('No questions were asked'));
    });
  });

  group('transcriptFileName', () {
    test('is sortable and says which kind of export it is', () {
      expect(transcriptFileName(at), '2026-08-31-1405-transcript.md');
      expect(transcriptFileName(at, questionsOnly: true), '2026-08-31-1405-questions.md');
    });

    test('pads single-digit components so names sort lexically', () {
      expect(transcriptFileName(DateTime.utc(2026, 1, 2, 3, 4)), '2026-01-02-0304-transcript.md');
    });
  });
}
