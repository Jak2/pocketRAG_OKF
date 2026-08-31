// test/engine/engine_factory_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rag_okf/engine/cloud_api_engine.dart';
import 'package:pocket_rag_okf/engine/on_device_llama_engine.dart';
import 'package:pocket_rag_okf/engine/engine_factory.dart';
import 'package:pocket_rag_okf/settings/engine_settings.dart';

void main() {
  test('returns null for cloud choice with empty endpoint or key', () {
    expect(buildEngine(const EngineSettings(choice: EngineChoice.cloud)), isNull);
    expect(
      buildEngine(const EngineSettings(
        choice: EngineChoice.cloud,
        cloudEndpoint: 'https://x.com',
      )),
      isNull,
    );
  });

  test('returns CloudApiEngine when cloud settings are complete', () {
    final engine = buildEngine(const EngineSettings(
      choice: EngineChoice.cloud,
      cloudEndpoint: 'https://x.com',
      cloudApiKey: 'key',
    ));
    expect(engine, isA<CloudApiEngine>());
  });

  test('returns null for onDevice choice with empty model path', () {
    expect(buildEngine(const EngineSettings(choice: EngineChoice.onDevice)), isNull);
  });

  test('returns OnDeviceLlamaEngine when model path is set', () {
    final engine = buildEngine(const EngineSettings(
      choice: EngineChoice.onDevice,
      onDeviceModelPath: '/sdcard/models/model.gguf',
    ));
    expect(engine, isA<OnDeviceLlamaEngine>());
  });
}
