import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rag_okf/chat/slash_command.dart';

void main() {
  test('parses a bare skill slug', () {
    final cmd = parseSlashCommand('/code-review');
    expect(cmd, isA<SkillCommand>());
    expect((cmd as SkillCommand).slug, 'code-review');
  });

  test('parses a persona command', () {
    final cmd = parseSlashCommand('/persona:debugger');
    expect(cmd, isA<PersonaCommand>());
    expect((cmd as PersonaCommand).slug, 'debugger');
  });

  test('trims surrounding whitespace before matching', () {
    final cmd = parseSlashCommand('  /persona:analyst  ');
    expect(cmd, isA<PersonaCommand>());
  });

  test('a message that merely contains a slash is not a command', () {
    expect(parseSlashCommand('add a section on CI/CD'), isNull);
  });

  test('a message starting with / but with trailing words is not a command', () {
    expect(parseSlashCommand('/code-review please run it'), isNull);
  });

  test('an unknown colon prefix (not persona) is not a command', () {
    expect(parseSlashCommand('/foo:bar'), isNull);
  });

  test('empty and bare-slash inputs are not commands', () {
    expect(parseSlashCommand(''), isNull);
    expect(parseSlashCommand('/'), isNull);
  });
}
