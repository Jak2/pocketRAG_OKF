import 'package:langchain/langchain.dart';

import 'llm_engine.dart';

/// Options for [LlmEngineChatModel].
///
/// The underlying [LlmEngine] implementations own their own sampling settings,
/// so nothing here is forwarded to them yet — this exists because
/// `ChatModelOptions` is abstract and `SimpleChatModel` needs a concrete
/// instance.
// ponytail: no extra fields; add them when an engine can actually honour them.
class LlmEngineChatModelOptions extends ChatModelOptions {
  const LlmEngineChatModelOptions({
    super.model,
    super.tools,
    super.toolChoice,
    super.concurrencyLimit,
  });

  @override
  LlmEngineChatModelOptions copyWith({
    String? model,
    List<ToolSpec>? tools,
    ChatToolChoice? toolChoice,
    int? concurrencyLimit,
  }) {
    return LlmEngineChatModelOptions(
      model: model ?? this.model,
      tools: tools ?? this.tools,
      toolChoice: toolChoice ?? this.toolChoice,
      concurrencyLimit: concurrencyLimit ?? this.concurrencyLimit,
    );
  }
}

/// Makes any of this app's [LlmEngine]s a first-class LangChain chat model.
///
/// Works for the on-device llama.cpp engine and the cloud API engine alike —
/// no Ollama server, no separate integration package. LangChain chains,
/// prompt templates, memory and output parsers can be pointed at this.
///
/// Messages are flattened into the same plain-text transcript
/// `GeneralChatScreen._buildPrompt()` produces, including the trailing
/// `Assistant:` cue, because `kStopSequences` in the on-device engine depends
/// on exactly that shape.
class LlmEngineChatModel extends SimpleChatModel<LlmEngineChatModelOptions> {
  LlmEngineChatModel(this.engine, {String? model})
      : super(defaultOptions: LlmEngineChatModelOptions(model: model));

  final LlmEngine engine;

  @override
  String get modelType => 'llm-engine';

  @override
  Future<String> callInternal(
    List<ChatMessage> messages, {
    LlmEngineChatModelOptions? options,
  }) {
    return engine.generate(transcriptFor(messages));
  }

  /// The plain-text prompt [messages] are flattened into.
  ///
  /// System messages become the preamble; every other message becomes one
  /// `Role: text` line under `Conversation so far:`; the prompt always ends
  /// with the `Assistant:` cue.
  static String transcriptFor(List<ChatMessage> messages) {
    final buffer = StringBuffer();
    for (final m in messages.whereType<SystemChatMessage>()) {
      buffer
        ..writeln(m.content)
        ..writeln();
    }
    buffer.writeln('Conversation so far:');
    for (final m in messages) {
      final role = switch (m) {
        SystemChatMessage() => null,
        HumanChatMessage() => 'User',
        AIChatMessage() => 'Assistant',
        ToolChatMessage() => 'Tool',
        CustomChatMessage(:final role) => role,
      };
      if (role != null) buffer.writeln('$role: ${m.contentAsString}');
    }
    // Cue the model that it is the assistant's turn — same reason as
    // _buildPrompt(): without it the model role-plays both sides.
    buffer.write('Assistant:');
    return buffer.toString();
  }

  /// Not supported: neither engine exposes a tokenizer, and a word-count guess
  /// would be a fabricated metric.
  @override
  Future<List<int>> tokenize(
    PromptValue promptValue, {
    LlmEngineChatModelOptions? options,
  }) {
    throw UnsupportedError(
      'LlmEngineChatModel cannot tokenize: the underlying LlmEngine exposes no '
      'tokenizer.',
    );
  }
}
