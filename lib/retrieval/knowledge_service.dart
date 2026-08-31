import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../agents/agent_logic.dart';
import '../engine/embedding_engine.dart';
import '../engine/llm_engine.dart';
import '../memory/memory_fact.dart';
import '../okf/bundle.dart';
import 'chunker.dart';
import 'context_assembler.dart';
import 'corpus.dart';
import 'retrieval_result.dart';
import 'retrieval_service.dart';
import 'route_log.dart';
import 'router.dart';
import 'vector_index.dart';

/// Wires the corpus, the embedding model, memory and the router together, so
/// the UI deals in "ask a question, get an answer and its sources" and nothing
/// else.
///
/// Everything expensive (loading a bundle, embedding it) is explicit and
/// cancellable. Nothing here runs on app start by itself.
class KnowledgeService {
  Corpus? _corpus;
  MemoryStore? _memory;
  RouteLog? _routeLog;
  EmbeddingEngine? _embedder;

  String _bundlePath = '';
  bool _indexStale = false;
  List<String> _skipped = const [];

  final _logicResolver = AgentLogicResolver();

  /// The active agent-logic file, resolved at [open]. Null means the built-in
  /// system prompt and the router's own heuristics — the original behaviour.
  AgentLogic? _logic;

  /// The parsed agent logic in force, for the UI to show what is active.
  AgentLogic? get agentLogic => _logic;
  String _embedModelPath = '';
  String _agentLogicPath = '';
  Set<String> _fileTools = const {};
  bool _cancelIndexing = false;

  /// True when the service is already open for exactly this configuration.
  ///
  /// The UI calls this before reopening: picking a new folder or embedding
  /// model in Config has to take effect without an app restart, but reopening
  /// on every rebuild would re-read the whole bundle off disk.
  ///
  /// The enabled file-tool set is part of that configuration: turning PDF on
  /// changes what belongs in the index even though the folder did not change.
  bool isOpenFor({
    required String bundlePath,
    required String embedModelPath,
    Set<String> fileTools = const {},
    String agentLogicPath = '',
  }) =>
      _corpus != null &&
      _bundlePath == bundlePath &&
      _embedModelPath == embedModelPath &&
      _agentLogicPath == agentLogicPath &&
      _fileTools.length == fileTools.length &&
      _fileTools.containsAll(fileTools);

  /// True when the built index no longer matches the bundle on disk. Owned
  /// here rather than by a screen so that a reindex clears it for everyone.
  bool get indexStale => _indexStale;

  /// Files the last open could not read, as `relpath: reason`. Surfaced so an
  /// enabled file tool that extracts nothing is visible rather than silent.
  List<String> get skippedFiles => List.unmodifiable(_skipped);

  Corpus? get corpus => _corpus;
  MemoryStore? get memory => _memory;
  RouteLog? get routeLog => _routeLog;
  bool get isReady => _corpus != null && _corpus!.bundle.concepts.isNotEmpty;
  int get conceptCount => _corpus?.bundle.concepts.length ?? 0;
  int get chunkCount => _corpus?.chunks.length ?? 0;
  bool get hasEmbeddings => _corpus?.hasEmbeddings ?? false;

  Future<Directory> _appDir() async => getApplicationDocumentsDirectory();

  /// The manifest lives in app storage, not in the bundle folder.
  ///
  /// The spec puts `.okf-manifest.json` next to the content, but a folder the
  /// user picks through the system directory picker is not reliably writable
  /// under scoped storage — and a manifest that silently fails to write means
  /// re-embedding the whole bundle on every launch.
  Future<File> _manifestFile() async =>
      File(p.join((await _appDir()).path, 'okf_manifest.json'));
  Future<File> _vectorCacheFile() async => File(p.join((await _appDir()).path, 'okf_vectors.json'));

  /// Opens the bundle and builds the lexical indexes. Returns true when the
  /// cached vectors are stale and [reindex] should be offered to the user —
  /// never triggered automatically, because embedding a bundle on a phone is
  /// a battery and thermal event.
  Future<bool> open({
    required String bundlePath,
    required String embedModelPath,
    String agentLogicPath = '',
    Set<String> fileTools = const {},
  }) async {
    _bundlePath = bundlePath;
    _agentLogicPath = agentLogicPath;
    _logic = await _logicResolver.resolve(bundlePath: bundlePath, logicPath: agentLogicPath);
    _embedModelPath = embedModelPath;
    _fileTools = fileTools;
    if (bundlePath.isEmpty) {
      _indexStale = false;
      return false;
    }

    final dir = await _appDir();
    _memory = MemoryStore(File(p.join(dir.path, 'memory.json')));
    await _memory!.load();
    _routeLog = RouteLog(File(p.join(dir.path, 'route_log.jsonl')));

    // Retiring stale facts is cheap and bounded, and this is the one moment a
    // session reliably reaches. A background job would be more faithful to the
    // spec and buy nothing.
    await _memory!.decay();

    final opened = await openCorpus(
      root: Directory(bundlePath),
      embedModel: p.basename(embedModelPath),
      manifestFile: await _manifestFile(),
      vectorCacheFile: await _vectorCacheFile(),
      fileTools: fileTools,
    );
    _corpus = opened.corpus;
    _skipped = opened.skipped;
    _rebuildMemoryChunks();
    _indexStale = opened.needsEmbedding && embedModelPath.isNotEmpty;
    return _indexStale;
  }

