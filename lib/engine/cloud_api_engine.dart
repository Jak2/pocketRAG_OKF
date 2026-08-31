import 'package:dio/dio.dart';
import 'generation_event.dart';
import 'llm_engine.dart';

class CloudApiEngine implements LlmEngine {
  final Dio client;
  final String apiKey;
  final String endpoint;
  final String model;
  final Map<String, String> extraHeaders;

  CloudApiEngine({
    required this.client,
    required this.apiKey,
    required this.endpoint,
    this.model = '',
    this.extraHeaders = const {},
  });

  @override
  Future<String> generate(String prompt) => bufferStream(generateStream(prompt));

  /// No SSE here — the cloud endpoint returns one response, which is wrapped in
  /// the event API so the UI has a single code path for both engines.
  @override
  Stream<GenerationEvent> generateStream(String prompt) async* {
    yield const GenerationStatus('contacting API…');
    // ponytail: failures propagate as stream errors rather than a
    // GenerationError event, so callers keep the original DioException (with
    // its request context) instead of a type-erased Exception. Nothing is
    // swallowed — the UI's onError renders it.
    final text = await _requestCompletion(prompt);
    yield const GenerationStatus('response received');
    yield GenerationToken(text);
    yield GenerationDone(text);
  }

  Future<String> _requestCompletion(String prompt) async {
    final response = await client.post(
      endpoint,
      options: Options(headers: {'Authorization': 'Bearer $apiKey', ...extraHeaders}),
      data: {'prompt': prompt, if (model.isNotEmpty) 'model': model},
    );
    final data = response.data;
    if (data is! Map || data['content'] is! String) {
      throw DioException(
        requestOptions: response.requestOptions,
        message: 'Unexpected response shape from cloud LLM endpoint',
      );
    }
    return data['content'] as String;
  }
}
