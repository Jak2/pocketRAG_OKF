/// One observable step in an LLM generation. Engines emit these so the UI can
/// distinguish "thinking" from "stuck" — a distinction the old buffered
/// `Future<String>` API could not express.
sealed class GenerationEvent {
  const GenerationEvent();
}

/// A human-readable stage, e.g. "loading model", "prompt sent".
class GenerationStatus extends GenerationEvent {
  final String stage;
  const GenerationStatus(this.stage);
}

/// An incremental chunk of generated text.
class GenerationToken extends GenerationEvent {
  final String text;
  const GenerationToken(this.text);
}

/// Generation finished successfully. [fullText] is the complete output.
class GenerationDone extends GenerationEvent {
  final String fullText;
  const GenerationDone(this.fullText);
}

/// Generation failed. Always surfaced to the user — never swallowed.
class GenerationError extends GenerationEvent {
  final String message;
  const GenerationError(this.message);
}
