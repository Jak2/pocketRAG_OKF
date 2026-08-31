import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rag_okf/engine/generation_event.dart';
import 'package:pocket_rag_okf/engine/langchain_chat_model.dart';
import 'package:pocket_rag_okf/engine/llm_engine.dart';
import 'package:langchain/langchain.dart';

/// Records the prompt it was handed and replies with a fixed string.
class _RecordingEngine implements LlmEngine {
  _RecordingEngine(this.reply);

  final String reply;
  String? lastPrompt;

  @override
  Stream<GenerationEvent> generateStream(String prompt) async* {
    lastPrompt = prompt;
    yield GenerationDone(reply);
  }

  @override
  Future<String> generate(String prompt) =>
      bufferStream(generateStream(prompt));
}

void main() {
  const messages = <ChatMessage>[
    SystemChatMessage(content: 'You are a helpful assistant.'),
    HumanChatMessage(content: ChatMessageContentText(text: 'What is 2+2?')),
    AIChatMessage(content: '4'),
    HumanChatMessage(content: ChatMessageContentText(text: 'And 3+3?')),
  ];

  test('flattens system/human/AI messages into the app transcript format', () {
    expect(
      LlmEngineChatModel.transcriptFor(messages),
      'You are a helpful assistant.\n'
      '\n'
      'Conversation so far:\n'
      'User: What is 2+2?\n'
      'Assistant: 4\n'
      'User: And 3+3?\n'
      'Assistant:',
    );
  });

  test('always ends with the Assistant: cue kStopSequences relies on', () {
    expect(LlmEngineChatModel.transcriptFor(const []), endsWith('Assistant:'));
    expect(
      LlmEngineChatModel.transcriptFor(messages),
      endsWith('\nAssistant:'),
    );
  });

  test('passes the transcript to the engine and returns its text', () async {
    final engine = _RecordingEngine('6');
    final model = LlmEngineChatModel(engine);

    final result = await model.call(messages);

    expect(result.content, '6');
    expect(engine.lastPrompt, LlmEngineChatModel.transcriptFor(messages));
  });

  test('works as a LangChain chain component', () async {
    final engine = _RecordingEngine('  Paris  ');
    final chain = ChatPromptTemplate.fromTemplate('Capital of {country}?')
        .pipe(LlmEngineChatModel(engine))
        .pipe(const StringOutputParser());

    expect(await chain.invoke({'country': 'France'}), '  Paris  ');
    expect(engine.lastPrompt, contains('User: Capital of France?'));
  });
}