  /// Embeds every chunk and writes both caches. Long-running and cancellable.
  Future<void> reindex({IndexProgress? onProgress}) async {
    final corpus = _corpus;
    if (corpus == null || _embedModelPath.isEmpty) return;

    _cancelIndexing = false;
    final embedder = EmbeddingEngineRegistry.instance.forPath(_embedModelPath)!;
    _embedder = embedder;

    await corpus.embedAll(
      embedder.embed,
      onProgress: onProgress,
      shouldCancel: () => _cancelIndexing,
    );
    if (_cancelIndexing) return;

    await (await _vectorCacheFile()).writeAsString(corpus.encodeVectorCache());
    await (await _manifestFile()).writeAsString(_manifestJson(corpus));
    _indexStale = false;
  }

  void cancelIndexing() => _cancelIndexing = true;

  String _manifestJson(Corpus corpus) {
    final dim = corpus.vectors.isEmpty ? 0 : corpus.vectors.toLists().first.length;
    return jsonEncode(BundleManifest(
      bundleId: corpus.bundle.id,
      contentHash: corpus.bundle.contentHash,
      indexedAt: DateTime.now().millisecondsSinceEpoch,
      embedModel: p.basename(_embedModelPath),
      embedDim: dim,
      fileCount: corpus.bundle.concepts.length,
      fileTools: BundleManifest.normaliseFileTools(_fileTools),
    ).toJson());
  }

  /// Folds active memory facts into the corpus chunk list so vector mode
  /// retrieves them natively, with no separate lookup path.
  void _rebuildMemoryChunks() {
    final corpus = _corpus;
    final memory = _memory;
    if (corpus == null || memory == null) return;

    corpus.chunks.removeWhere((c) => c.memoryId != null);
    for (final fact in memory.active) {
      corpus.chunkIndex.add('${corpus.chunks.length}', body: fact.text);
      corpus.chunks.add(Chunk(memoryId: fact.id, ord: 0, text: fact.text));
    }
  }

  /// Runs one turn: route, retrieve, assemble the prompt.
  ///
  /// Generation is left to the caller so the UI owns the token stream — this
  /// returns the prompt and the provenance to render alongside it.
  Future<({RetrievalOutcome outcome, String prompt})> prepare({
    required String question,
    required RetrievalMode requested,
    required List<String> history,
    required int contextTokens,
    LlmEngine? classifierEngine,
    AgentLogic? logic,
  }) async {
    // Null logic means no agent-logic file, which must behave exactly as
    // before: the built-in prompt and the router's own cascade.
    // An explicit argument wins; otherwise the file resolved at open() is in
    // force. Falling back to the built-in prompt keeps a bundle with no logic
    // file behaving exactly as before.
    final active = logic ?? _logic;
    final systemPrompt = active?.systemPrompt() ?? kSystemPrompt;
    final corpus = _corpus;
    if (corpus == null) {
      return (
        outcome: const RetrievalOutcome(
          decision: RouteDecision(mode: RetrievalMode.vector, confidence: 0, reason: 'no-bundle'),
          result: RetrievalResult(mode: RetrievalMode.vector, items: []),
        ),
        prompt: buildPrompt(
          question: question,
          retrieved: const RetrievalResult(mode: RetrievalMode.vector, items: []),
          history: history,
          contextTokens: contextTokens,
          systemPrompt: systemPrompt,
        ),
      );
    }

    final budget = retrievalBudget(
      contextTokens: contextTokens,
      systemPrompt: systemPrompt,
      history: history,
    );

    List<double>? queryVector;
    if (corpus.hasEmbeddings && _embedModelPath.isNotEmpty) {
      try {
        queryVector = await EmbeddingEngineRegistry.instance.forPath(_embedModelPath)!.embed(question);
      } catch (_) {
        // No query vector means BM25-only retrieval, which is degraded but
        // still answers. Failing the turn outright would not.
      }
    }

    final outcome = await retrieve(
      corpus: corpus,
      query: question,
      requested: requested,
      budgetTokens: budget,
      queryVector: queryVector,
      memoryHit: _hasMemoryHit(question),
      boostMemory: _boostMemory,
      classify: classifierEngine == null ? null : (q) => _classifyWith(classifierEngine, q),
      forceMode: active?.routeFor,
    );

    await _recordMemoryHits(outcome.result);

    return (
      outcome: outcome,
      prompt: buildPrompt(
        question: question,
        retrieved: outcome.result,
        history: history,
        contextTokens: contextTokens,
        systemPrompt: systemPrompt,
      ),
    );
  }

