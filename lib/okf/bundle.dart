import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'concept.dart';
import 'extractors.dart';
import 'parser.dart';

/// Everything read off disk for one bundle, before any index is built.
class Bundle {
  final String id;
  final Directory root;
  final List<Concept> concepts;

  /// sha256 over the sorted (relpath, file hash) pairs. The reindex trigger:
  /// an unchanged hash means the built index is still valid, so app start does
  /// no embedding work at all.
  final String contentHash;

  const Bundle({
    required this.id,
    required this.root,
    required this.concepts,
    required this.contentHash,
  });

  Concept? byPath(String relpath) {
    for (final c in concepts) {
      if (c.relpath == relpath) return c;
    }
    return null;
  }

  /// The bundle's `index.md` root, if it has one. Used as the universal
  /// last-resort seed for graph mode.
  Concept? get indexConcept => byPath('index.md');

  /// Every distinct frontmatter `type` in the corpus. The AUTO router builds
  /// its structural-noun vocabulary from this rather than from a hardcoded
  /// guess, so it adapts to whatever the user actually authored.
  Set<String> get types =>
      concepts.map((c) => c.type).whereType<String>().where((t) => t.isNotEmpty).toSet();
}

/// Reads and parses every `.md` file under [root], plus any file whose
/// extension is in [fileTools] (see `lib/okf/extractors.dart`).
///
/// [fileTools] empty — the default — means markdown only, which is the app's
/// original behaviour.
///
/// A file that cannot be read or parsed is skipped with its path collected in
/// [skipped] — one broken file must not make the whole bundle unusable.
Future<Bundle> loadBundle(
  Directory root, {
  String? id,
  List<String>? skipped,
  Set<String> fileTools = const {},
}) async {
  if (!await root.exists()) {
    return Bundle(id: id ?? p.basename(root.path), root: root, concepts: const [], contentHash: '');
  }

  // Markdown always; anything else only when the user enabled that file tool.
  final extras = fileTools.where((e) => e != 'md').toSet();

  final files = <File>[];
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final ext = p.extension(entity.path).toLowerCase().replaceFirst('.', '');
    if (ext == 'md' || extras.contains(ext)) files.add(entity);
  }
  files.sort((a, b) => a.path.compareTo(b.path));

  final concepts = <Concept>[];
  final hashInput = StringBuffer();

  for (final file in files) {
    final relpath = p.url.joinAll(p.split(p.relative(file.path, from: root.path)));
    final ext = p.extension(file.path).toLowerCase().replaceFirst('.', '');
    try {
      if (ext == 'md') {
        final raw = await file.readAsString();
        concepts.add(parseConcept(relpath: relpath, raw: raw));
        hashInput.write('$relpath:${sha256.convert(utf8.encode(raw))}\n');
        continue;
      }

      final text = await extractText(file, extras);
      if (text == null || text.trim().isEmpty) {
        // Registered-but-unimplemented (pdf, images) and empty extractions land
        // here. Recording it in [skipped] is what surfaces "the toggle is on
        // but this file produced nothing" instead of it vanishing silently.
        skipped?.add('$relpath: no text extracted');
        continue;
      }
      // No frontmatter and no links in a binary document: the parser's filename
      // title fallback is exactly right, and the extension as `type` feeds the
      // router's corpus-type vocabulary for free.
      final parsed = parseConcept(relpath: relpath, raw: text);
      concepts.add(Concept(
        relpath: relpath,
        type: ext,
        title: parsed.title,
        body: text,
      ));
      hashInput.write('$relpath:${sha256.convert(utf8.encode(text))}\n');
    } catch (e) {
      skipped?.add('$relpath: $e');
    }
  }

  return Bundle(
    id: id ?? p.basename(root.path),
    root: root,
    concepts: concepts,
    contentHash: sha256.convert(utf8.encode(hashInput.toString())).toString(),
  );
}

/// App-local bookkeeping written next to the bundle. Not part of the OKF spec.
class BundleManifest {
  final String bundleId;
  final String contentHash;
  final int indexedAt;
  final String embedModel;
  final int embedDim;
  final int fileCount;

  /// The enabled file-tool extensions the index was built with, sorted. Part of
  /// the index's identity: enabling PDF changes what should be indexed even
  /// though nothing on disk changed.
  final List<String> fileTools;

  const BundleManifest({
    required this.bundleId,
    required this.contentHash,
    required this.indexedAt,
    required this.embedModel,
    required this.embedDim,
    required this.fileCount,
    this.fileTools = const [],
  });

  /// Canonical form of a file-tool set, so `{pdf,docx}` and `{docx,pdf}` are
  /// the same configuration.
  static List<String> normaliseFileTools(Set<String> tools) =>
      tools.map((t) => t.toLowerCase()).toList()..sort();

  /// True when the built index no longer matches what is on disk, was built
  /// with a different embedding model (whose vectors are not comparable), or
  /// was built over a different set of file tools.
  bool isStaleFor({
    required String contentHash,
    required String embedModel,
    Set<String> fileTools = const {},
  }) =>
      this.contentHash != contentHash ||
      this.embedModel != embedModel ||
      this.fileTools.join(',') != normaliseFileTools(fileTools).join(',');

  Map<String, Object?> toJson() => {
        'bundle_id': bundleId,
        'content_hash': contentHash,
        'indexed_at': indexedAt,
        'embed_model': embedModel,
        'embed_dim': embedDim,
        'file_count': fileCount,
        'file_tools': fileTools,
      };

  factory BundleManifest.fromJson(Map<String, Object?> j) => BundleManifest(
        bundleId: j['bundle_id'] as String? ?? '',
        contentHash: j['content_hash'] as String? ?? '',
        indexedAt: j['indexed_at'] as int? ?? 0,
        embedModel: j['embed_model'] as String? ?? '',
        embedDim: j['embed_dim'] as int? ?? 0,
        fileCount: j['file_count'] as int? ?? 0,
        fileTools: (j['file_tools'] as List?)?.map((e) => '$e').toList() ?? const [],
      );
}
