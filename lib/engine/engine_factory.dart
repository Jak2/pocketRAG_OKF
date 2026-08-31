import 'package:dio/dio.dart';
import '../settings/engine_settings.dart';
import 'cloud_api_engine.dart';
import 'llm_engine.dart';
import 'on_device_engine_registry.dart';

/// Returns null when [settings] doesn't have enough configured to build a
/// real engine. Callers must treat null as "block and ask the user to
/// configure the LLM in Settings" — never substitute a fake/placeholder
/// engine, since that risks pushing fabricated content to a real repo.
LlmEngine? buildEngine(EngineSettings settings) {
  switch (settings.choice) {
    case EngineChoice.cloud:
      if (settings.cloudEndpoint.isEmpty || settings.cloudApiKey.isEmpty) {
        return null;
      }
      return CloudApiEngine(
        client: Dio(),
        apiKey: settings.cloudApiKey,
        endpoint: settings.cloudEndpoint,
        model: settings.cloudModel,
        extraHeaders: settings.cloudHeadersMap,
      );
    case EngineChoice.onDevice:
      if (settings.onDeviceModelPath.isEmpty) return null;
      return OnDeviceEngineRegistry.instance.forPath(settings.onDeviceModelPath);
  }
}
