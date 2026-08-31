// test/engine/cloud_api_engine_test.dart
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rag_okf/engine/cloud_api_engine.dart';
import 'package:pocket_rag_okf/engine/generation_event.dart';

void main() {
  test('generate posts prompt and returns content field', () async {
    final dio = Dio();
    dio.httpClientAdapter = _FakeAdapter((options) {
      expect(options.headers['Authorization'], 'Bearer test-key');
      expect(options.data, {'prompt': 'hello', 'model': 'test-model'});
      return ResponseBody.fromString(
        '{"content": "structured output"}',
        200,
        headers: {'content-type': ['application/json']},
      );
    });
    final engine = CloudApiEngine(
      client: dio,
      apiKey: 'test-key',
      endpoint: 'https://example.com/generate',
      model: 'test-model',
    );

    final result = await engine.generate('hello');

    expect(result, 'structured output');
  });

  test('generate throws when response has no content field', () async {
    final dio = Dio();
    dio.httpClientAdapter = _FakeAdapter((options) {
      return ResponseBody.fromString('{"unexpected": true}', 200,
          headers: {'content-type': ['application/json']});
    });
    final engine = CloudApiEngine(
      client: dio,
      apiKey: 'test-key',
      endpoint: 'https://example.com/generate',
    );

    expect(() => engine.generate('hello'), throwsA(isA<DioException>()));
  });

  test('generateStream emits status, token, then done', () async {
    final dio = Dio();
    dio.httpClientAdapter = _FakeAdapter((options) {
      return ResponseBody.fromString('{"content": "hello"}', 200,
          headers: {'content-type': ['application/json']});
    });
    final engine = CloudApiEngine(
      client: dio,
      apiKey: 'test-key',
      endpoint: 'https://example.com/generate',
    );

    final events = await engine.generateStream('hi').toList();

    expect(events.whereType<GenerationStatus>(), isNotEmpty);
    expect(events.whereType<GenerationToken>().single.text, 'hello');
    expect(events.whereType<GenerationDone>().single.fullText, 'hello');
    expect(events.whereType<GenerationError>(), isEmpty);
  });
}

class _FakeAdapter implements HttpClientAdapter {
  final ResponseBody Function(RequestOptions) handler;
  _FakeAdapter(this.handler);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? requestStream,
      Future<void>? cancelFuture) async {
    return handler(options);
  }
}
