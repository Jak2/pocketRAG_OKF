import 'dart:async';

import 'package:llama_cpp_dart/llama_cpp_dart.dart';
import 'generation_event.dart';
import 'llm_engine.dart';

/// Context window used for on-device inference, in tokens.
///
/// Bigger costs RAM (KV cache) and prefill time on a phone; smaller rejects
/// real repo trees. 4096 fits the trees seen so far with room for the reply.
const int kOnDeviceContextTokens = 4096;

/// Rough characters-per-token for English text and file paths. Used only to
/// keep a prompt under [kOnDeviceContextTokens] before sending it — it is a
/// conservative estimate, not a real tokenizer count.
const double kCharsPerToken = 3.5;

/// The largest prompt, in characters, that should be sent on-device — leaving
/// headroom for the model's own reply.
final int kMaxPromptChars =
    ((kOnDeviceContextTokens - 512) * kCharsPerToken).floor();

/// Markers that mean the model has stopped answering and started writing the
/// rest of the transcript itself.
///
/// llama_cpp_dart 0.0.9 stops only on an end-of-generation token or the
/// nPredict cap. A plain-text (non chat-templated) prompt rarely makes a model
/// emit its EOG token, so without this it happily continues with
/// "User: ...\nAssistant: ..." and role-plays both sides.
const List<String> kStopSequences = ['\nUser:', '\nAssistant:', '\nSystem:'];

final int _maxStopLength =
    kStopSequences.map((s) => s.length).reduce((a, b) => a > b ? a : b);

/// Index of the earliest stop marker in [text], or null if none is present.
int? _firstStopIndex(String text) {
  int? earliest;
  for (final stop in kStopSequences) {
    final i = text.indexOf(stop);
    if (i >= 0 && (earliest == null || i < earliest)) earliest = i;
  }
  return earliest;
}

/// [text] truncated at the first stop marker and trimmed.
String trimAtStop(String text) {
  final i = _firstStopIndex(text);
  return (i == null ? text : text.substring(0, i)).trim();
}

/// On-device engine backed by llama_cpp_dart's isolate-based LlamaParent.
/// The package already runs inference in a child isolate, so this class
/// just drives its prompt/stream API.
class OnDeviceLlamaEngine implements LlmEngine {
  final String modelPath;
  LlamaParent? _parent;

  OnDeviceLlamaEngine({required this.modelPath});

  bool get isLoaded => _parent != null;

  Future<LlamaParent> _ensureLoaded() async {
    if (_parent != null) return _parent!;
    final parent = LlamaParent(
      LlamaLoad(
        path: modelPath,
        // nGpuLayers defaults to 99 (offload almost everything to GPU), but
        // this app's llama.cpp is built from source without a mobile GPU
        // backend (no Vulkan/CUDA compute path linked in) — leaving the
        // default causes a native SIGSEGV inside the model-load isolate the
        // first time it tries to hand a layer to a GPU backend that isn't
        // there. Force CPU-only inference.
        modelParams: ModelParams()..nGpuLayers = 0,
        // Defaults are nPredict = 32, nCtx = 512, nBatch = 512, which truncate
        // a reply mid-sentence and leave no room for repo-tree context — a
        // real repo tree measured 2325 tokens and was rejected outright with
        // "Prompt token count exceeds batch capacity".
        //
        // nBatch must be >= the whole prompt: llama_cpp_dart submits the
        // prompt as one logical batch and throws if it doesn't fit. nUbatch
        // stays small because it only sets the physical micro-batch size, and
        // raising it inflates the compute buffer for no benefit here.
        contextParams: ContextParams()
          ..nPredict = 256
          ..nCtx = kOnDeviceContextTokens
          ..nBatch = kOnDeviceContextTokens
          ..nUbatch = 512,
        samplingParams: SamplerParams(),
      ),
    );
    await parent.init();
    _parent = parent;
    return parent;
  }

  /// Explicitly loads the model without generating anything, so the UI can
  /// show a "Load" action independent of sending a prompt.
  Future<void> load() => _ensureLoaded();

  /// Frees the loaded model's isolate/memory. Safe to call when not loaded.
  Future<void> unload() async {
    final parent = _parent;
    _parent = null;
    await parent?.dispose();
  }

  @override
  Future<String> generate(String prompt) => bufferStream(generateStream(prompt));

  @override
  Stream<GenerationEvent> generateStream(String prompt) async* {
    if (_parent == null) {
      yield const GenerationStatus('loading model…');
    }
    final LlamaParent parent;
    try {
      parent = await _ensureLoaded();
    } catch (e) {
      yield GenerationError('Model failed to load: $e');
      return;
    }
    yield const GenerationStatus('model ready');

    final buffer = StringBuffer();
    final tokens = StreamController<String>();
    final sub = parent.stream.listen(tokens.add, onError: tokens.addError);

    // Subscribe to completions BEFORE sending the prompt. Subscribing after
    // `sendPrompt` returns leaves a window where the completion event can fire
    // unobserved on this broadcast stream, which strands the caller until a
    // timeout — one of the suspected causes of the silent-generation bug.
    final completion = parent.completions.first;

    try {
      yield const GenerationStatus('prompt sent');
      await parent.sendPrompt(prompt);

      var count = 0;
      var emitted = 0;
      var hitStop = false;
      final done = completion.whenComplete(tokens.close);

      await for (final token in tokens.stream) {
        buffer.write(token);
        count++;

        final text = buffer.toString();
        final stopAt = _firstStopIndex(text);

        if (stopAt != null) {
          // Emit only the text before the stop marker, then halt generation so
          // the model doesn't keep burning CPU role-playing the user's turn.
          if (stopAt > emitted) {
            yield GenerationToken(text.substring(emitted, stopAt));
            emitted = stopAt;
          }
          hitStop = true;
          await parent.stop();
          break;
        }

        // Hold back a tail that could still turn out to be the start of a stop
        // marker, so a partial "\nUser" is never shown and then retracted.
        final safeEnd = text.length - _maxStopLength;
        if (safeEnd > emitted) {
          yield GenerationToken(text.substring(emitted, safeEnd));
          emitted = safeEnd;
        }

        if (count % 8 == 0) {
          yield GenerationStatus('generating ($count tokens)');
        }
      }

      if (hitStop) {
        yield GenerationDone(trimAtStop(buffer.toString()));
        return;
      }

      // Flush whatever was held back for stop-marker detection.
      final full = buffer.toString();
      if (full.length > emitted) {
        yield GenerationToken(full.substring(emitted));
      }

      final event = await done;
      if (!event.success) {
        yield GenerationError(event.errorDetails ?? 'Generation failed');
        return;
      }
      yield GenerationDone(trimAtStop(full));
    } catch (e) {
      yield GenerationError('$e');
    } finally {
      await sub.cancel();
      if (!tokens.isClosed) await tokens.close();
    }
  }
}
