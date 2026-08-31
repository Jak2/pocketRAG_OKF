/// Renders a conversation as an OKF-shaped markdown document.
///
/// Markdown rather than PDF or .docx on purpose: this app already reads
/// markdown, so an exported transcript dropped into the knowledge folder
/// becomes a searchable source on the next reindex. Writing a binary format
/// would need a dependency *and* would produce a file the app cannot read back.
library;

/// One turn to render. Deliberately not the UI's `ChatTurn` — keeping this
/// function free of Flutter types is what lets it be tested without a widget.
class TranscriptTurn {
  final bool fromUser;
  final String text;

  /// Which retrieval mode answered, e.g. `OKF`. Null for user turns and for
  /// answers produced with no retrieval.
  final String? mode;

  /// Cited source paths, in the order they were retrieved.
  final List<String> sources;

  const TranscriptTurn({
    required this.fromUser,
    required this.text,
    this.mode,
    this.sources = const [],
  });
}

/// Renders [turns] as markdown with OKF frontmatter.
///
/// [questionsOnly] drops the answers and keeps just what was asked — the
/// common case for someone building a list of open questions rather than
/// archiving a session.
String renderTranscript({
  required List<TranscriptTurn> turns,
  required DateTime at,
  String title = 'Conversation',
  bool questionsOnly = false,
}) {
  final buffer = StringBuffer()
    ..writeln('---')
    ..writeln('type: ${questionsOnly ? 'questions' : 'transcript'}')
    ..writeln('title: ${_escapeYaml(title)}')
    ..writeln('description: ${questionsOnly ? 'Questions asked' : 'Chat transcript'} '
        'exported from Pocket RAG')
    ..writeln('created: ${at.toIso8601String()}')
    ..writeln('---')
    ..writeln()
    ..writeln('# ${title.trim().isEmpty ? 'Conversation' : title.trim()}')
    ..writeln();

  final questions = turns.where((t) => t.fromUser).toList();

  if (questionsOnly) {
    if (questions.isEmpty) {
      buffer.writeln('_No questions were asked in this session._');
      return buffer.toString();
    }
    for (var i = 0; i < questions.length; i++) {
      buffer.writeln('${i + 1}. ${_collapse(questions[i].text)}');
    }
    return buffer.toString();
  }

  if (turns.isEmpty) {
    buffer.writeln('_This session is empty._');
    return buffer.toString();
  }

  for (final turn in turns) {
    if (turn.fromUser) {
      buffer
        ..writeln('## ${_collapse(turn.text)}')
        ..writeln();
      continue;
    }

    if (turn.mode != null) {
      buffer
        ..writeln('*Answered via ${turn.mode}.*')
        ..writeln();
    }
    buffer
      ..writeln(turn.text.trim())
      ..writeln();

    if (turn.sources.isNotEmpty) {
      buffer.writeln('Sources:');
      for (final source in turn.sources) {
        // A markdown link, so an exported transcript sitting in the bundle
        // links back into the concepts it cited and the graph walk can follow
        // it like any other concept.
        buffer.writeln('- [$source]($source)');
      }
      buffer.writeln();
    }
  }
  return buffer.toString();
}

/// Flattens newlines so a multi-line question stays one heading or list item.
String _collapse(String text) => text.trim().replaceAll(RegExp(r'\s*\n\s*'), ' ');

/// Quotes a frontmatter value that would otherwise break the `key: value`
/// parse — the app's own parser splits on the first colon.
String _escapeYaml(String value) {
  final flat = _collapse(value);
  return flat.contains(':') ? '"${flat.replaceAll('"', r'\"')}"' : flat;
}

/// A filesystem-safe filename for an export taken at [at].
String transcriptFileName(DateTime at, {bool questionsOnly = false}) {
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp = '${at.year}-${two(at.month)}-${two(at.day)}-${two(at.hour)}${two(at.minute)}';
  return '$stamp-${questionsOnly ? 'questions' : 'transcript'}.md';
}
