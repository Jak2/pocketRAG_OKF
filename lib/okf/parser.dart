import 'package:path/path.dart' as p;

import 'concept.dart';

/// Splits a `---`-delimited YAML frontmatter block off the front of [raw].
///
/// Tolerates: no block at all, a BOM, CRLF, an unterminated block, and an
/// empty body. Never throws — a malformed file degrades to "all of it is
/// body", which is still answerable text.
({String yaml, String body}) splitFrontmatter(String raw) {
  var text = raw.startsWith('﻿') ? raw.substring(1) : raw;
  text = text.replaceAll('\r\n', '\n');

  if (!text.startsWith('---\n')) return (yaml: '', body: text);
  final end = text.indexOf('\n---', 3);
  // Unterminated block: treating the whole file as body loses nothing, whereas
  // treating it as frontmatter would silently drop the content.
  if (end < 0) return (yaml: '', body: text);

  final yaml = text.substring(4, end + 1);
  var body = text.substring(end + 4);
  if (body.startsWith('\n')) body = body.substring(1);
  return (yaml: yaml, body: body);
}

/// Parses the flat `key: value` subset of YAML that OKF frontmatter uses.
///
/// ponytail: hand-rolled instead of the `yaml` package — OKF frontmatter is
/// flat scalars plus tag lists, and a real parser would throw on malformed
/// input where this must not. Swap in `package:yaml` (inside a try/catch) if
/// nested structures ever appear.
///
/// Handles `key: value`, `key: [a, b]`, and `- item` blocks. Unknown keys are
/// kept verbatim. Anything it cannot understand is skipped, not raised.
Map<String, String> parseFrontmatter(String yaml) {
  final out = <String, String>{};
  String? listKey;
  final listItems = <String>[];

  void flushList() {
    if (listKey != null) {
      out[listKey!] = listItems.join(', ');
      listItems.clear();
      listKey = null;
    }
  }

  for (final line in yaml.split('\n')) {
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;

    if (listKey != null && line.trimLeft().startsWith('- ')) {
      listItems.add(_unquote(line.trimLeft().substring(2).trim()));
      continue;
    }
    flushList();

    final colon = line.indexOf(':');
    if (colon <= 0) continue;
    final key = line.substring(0, colon).trim();
    final value = line.substring(colon + 1).trim();
    if (key.isEmpty) continue;

    if (value.isEmpty) {
      // Either a block list follows or the key is genuinely empty. Record the
      // empty value now; a following `- item` run overwrites it.
      out[key] = '';
      listKey = key;
    } else {
      out[key] = _unquote(value);
    }
  }
  flushList();
  return out;
}

String _unquote(String v) {
  if (v.length >= 2 &&
      ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'")))) {
    return v.substring(1, v.length - 1);
  }
  return v;
}

/// Splits `[a, b]` / `a, b` into a tag list.
List<String> parseTags(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const [];
  var v = raw.trim();
  if (v.startsWith('[') && v.endsWith(']')) v = v.substring(1, v.length - 1);
  return v
      .split(',')
      .map((t) => _unquote(t.trim()))
      .where((t) => t.isNotEmpty)
      .toList();
}

final _linkPattern = RegExp(r'\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)');
final _externalPattern = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:');

/// Extracts markdown links from [body] and resolves each against [fromRelpath].
///
/// External schemes (http, https, mailto, …) resolve to null. So does anything
/// that escapes the bundle root via `../`, which is a path-traversal guard as
/// much as a correctness one.
List<ConceptLink> extractLinks(String body, String fromRelpath) {
  final dir = p.url.dirname(fromRelpath);
  final out = <ConceptLink>[];

  for (final m in _linkPattern.allMatches(body)) {
    final anchor = m.group(1) ?? '';
    final href = m.group(2)!;

    String? target;
    // A bare `#section` is a self-link; a scheme means it leaves the bundle.
    if (!href.startsWith('#') && !_externalPattern.hasMatch(href)) {
      var path = href.split('#').first;
      if (path.isNotEmpty) {
        path = Uri.decodeComponent(path);
        final joined = p.url.normalize(path.startsWith('/') ? path.substring(1) : p.url.join(dir, path));
        if (!joined.startsWith('..') && joined != '.') target = joined;
      }
    }
    out.add(ConceptLink(anchor: anchor, rawHref: href, targetPath: target));
  }
  return out;
}

/// Parses one bundle file into a [Concept].
///
/// [relpath] is bundle-relative and doubles as the concept's identity and its
/// citation string, so it is never derived from frontmatter.
Concept parseConcept({required String relpath, required String raw}) {
  final split = splitFrontmatter(raw);
  final fm = parseFrontmatter(split.yaml);
  final body = split.body;

  return Concept(
    relpath: relpath,
    type: (fm['type']?.isEmpty ?? true) ? null : fm['type'],
    // Falling back to the filename keeps title-based seeding working on files
    // with no frontmatter at all.
    title: (fm['title']?.isNotEmpty ?? false)
        ? fm['title']!
        : p.url.basenameWithoutExtension(relpath).replaceAll('-', ' '),
    description: fm['description'] ?? '',
    tags: parseTags(fm['tags']),
    frontmatter: fm,
    body: body,
    links: extractLinks(body, relpath),
  );
}
