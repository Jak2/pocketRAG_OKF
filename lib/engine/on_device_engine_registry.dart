import 'on_device_llama_engine.dart';

/// App-wide holder for the single on-device model instance, so the chat
/// screen (which generates with it) and the Config screen (which shows
/// load/offload status and controls) always see the same loaded/unloaded
/// state instead of each holding an independent engine.
class OnDeviceEngineRegistry {
  OnDeviceEngineRegistry._();
  static final OnDeviceEngineRegistry instance = OnDeviceEngineRegistry._();

  OnDeviceLlamaEngine? _engine;
  String? _modelPath;

  /// Returns the shared engine for [modelPath], creating a fresh (unloaded)
  /// one if the path changed or none exists yet. Switching to a different
  /// model path discards the old engine instance without unloading it here —
  /// callers that need a clean unload first should call [unload] explicitly.
  OnDeviceLlamaEngine forPath(String modelPath) {
    if (_engine == null || _modelPath != modelPath) {
      _engine = OnDeviceLlamaEngine(modelPath: modelPath);
      _modelPath = modelPath;
    }
    return _engine!;
  }

  /// The model path the shared engine is actually loaded for, or null if
  /// nothing is loaded right now.
  String? get loadedModelPath => (_engine?.isLoaded ?? false) ? _modelPath : null;

  bool isLoadedFor(String modelPath) => loadedModelPath == modelPath;

  Future<void> unload() async {
    await _engine?.unload();
  }
}
