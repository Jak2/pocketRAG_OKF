import 'tokens.dart';

/// A slice of a concept body or a memory fact, as embedded and retrieved.
class Chunk {
  /// `relpath` of the owning concept, or null when this chunk is a memory fact.
  final String? conceptPath;

  /// Memory fact id, or null when this chunk belongs to a concept.
  final String? memoryId;

  final int ord;
  final String text;

  const Chunk({required this.ord, required this.text, this.conceptPath, this.memoryId})
      : assert((conceptPath == null) != (memoryId == null), 'a chunk has exactly one owner');

  int get nTokens => estimateTokens(text);

  Map<String, Object?> toJson() =>
      {'concept': conceptPath, 'memory': memoryId, 'ord': ord, 'text': text};

  factory Chunk.fromJson(Map<String, Object?> j) => Chunk(
        conceptPath: j['concept'] as String?,
        memoryId: j['memory'] as String?,
        ord: j['ord'] as int,
        text: j['text'] as String,
      );
}

/// Splits [text] into overlapping chunks of roughly [targetTokens].
///
/// Splits on blank lines first so a chunk is a paragraph boundary rather than
/// a sentence fragment; a single paragraph longer than the target is hard-cut
/// rather than dropped. [overlapTokens] of trailing text is repeated into the
/// next chunk so a fact spanning a boundary is retrievable from either side.
List<String> chunkText(String text, {int targetTokens = 220, int overlapTokens = 40}) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return const [];
  if (estimateTokens(trimmed) <= targetTokens) return [trimmed];

  final maxChars = (targetTokens * kCharsPerToken).floor();
  final overlapChars = (overlapTokens * kCharsPerToken).floor();

  final paragraphs = trimmed.split(RegExp(r'\n\s*\n'));
  final out = <String>[];
  final buffer = StringBuffer();

  void flush() {
    final s = buffer.toString().trim();
    if (s.isNotEmpty) out.add(s);
    buffer.clear();
  }

  for (var para in paragraphs) {
    para = para.trim();
    if (para.isEmpty) continue;

    while (para.length > maxChars) {
      flush();
      out.add(para.substring(0, maxChars).trim());
      // Step back by the overlap so the split point is covered twice.
      para = para.substring(maxChars - overlapChars).trim();
    }

    if (buffer.length + para.length + 2 > maxChars) {
      final previous = buffer.toString();
      flush();
      if (previous.length > overlapChars) {
        buffer.write(previous.substring(previous.length - overlapChars).trimLeft());
        buffer.write('\n\n');
      }
    }
    buffer.write(para);
    buffer.write('\n\n');
  }
  flush();
  return out;
}
