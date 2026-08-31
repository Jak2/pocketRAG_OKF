import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rag_okf/engine/generation_event.dart';
import 'package:pocket_rag_okf/engine/llm_engine.dart';

class _FakeEngine implements LlmEngine {
  final List<GenerationEvent> events;
  _FakeEngine(this.events);

  @override
  Stream<GenerationEvent> generateStream(String prompt) async* {
    for (final e in events) {
      yield e;
    }
  }

  @override
  Future<String> generate(String prompt) => bufferStream(generateStream(prompt));
}

void main() {
  test('bufferStream concatenates tokens into the final string', () async {
    final engine = _FakeEngine(const [
      GenerationStatus('prompt sent'),
      GenerationToken('Hello '),
      GenerationToken('world'),
      GenerationDone('Hello world'),
    ]);
    expect(await engine.generate('hi'), 'Hello world');
  });

  test('bufferStream throws on an error event instead of returning empty', () async {
    final engine = _FakeEngine(const [
      GenerationStatus('prompt sent'),
      GenerationError('model exploded'),
    ]);
    expect(() => engine.generate('hi'), throwsA(isA<Exception>()));
  });

  test('bufferStream throws when the stream ends with no done event', () async {
    final engine = _FakeEngine(const [GenerationToken('partial')]);
    expect(() => engine.generate('hi'), throwsA(isA<Exception>()));
  });
}
