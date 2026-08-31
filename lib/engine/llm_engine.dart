import 'generation_event.dart';

abstract class LlmEngine {
  /// Buffered generation, kept for non-interactive callers (the structuring
  /// flow). Implement it as `bufferStream(generateStream(prompt))` so there is
  /// a single code path.
  Future<String> generate(String prompt);

  /// Observable generation. Emits status, tokens, then exactly one
  /// [GenerationDone] — or one [GenerationError].
  Stream<GenerationEvent> generateStream(String prompt);
}

/// Collapses an event stream into the final text.
///
/// Throws on [GenerationError], and throws if the stream ends without a
/// [GenerationDone] — returning an empty string there would reproduce exactly
/// the "silent, no output, no error" failure this work exists to fix.
Future<String> bufferStream(Stream<GenerationEvent> events) async {
  final buffer = StringBuffer();
  var done = false;
  String? result;

  await for (final event in events) {
    switch (event) {
      case GenerationStatus():
        break;
      case GenerationToken(:final text):
        buffer.write(text);
      case GenerationDone(:final fullText):
        done = true;
        result = fullText.isEmpty ? buffer.toString() : fullText;
      case GenerationError(:final message):
        throw Exception(message);
    }
  }

  if (!done) {
    throw Exception('Generation ended without completing (no done event)');
  }
  return result ?? buffer.toString();
}
