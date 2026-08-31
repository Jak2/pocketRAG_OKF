import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// Plain text extracted from one file, or null when this extractor cannot
/// handle it.
typedef TextExtractor = Future<String?> Function(File file);

/// Lowercase extension (no dot) -> extractor.
///
/// Every entry must return null rather than throw on a file it cannot read:
/// `loadBundle`'s contract is that one broken file never makes a bundle
/// unindexable.
final Map<String, TextExtractor> textExtractors = {
  'txt': _plainText,
  'md': _plainText,
  'csv': _plainText,
  'json': _plainText,
  'docx': _docx,
  'xlsx': _xlsx,
  'pptx': _pptx,
  'pdf': _unsupportedPdf,
  'png': _unsupportedImage,
  'jpg': _unsupportedImage,
  'jpeg': _unsupportedImage,
};

/// Extracts plain text from [file] when its extension is in [enabled] and an
/// extractor exists for it. Returns null otherwise.
Future<String?> extractText(File file, Set<String> enabled) async {
  final ext = p.extension(file.path).toLowerCase().replaceFirst('.', '');
  if (!enabled.contains(ext)) return null;
  final extractor = textExtractors[ext];
  if (extractor == null) return null;
  return extractor(file);
}

Future<String?> _plainText(File file) async {
  try {
    return await file.readAsString();
  } catch (_) {
    // Binary bytes mislabelled as text, or an unreadable path.
    return null;
  }
}

/// PDF text extraction is not implemented.
///
/// It needs a real PDF parser (font maps, content-stream operators, encodings)
/// — `syncfusion_flutter_pdf` would do it, but is not a dependency of this app
/// and pulling in a large licensed package for it is a deliberate decision, not
/// something to slip in here. Returning null means a PDF is skipped rather than
/// indexed with garbage, which is the honest failure.
Future<String?> _unsupportedPdf(File file) async => null;

/// Image text extraction (OCR) is not implemented and cannot be, offline, in
/// pure Dart. It would need an ML Kit / Tesseract dependency plus a platform
/// channel per platform. Registered so the extension is recognised and quietly
/// skipped instead of silently indexing nothing.
Future<String?> _unsupportedImage(File file) async => null;

// --- OOXML -------------------------------------------------------------

/// Text inside `<tag>…</tag>` pairs, unescaped. Deliberately a regex sweep
/// rather than a full XML parse: only a handful of tags in OOXML carry visible
/// text, and `package:xml` is not a direct dependency of this app.
///
/// ponytail: tag sweep, not a parser. Swap in `package:xml` if these ever need
/// structure (tables, cell types) rather than a flat text stream.
List<String> _tagText(String xml, String tag) => RegExp(
      '<$tag(?:\\s[^>]*)?>(.*?)</$tag>',
      dotAll: true,
    ).allMatches(xml).map((m) => _unescape(m.group(1)!)).toList();

String _unescape(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    // Last: an escaped `&amp;lt;` must not become `<`.
    .replaceAll('&amp;', '&');

/// Decodes [file] as a ZIP, or null when it is not one.
Archive? _openZip(File file) {
  try {
    return ZipDecoder().decodeBytes(file.readAsBytesSync());
  } catch (_) {
    return null;
  }
}

/// UTF-8 content of the archive entry at [name], or null.
String? _entry(Archive archive, String name) {
  try {
    final f = archive.findFile(name);
    if (f == null || !f.isFile) return null;
    return utf8.decode(f.content as List<int>, allowMalformed: true);
  } catch (_) {
    return null;
  }
}

Future<String?> _docx(File file) async {
  final archive = _openZip(file);
  if (archive == null) return null;
  var xml = _entry(archive, 'word/document.xml');
  if (xml == null) return null;
  // Paragraph ends become newlines before the run sweep, so the extracted text
  // keeps the document's line structure instead of collapsing to one blob.
  xml = xml.replaceAll('</w:p>', '</w:p>\n');
  final out = <String>[];
  for (final line in xml.split('\n')) {
    final runs = _tagText(line, 'w:t');
    if (runs.isNotEmpty) out.add(runs.join());
  }
  return out.isEmpty ? null : out.join('\n');
}

Future<String?> _pptx(File file) async {
  final archive = _openZip(file);
  if (archive == null) return null;
  final slides = archive.files
      .where((f) => f.isFile && RegExp(r'^ppt/slides/slide\d+\.xml$').hasMatch(f.name))
      .toList()
    ..sort((a, b) => a.name.length == b.name.length
        ? a.name.compareTo(b.name)
        : a.name.length.compareTo(b.name.length));

  final out = <String>[];
  for (final slide in slides) {
    final xml = _entry(archive, slide.name);
    if (xml == null) continue;
    out.addAll(_tagText(xml, 'a:t'));
  }
  return out.isEmpty ? null : out.join('\n');
}

final _cellPattern = RegExp(r'<c(\s[^>]*)?>(.*?)</c>', dotAll: true);

Future<String?> _xlsx(File file) async {
  final archive = _openZip(file);
  if (archive == null) return null;

  final out = <String>[];
  final shared = _entry(archive, 'xl/sharedStrings.xml');
  // Nearly all cell text in a real workbook lives in the shared string table;
  // the sheets themselves hold indices into it plus inline numbers.
  if (shared != null) out.addAll(_tagText(shared, 't'));

  final sheets = archive.files
      .where((f) => f.isFile && RegExp(r'^xl/worksheets/sheet\d+\.xml$').hasMatch(f.name))
      .toList()
    ..sort((a, b) => a.name.length == b.name.length
        ? a.name.compareTo(b.name)
        : a.name.length.compareTo(b.name.length));
  for (final sheet in sheets) {
    final xml = _entry(archive, sheet.name);
    if (xml == null) continue;
    for (final cell in _cellPattern.allMatches(xml)) {
      final attrs = cell.group(1) ?? '';
      final inner = cell.group(2)!;
      // A `t="s"` cell's <v> is an *index* into the shared table, not text —
      // emitting it would pollute the corpus with bare row numbers. The string
      // itself is already in `out` from sharedStrings.
      if (attrs.contains('t="s"')) continue;
      out.addAll(_tagText(inner, 't'));
      out.addAll(_tagText(inner, 'v'));
    }
  }

  final text = out.where((t) => t.trim().isNotEmpty).join('\n');
  return text.isEmpty ? null : text;
}
