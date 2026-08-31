import 'dart:io';

import 'package:path/path.dart' as p;

import '../okf/parser.dart' show splitFrontmatter;
import '../retrieval/context_assembler.dart' show kSystemPrompt;
import '../retrieval/retrieval_result.dart' show RetrievalMode;

/// One `pattern -> mode` line from a logic file's Routing section.
class RoutingRule {
  final RegExp pattern;
  final RetrievalMode mode;

  const RoutingRule(this.pattern, this.mode);
}

/// A parsed agent-logic markdown file: persona, routing rules, tool permissions.
///
/// Parsing follows lib/okf/parser.dart's rules exactly: unknown sections are
/// ignored, unreadable lines are skipped rather than raised, and nothing here
/// ever throws. A file that only has a persona is a valid file; so is one that
/// parses to nothing.
class AgentLogic {
  /// The persona text, or empty when the file had no Persona section.
  final String persona;

  /// True when the persona should stand alone instead of being prefixed to
  /// [kSystemPrompt]. Set with `prompt: replace` in the frontmatter.
  final bool replacesSystemPrompt;

  /// In file order — [routeFor] takes the first match, so the author's order is
  /// the precedence.
  final List<RoutingRule> routingRules;

  /// Extensions this agent may cite, lowercase without dots, matching
  /// [EngineSettings.fileToolSet]. Empty means "no opinion" — the caller's own
  /// default applies. Parsed only; wiring belongs to the file-tools ingestion.
  final Set<String> allowedTools;

  const AgentLogic({
    this.persona = '',
    this.replacesSystemPrompt = false,
    this.routingRules = const [],
    this.allowedTools = const {},
  });

  bool get isEmpty => persona.isEmpty && routingRules.isEmpty && allowedTools.isEmpty;

  /// The system prompt to actually send.
  ///
  /// Prefixed by default rather than replaced: the built-in prompt carries the
  /// citation and "say you don't know" rules, and a persona that quietly drops
  /// them turns a grounded assistant into a confabulating one. Authors who
  /// really want that say `prompt: replace`.
  String systemPrompt([String base = kSystemPrompt]) {
    if (persona.isEmpty) return base;
    return replacesSystemPrompt ? persona : '$persona\n\n$base';
  }

  /// The mode the rules force for [query], or null when none matches and the
  /// router's own heuristics should decide.
  RetrievalMode? routeFor(String query) {
    for (final rule in routingRules) {
      if (rule.pattern.hasMatch(query)) return rule.mode;
    }
    return null;
  }
}

/// Section headings we understand. Anything else is ignored.
const _personaHeadings = {'persona', 'system prompt', 'system'};
const _routingHeadings = {'routing', 'routing rules', 'routes'};
const _toolHeadings = {'tools', 'tool permissions', 'permissions'};

final _headingPattern = RegExp(r'^#{1,6}\s+(.*)$');
final _rulePattern = RegExp(r'^\s*(?:[-*]\s*)?(.+?)\s*(?:->|=>|:)\s*(\w+)\s*$');
final _regexLiteral = RegExp(r'^/(.*)/$');

/// Parses a logic file. Never throws; an unparseable file yields an empty
/// [AgentLogic], which the caller treats the same as no file at all.
AgentLogic parseAgentLogic(String raw) {
  final split = splitFrontmatter(raw);
  final replace = RegExp(r'^\s*prompt\s*:\s*replace\s*$', multiLine: true).hasMatch(split.yaml);

  final persona = StringBuffer();
  final rules = <RoutingRule>[];
  final tools = <String>{};

  String? section;
  for (final line in split.body.replaceAll('\r\n', '\n').split('\n')) {
    final heading = _headingPattern.firstMatch(line);
    if (heading != null) {
      final title = heading.group(1)!.trim().toLowerCase();
      section = _personaHeadings.contains(title)
          ? 'persona'
          : _routingHeadings.contains(title)
              ? 'routing'
              : _toolHeadings.contains(title)
                  ? 'tools'
                  : null; // Unknown section: swallow its body rather than
      // letting stray prose leak into the persona.
      continue;
    }

    switch (section) {
      case 'persona':
        persona.writeln(line);
      case 'routing':
        final rule = _parseRule(line);
        if (rule != null) rules.add(rule);
      case 'tools':
        for (final token in line.split(RegExp(r'[,\s]+'))) {
          final ext = token.replaceAll(RegExp(r'^[-*\s.]+'), '').trim().toLowerCase();
          if (RegExp(r'^[a-z0-9]+$').hasMatch(ext)) tools.add(ext);
        }
      case _:
        break;
    }
  }

  return AgentLogic(
    persona: persona.toString().trim(),
    replacesSystemPrompt: replace,
    routingRules: rules,
    allowedTools: tools,
  );
}

/// `pattern -> okf`, where pattern is either `/a regex/` or plain text matched
/// as a case-insensitive substring. Returns null for anything else, including a
/// regex that does not compile — one bad line must not cost the other rules.
RoutingRule? _parseRule(String line) {
  if (line.trim().isEmpty) return null;
  final m = _rulePattern.firstMatch(line);
  if (m == null) return null;

  final mode = switch (m.group(2)!.toLowerCase()) {
    'okf' || 'graph' => RetrievalMode.graph,
    'rag' || 'vector' => RetrievalMode.vector,
    'auto' => RetrievalMode.auto,
    _ => null,
  };
  if (mode == null) return null;

  var raw = m.group(1)!.trim();
  if (raw.isEmpty) return null;
  final literal = _regexLiteral.firstMatch(raw);
  try {
    return RoutingRule(
      RegExp(literal != null ? literal.group(1)! : RegExp.escape(raw), caseSensitive: false),
      mode,
    );
  } on FormatException {
    return null;
  }
}

/// Loads and caches the logic file for a bundle-relative [logicPath].
///
/// A missing file is not an error — it means "use the built-in prompt", so
/// this returns null and the caller changes nothing.
class AgentLogicResolver {
  final Map<String, AgentLogic?> _cache = {};

  Future<AgentLogic?> resolve({required String bundlePath, required String logicPath}) async {
    if (bundlePath.isEmpty || logicPath.isEmpty) return null;
    final full = p.join(bundlePath, logicPath);
    if (_cache.containsKey(full)) return _cache[full];

    AgentLogic? logic;
    try {
      final file = File(full);
      if (await file.exists()) {
        final parsed = parseAgentLogic(await file.readAsString());
        if (!parsed.isEmpty) logic = parsed;
      }
    } on Object {
      // Unreadable path, permissions, a directory where a file was expected:
      // all mean the same thing to the caller as "no logic file".
      logic = null;
    }
    _cache[full] = logic;
    return logic;
  }

  /// Call after the user edits or re-picks the logic file.
  void clear() => _cache.clear();
}