  /// Applies the recency/usage boost to a memory chunk's fused score.
  double _boostMemory(String memoryId, double score) {
    final memory = _memory;
    if (memory == null) return score;
    for (final fact in memory.active) {
      if (fact.id == memoryId) return memoryScore(score, fact);
    }
    return score;
  }

  bool _hasMemoryHit(String query) {
    final memory = _memory;
    final corpus = _corpus;
    if (memory == null || corpus == null || memory.active.isEmpty) return false;
    // A memory chunk in the lexical top 3 is a strong enough signal; anything
    // looser routes half the corpus down the memory path.
    return corpus.chunkIndex
        .search(query, limit: 3)
        .any((h) => corpus.chunks[int.parse(h.id)].memoryId != null);
  }

  Future<void> _recordMemoryHits(RetrievalResult result) async {
    final memory = _memory;
    if (memory == null) return;
    for (final item in result.items) {
      if (item.source.startsWith('memory:')) {
        await memory.recordHit(item.source.substring('memory:'.length));
      }
    }
  }

  Future<String?> _classifyWith(LlmEngine engine, String query) async {
    try {
      return await engine.generate(classifierPromptFor(query));
    } catch (_) {
      return null;
    }
  }

  /// Extracts durable facts from a finished conversation and stores them,
  /// deduping against what is already remembered.
  Future<int> extractMemories({
    required LlmEngine engine,
    required List<String> conversation,
    required String sessionId,
  }) async {
    final memory = _memory;
    if (memory == null || conversation.isEmpty) return 0;

    final String reply;
    try {
      reply = await engine.generate(memoryExtractionPromptFor(conversation.join('\n')));
    } catch (_) {
      return 0;
    }

    final candidates = parseExtraction(reply);
    if (candidates.isNotEmpty) await _warmMemoryVectors();
    var stored = 0;
    for (final candidate in candidates) {
      List<double>? vector;
      if (_embedModelPath.isNotEmpty) {
        try {
          vector = await EmbeddingEngineRegistry.instance.forPath(_embedModelPath)!.embed(candidate.text);
        } catch (_) {/* fall back to exact-text dedupe below */}
      }

      final before = memory.all.length;
      await memory.upsert(
        id: '${DateTime.now().microsecondsSinceEpoch}-$stored',
        text: candidate.text,
        kind: candidate.kind,
        source: sessionId,
        isDuplicate: (existing) => vector == null
            ? existing.text.toLowerCase().trim() == candidate.text.toLowerCase().trim()
            : _isNearDuplicate(existing, vector),
      );
      if (memory.all.length > before) {
        stored++;
        if (vector != null) _memoryVectors[memory.all.last.id] = vector;
      }
    }
    _rebuildMemoryChunks();
    return stored;
  }

  /// Embeddings of stored memory facts, computed on demand and cached for the
  /// life of the service. Only the dedupe path needs them, and it runs once
  /// per extraction rather than once per query.
  final Map<String, List<double>> _memoryVectors = {};

  Future<List<double>?> _vectorFor(MemoryFact fact) async {
    final cached = _memoryVectors[fact.id];
    if (cached != null) return cached;
    if (_embedModelPath.isEmpty) return null;
    try {
      final vector = await EmbeddingEngineRegistry.instance.forPath(_embedModelPath)!.embed(fact.text);
      _memoryVectors[fact.id] = vector;
      return vector;
    } catch (_) {
      return null;
    }
  }

  /// Embeds every active fact so the dedupe check has something to compare
  /// against. Without this the cache is empty on the first extraction of a
  /// session and near-duplicates slip straight through.
  Future<void> _warmMemoryVectors() async {
    final memory = _memory;
    if (memory == null || _embedModelPath.isEmpty) return;
    for (final fact in memory.active) {
      await _vectorFor(fact);
    }
  }

  /// True when [candidate] is [existing] said differently.
  ///
  /// A fact with no cached vector is never treated as a duplicate — silently
  /// merging on a guess would lose a genuinely new fact, which is the worse
  /// of the two failures.
  bool _isNearDuplicate(MemoryFact existing, List<double> candidate) {
    final stored = _memoryVectors[existing.id];
    if (stored == null) return false;
    return cosine(stored, candidate) > kDedupeThreshold;
  }

  Future<void> dispose() async {
    await _embedder?.unload();
  }
}
