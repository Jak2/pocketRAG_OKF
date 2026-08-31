import 'dart:convert';
import 'dart:io';

class InstructionEntry {
  final String slug;
  final String name;
  final String description;
  final String content;

  const InstructionEntry({
    required this.slug,
    required this.name,
    required this.description,
    required this.content,
  });
}

String slugify(String input) {
  final lowered = input.toLowerCase().trim();
  final hyphenated = lowered.replaceAll(RegExp(r'[^a-z0-9]+'), '-');
  return hyphenated.replaceAll(RegExp(r'^-+|-+$'), '');
}

class InstructionLibrary {
  final Directory root;

  InstructionLibrary({required this.root});

  File get _manifestFile => File('${root.path}/manifest.json');
  File _contentFile(String slug) => File('${root.path}/$slug.md');

  Future<Map<String, dynamic>> _readManifest() async {
    if (!await _manifestFile.exists()) return {};
    try {
      final text = await _manifestFile.readAsString();
      if (text.trim().isEmpty) return {};
      return jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      // Corrupt/hand-edited manifest: treat as a fresh, empty library rather than crashing.
      return {};
    }
  }

  Future<void> _writeManifest(Map<String, dynamic> manifest) async {
    await root.create(recursive: true);
    await _manifestFile.writeAsString(jsonEncode(manifest));
  }

  Future<List<InstructionEntry>> list() async {
    final manifest = await _readManifest();
    final entries = <InstructionEntry>[];
    for (final slug in manifest.keys) {
      final meta = manifest[slug] as Map<String, dynamic>;
      final content = await contentFor(slug) ?? '';
      entries.add(InstructionEntry(
        slug: slug,
        name: meta['name'] as String,
        description: meta['description'] as String,
        content: content,
      ));
    }
    return entries;
  }

  Future<InstructionEntry> add({
    required String name,
    required String description,
    required String content,
  }) async {
    final slug = slugify(name);
    final manifest = await _readManifest();
    if (manifest.containsKey(slug)) {
      throw StateError('An entry with slug "$slug" already exists');
    }
    manifest[slug] = {'name': name, 'description': description};
    await _writeManifest(manifest);
    await _contentFile(slug).writeAsString(content);
    return InstructionEntry(slug: slug, name: name, description: description, content: content);
  }

  Future<void> update(String slug, {String? name, String? description, String? content}) async {
    final manifest = await _readManifest();
    final meta = manifest[slug] as Map<String, dynamic>?;
    if (meta == null) throw StateError('No entry with slug "$slug"');
    if (name != null) meta['name'] = name;
    if (description != null) meta['description'] = description;
    manifest[slug] = meta;
    await _writeManifest(manifest);
    if (content != null) {
      await _contentFile(slug).writeAsString(content);
    }
  }

  Future<void> delete(String slug) async {
    final manifest = await _readManifest();
    if (!manifest.containsKey(slug)) return;
    manifest.remove(slug);
    await _writeManifest(manifest);
    final file = _contentFile(slug);
    if (await file.exists()) await file.delete();
  }

  Future<String?> contentFor(String slug) async {
    final file = _contentFile(slug);
    if (!await file.exists()) return null;
    return file.readAsString();
  }
}
