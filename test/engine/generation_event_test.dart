import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rag_okf/engine/generation_event.dart';

void main() {
  test('events expose their payloads', () {
    expect(const GenerationStatus('loading model').stage, 'loading model');
    expect(const GenerationToken('hi').text, 'hi');
    expect(const GenerationDone('hello there').fullText, 'hello there');
    expect(const GenerationError('boom').message, 'boom');
  });

  test('events are exhaustively switchable', () {
    String describe(GenerationEvent e) => switch (e) {
          GenerationStatus() => 'status',
          GenerationToken() => 'token',
          GenerationDone() => 'done',
          GenerationError() => 'error',
        };
    expect(describe(const GenerationStatus('x')), 'status');
    expect(describe(const GenerationToken('x')), 'token');
    expect(describe(const GenerationDone('x')), 'done');
    expect(describe(const GenerationError('x')), 'error');
  });
}
