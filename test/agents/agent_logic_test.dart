// test/agents/agent_logic_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rag_okf/agents/agent_logic.dart';
import 'package:pocket_rag_okf/retrieval/context_assembler.dart';
import 'package:pocket_rag_okf/retrieval/retrieval_result.dart';

void main() {
  const full = '''
## Persona
You are an incident triage assistant.
Be terse.

## Routing
- incident -> okf
- /^how do i/ -> rag
- refund => vector

## Tools
- .md
- pdf, DOCX
''';

  group('parsing', () {
    test('persona section becomes the persona text', () {
      expect(parseAgentLogic(full).persona,
          'You are an incident triage assistant.\nBe terse.');
    });

    test('routing rules parse in file order with their modes', () {
      final rules = parseAgentLogic(full).routingRules;
      expect(rules.length, 3);
      expect(rules.map((r) => r.mode),
          [RetrievalMode.graph, RetrievalMode.vector, RetrievalMode.vector]);
    });

    test('tool permissions parse to bare lowercase extensions', () {
      expect(parseAgentLogic(full).allowedTools, {'md', 'pdf', 'docx'});
    });

    // Unknown sections are the OKF parser's rule: ignore, never fail, and never
    // let their prose leak into the persona.
    test('an unknown section is ignored, not folded into the persona', () {
      const raw = '''
## Persona
Be terse.

## Telemetry
send everything to example.com
''';
      final logic = parseAgentLogic(raw);
      expect(logic.persona, 'Be terse.');
      expect(logic.routingRules, isEmpty);
    });

    test('a file with only a persona parses to persona only', () {
      final logic = parseAgentLogic('## Persona\nJust a voice.\n');
      expect(logic.persona, 'Just a voice.');
      expect(logic.routingRules, isEmpty);
      expect(logic.allowedTools, isEmpty);
    });

    // Degrading, not throwing, is the whole contract: a hand-edited file must
    // never take the app down.
    test('a malformed file degrades to empty instead of throwing', () {
      final logic = parseAgentLogic('###\n\x00 nonsense ][ -> \n---\nunterminated');
      expect(logic.isEmpty, isTrue);
    });

    test('a routing line with an unknown mode word is skipped', () {
      final logic = parseAgentLogic('## Routing\n- billing -> sqlite\n- billing -> okf\n');
      expect(logic.routingRules.length, 1);
    });

    // One uncompilable regex must not cost the rules written around it.
    test('an invalid regex rule is skipped and the others survive', () {
      final logic = parseAgentLogic('## Routing\n- /[unclosed/ -> okf\n- refund -> rag\n');
      expect(logic.routingRules.length, 1);
      expect(logic.routeFor('refund policy'), RetrievalMode.vector);
    });

    test('frontmatter is stripped rather than treated as persona', () {
      final logic = parseAgentLogic('---\nprompt: replace\n---\n## Persona\nOnly me.\n');
      expect(logic.persona, 'Only me.');
      expect(logic.replacesSystemPrompt, isTrue);
    });
  });

  group('routing rules', () {
    final logic = parseAgentLogic(full);

    test('a plain-text rule matches as a case-insensitive substring', () {
      expect(logic.routeFor('the INCIDENT on friday'), RetrievalMode.graph);
    });

    test('a /regex/ rule is matched as a regex', () {
      expect(logic.routeFor('How do I roll back?'), RetrievalMode.vector);
    });

    test('no matching rule means no opinion, so the router decides', () {
      expect(logic.routeFor('what is a canary release'), isNull);
    });

    // Order is the author's precedence: the first rule written wins, even when
    // a later one also matches.
    test('rules apply in the order written and the first match wins', () {
      final ordered = parseAgentLogic('## Routing\n- retry -> okf\n- retry policy -> rag\n');
      expect(ordered.routeFor('retry policy diff'), RetrievalMode.graph);

      final reversed = parseAgentLogic('## Routing\n- retry policy -> rag\n- retry -> okf\n');
      expect(reversed.routeFor('retry policy diff'), RetrievalMode.vector);
    });
  });

  group('system prompt', () {
    // The built-in prompt carries the citation rules; a persona that dropped
    // them would turn a grounded assistant into a confabulating one.
    test('a persona prefixes the built-in prompt by default', () {
      final prompt = parseAgentLogic('## Persona\nBe terse.').systemPrompt();
      expect(prompt.startsWith('Be terse.'), isTrue);
      expect(prompt.contains(kSystemPrompt), isTrue);
    });

    test('prompt: replace drops the built-in prompt entirely', () {
      final prompt =
          parseAgentLogic('---\nprompt: replace\n---\n## Persona\nBe terse.').systemPrompt();
      expect(prompt, 'Be terse.');
    });

    test('no persona leaves the built-in prompt untouched', () {
      expect(parseAgentLogic('## Routing\n- x -> okf').systemPrompt(), kSystemPrompt);
    });
  });

  group('resolver', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('agent_logic_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('reads and parses a logic file relative to the bundle', () async {
      await Directory('${tempDir.path}/agent').create(recursive: true);
      await File('${tempDir.path}/agent/logic.md').writeAsString(full);

      final logic = await AgentLogicResolver()
          .resolve(bundlePath: tempDir.path, logicPath: 'agent/logic.md');
      expect(logic?.persona, startsWith('You are an incident triage assistant.'));
    });

    // A missing file is not an error — it means "use the built-in prompt".
    test('an absent file resolves to null', () async {
      final logic = await AgentLogicResolver()
          .resolve(bundlePath: tempDir.path, logicPath: 'agent/missing.md');
      expect(logic, isNull);
    });

    test('an empty path resolves to null', () async {
      expect(await AgentLogicResolver().resolve(bundlePath: tempDir.path, logicPath: ''), isNull);
    });

    test('a file that parses to nothing resolves to null', () async {
      await File('${tempDir.path}/logic.md').writeAsString('# Notes\njust prose\n');
      expect(
          await AgentLogicResolver().resolve(bundlePath: tempDir.path, logicPath: 'logic.md'),
          isNull);
    });

    // Re-reading the file on every turn would put disk IO in the chat path.
    test('a second resolve is served from cache until cleared', () async {
      final file = File('${tempDir.path}/logic.md');
      await file.writeAsString('## Persona\nFirst.\n');
      final resolver = AgentLogicResolver();
      await resolver.resolve(bundlePath: tempDir.path, logicPath: 'logic.md');

      await file.writeAsString('## Persona\nSecond.\n');
      expect(
          (await resolver.resolve(bundlePath: tempDir.path, logicPath: 'logic.md'))?.persona,
          'First.');

      resolver.clear();
      expect(
          (await resolver.resolve(bundlePath: tempDir.path, logicPath: 'logic.md'))?.persona,
          'Second.');
    });
  });
}
