import 'dart:convert';
import 'dart:io';

import '../okf/bundle.dart';
import '../okf/concept.dart';
import 'chunker.dart';
import 'keyword_index.dart';
import 'vector_index.dart';

/// Reports indexing progress so a long embed pass can show something other
/// than a spinner.
typedef IndexProgress = void Function(int done, int total, String stage);

/// Produces one embedding vector for a piece of text.
typedef Embedder = Future<List<double>> Function(String text);

/// A loaded bundle plus every index built over it.
///
/// One corpus, both modes. GRAPH walks [bundle]'s links and returns whole
/// concepts; VECTOR searches [chunks]. They are never two separate stores.
class Corpus {
  final Bundle bundle;

  /// Concept chunks followed by memory-fact chunks; positions are stable and
  /// are what [vectors] indexes into.
  final List<Chunk> chunks;

  /// BM25 over concepts, keyed by relpath.
  final KeywordIndex conceptIndex;

  /// BM25 over chunks, keyed by the chunk's position in [chunks] as a string.
  final KeywordIndex chunkIndex;

  final VectorIndex vectors;

  /// Empty until an [Embedder] has run. VECTOR mode degrades to BM25-only
  /// rather than failing when this is the case.
  bool get hasEmbeddings => !vectors.isEmpty;

  Corpus({
    required this.bundle,
    required this.chunks,
    required this.conceptIndex,
    required this.chunkIndex,
    required this.vectors,
  });

  /// Builds the lexical indexes and the chunk list. Cheap — no embeddings.
  factory Corpus.build(Bundle bundle) {
    final chunks = <Chunk>[];
    final conceptIndex = KeywordIndex();
    final chunkIndex = KeywordIndex();

    for (final c in bundle.concepts) {
      conceptIndex.add(
        c.relpath,
        title: c.title,
        description: c.description,
        tags: c.tags.join(' '),
        body: c.body,
      );
      var ord = 0;
      for (final text in chunkText(c.body)) {
        chunkIndex.add('${chunks.length}', title: c.title, tags: c.tags.join(' '), body: text);
        chunks.add(Chunk(conceptPath: c.relpath, ord: ord++, text: text));
      }
    }

    return Corpus(
      bundle: bundle,
      chunks: chunks,
      conceptIndex: conceptIndex,
      chunkIndex: chunkIndex,
      vectors: VectorIndex(),
    );
  }

  /// Embeds every chunk. Cancellable via [shouldCancel] because on a phone
  /// this is minutes of CPU, not seconds, and the user must be able to stop it.
  Future<void> embedAll(
    Embedder embed, {
    IndexProgress? onProgress,
    bool Function()? shouldCancel,
  }) async {
    vectors.clear();
    for (var i = 0; i < chunks.length; i++) {
      if (shouldCancel?.call() ?? false) return;
      try {
        vectors.add(i, await embed(chunks[i].text));
      } catch (_) {
        // A chunk that fails to embed stays retrievable through BM25; aborting
        // the whole pass over one bad chunk would not.
      }
      onProgress?.call(i + 1, chunks.length, 'embedding');
    }
  }

  Concept? conceptFor(Chunk chunk) =>
      chunk.conceptPath == null ? null : bundle.byPath(chunk.conceptPath!);

  /// Serialises chunks and vectors so a restart does not re-embed. The
  /// concepts themselves are re-read from disk (cheap) rather than duplicated
  /// here.
  String encodeVectorCache() => jsonEncode({
        'chunks': chunks.map((c) => c.toJson()).toList(),
        'chunk_indices': vectors.chunkIndices(),
        'vectors': vectors.toLists(),
      });

  /// Restores vectors saved by [encodeVectorCache]. Returns false when the
  /// cache does not line up with the current chunk list, in which case the
  /// caller must re-embed rather than serve mismatched vectors.
  bool loadVectorCache(String json) {
    try {
      final data = jsonDecode(json) as Map<String, Object?>;
      final cached = (data['chunks'] as List).map((c) => Chunk.fromJson(c as Map<String, Object?>)).toList();
      if (cached.length != chunks.length) return false;
      for (var i = 0; i < cached.length; i++) {
        if (cached[i].text != chunks[i].text) return false;
      }
      final indices = (data['chunk_indices'] as List).cast<int>();
      final vecs = (data['vectors'] as List)
          .map((v) => (v as List).map((n) => (n as num).toDouble()).toList())
          .toList();
      if (indices.length != vecs.length) return false;

      vectors.clear();
      for (var i = 0; i < indices.length; i++) {
        vectors.add(indices[i], vecs[i]);
      }
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// Loads the bundle at [root] and builds its indexes, reusing the cached
/// vectors when the manifest says nothing has changed.
///
/// Never re-embeds unconditionally on start: on a phone that is a battery and
/// thermal problem. Returns `needsEmbedding: true` for the caller to schedule
/// deliberately.
Future<({Corpus corpus, bool needsEmbedding, List<String> skipped})> openCorpus({
  required Directory root,
  required String embedModel,
  File? manifestFile,
  File? vectorCacheFile,
  Set<String> fileTools = const {},
}) async {
  // Collected rather than dropped: a file that yields no text is the only
  // evidence a file-tool toggle is on and doing nothing, and silence there
  // looks identical to the format never having been enabled.
  final skipped = <String>[];
  final bundle = await loadBundle(root, fileTools: fileTools, skipped: skipped);
  final corpus = Corpus.build(bundle);

  final manifest = manifestFile != null && await manifestFile.exists()
      ? BundleManifest.fromJson(jsonDecode(await manifestFile.readAsString()) as Map<String, Object?>)
      : null;

  final stale = manifest == null ||
      manifest.isStaleFor(
        contentHash: bundle.contentHash,
        embedModel: embedModel,
        fileTools: fileTools,
      );

  if (!stale && vectorCacheFile != null && await vectorCacheFile.exists()) {
    if (corpus.loadVectorCache(await vectorCacheFile.readAsString())) {
      return (corpus: corpus, needsEmbedding: false, skipped: skipped);
    }
  }
  return (corpus: corpus, needsEmbedding: corpus.chunks.isNotEmpty, skipped: skipped);
}
