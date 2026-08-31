import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rag_okf/engine/on_device_llama_engine.dart';

void main() {
  group('stop sequences', () {
    test('kStopSequences covers every transcript role', () {
      expect(kStopSequences, contains('\nUser:'));
      expect(kStopSequences, contains('\nAssistant:'));
      expect(kStopSequences, contains('\nSystem:'));
    });

    test('trims at the first stop marker', () {
      const raw = 'Hello there.\nUser: what next?\nAssistant: more';
      expect(trimAtStop(raw), 'Hello there.');
    });

    test('trims at the earliest marker when several appear', () {
      const raw = 'Answer.\nAssistant: dup\nUser: q';
      expect(trimAtStop(raw), 'Answer.');
    });

    test('leaves clean output untouched apart from trimming', () {
      expect(trimAtStop('  A tidy answer.  '), 'A tidy answer.');
    });

    test('does not cut on a role word that is not starting a new line', () {
      // "User:" mid-sentence is legitimate prose, not a new transcript turn.
      const raw = 'The User: prefix is used in logs.';
      expect(trimAtStop(raw), 'The User: prefix is used in logs.');
    });

    test('handles a stop marker at the very start', () {
      expect(trimAtStop('\nUser: hi'), '');
    });
  });
}
