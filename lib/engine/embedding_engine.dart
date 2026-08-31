import 'dart:async';
import 'dart:isolate';

import 'package:llama_cpp_dart/llama_cpp_dart.dart';

/// Produces embedding vectors from a second, small GGUF.
///
/// A separate model from the chat model on purpose: a chat GGUF mean-pooled
/// into a vector is a poor embedder, and retrieval quality is the whole point
/// of the vector path. Expect a 384- or 768-dim sentence-transformer GGUF.
///
/// `llama_cpp_dart` exposes `getEmbeddings` only on the synchronous FFI `Llama`
/// class, not on the isolate-based `LlamaParent` used for chat — so this runs
/// its own isolate. Without one, embedding a few thousand chunks would block
/// the UI thread for minutes.
class EmbeddingEngine {
  final String modelPath;

  Isolate? _isolate;
  SendPort? _send;
  final _ready = Completer<void>();
  final _pending = <int, Completer<List<double>>>{};
  var _nextId = 0;

  EmbeddingEngine({required this.modelPath});

  bool get isLoaded => _send != null;

  Future<void> load() async {
    if (_isolate != null) return _ready.future;
    final receive = ReceivePort();
    _isolate = await Isolate.spawn(_embedIsolate, (receive.sendPort, modelPath));

    receive.listen((message) {
      switch (message) {
        case SendPort port:
          _send = port;
          if (!_ready.isCompleted) _ready.complete();
        case (int id, List<double> vector):
          _pending.remove(id)?.complete(vector);
        case (int id, String error):
          _pending.remove(id)?.completeError(Exception(error));
        case String fatal:
          if (!_ready.isCompleted) _ready.completeError(Exception(fatal));
      }
    });
    return _ready.future;
  }

  /// Embeds [text]. Loads the model on first call.
  Future<List<double>> embed(String text) async {
    await load();
    final id = _nextId++;
    final completer = Completer<List<double>>();
    _pending[id] = completer;
    _send!.send((id, text));
    return completer.future;
  }

  Future<void> unload() async {
    _send?.send('dispose');
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _isolate = null;
    _send = null;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(Exception('embedding engine unloaded'));
    }
    _pending.clear();
  }
}

void _embedIsolate((SendPort, String) args) {
  final (reply, modelPath) = args;
  final port = ReceivePort();

  final Llama llama;
  try {
    llama = Llama(
      modelPath,
      // nGpuLayers 0 for the same reason as the chat engine: this build of
      // llama.cpp has no mobile GPU backend linked in, and the default of 99
      // segfaults on the first layer offload.
      ModelParams()..nGpuLayers = 0,
      ContextParams()
        ..embeddings = true
        ..nPredict = 0
        // An embedding model's context is its max input length; anything
        // longer is truncated by the chunker before it gets here.
        ..nCtx = 512
        ..nBatch = 512
        ..nUbatch = 512,
      SamplerParams(),
    );
  } catch (e) {
    reply.send('Embedding model failed to load: $e');
    return;
  }

  reply.send(port.sendPort);

  port.listen((message) {
    if (message == 'dispose') {
      llama.dispose();
      port.close();
      return;
    }
    final (id, text) = message as (int, String);
    try {
      reply.send((id, llama.getEmbeddings(text)));
    } catch (e) {
      reply.send((id, 'embedding failed: $e'));
    }
  });
}

/// App-wide holder, mirroring [OnDeviceEngineRegistry] for the chat model, so
/// the indexer and the query path share one loaded embedding model instead of
/// each holding their own copy in RAM.
class EmbeddingEngineRegistry {
  EmbeddingEngineRegistry._();
  static final EmbeddingEngineRegistry instance = EmbeddingEngineRegistry._();

  EmbeddingEngine? _engine;
  String? _path;

  EmbeddingEngine? forPath(String modelPath) {
    if (modelPath.isEmpty) return null;
    if (_engine == null || _path != modelPath) {
      _engine = EmbeddingEngine(modelPath: modelPath);
      _path = modelPath;
    }
    return _engine;
  }

  EmbeddingEngine? get current => _engine;
  Future<void> unload() async => _engine?.unload();
}
