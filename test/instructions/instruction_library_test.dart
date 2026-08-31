import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rag_okf/instructions/instruction_library.dart';

void main() {
  late Directory tempDir;
  late InstructionLibrary library;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('instruction_library_test_');
    library = InstructionLibrary(root: Directory('${tempDir.path}/lib_root'));
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('slugify lowercases and hyphenates', () {
    expect(slugify('Code Reviewer'), 'code-reviewer');
    expect(slugify('  Solution   Architect! '), 'solution-architect');
  });

  test('list is empty for a fresh library', () async {
    expect(await library.list(), isEmpty);
  });

  test('add creates an entry retrievable via list and contentFor', () async {
    final entry = await library.add(
      name: 'Code Reviewer',
      description: 'Reviews code for correctness',
      content: '# Code Reviewer\nThink like a reviewer.',
    );
    expect(entry.slug, 'code-reviewer');

    final all = await library.list();
    expect(all, hasLength(1));
    expect(all.single.name, 'Code Reviewer');
    expect(all.single.description, 'Reviews code for correctness');
    expect(all.single.content, contains('Think like a reviewer.'));

    expect(await library.contentFor('code-reviewer'), contains('Think like a reviewer.'));
  });

  test('add rejects a slug collision', () async {
    await library.add(name: 'Debugger', description: 'd1', content: 'c1');
    expect(
      () => library.add(name: 'Debugger', description: 'd2', content: 'c2'),
      throwsStateError,
    );
  });

  test('update changes metadata and content independently', () async {
    await library.add(name: 'Analyst', description: 'orig desc', content: 'orig content');
    await library.update('analyst', description: 'new desc');
    var all = await library.list();
    expect(all.single.description, 'new desc');
    expect(all.single.content, 'orig content');

    await library.update('analyst', content: 'new content');
    all = await library.list();
    expect(all.single.content, 'new content');
    expect(all.single.description, 'new desc');
  });

  test('delete removes an entry; deleting a nonexistent slug is a no-op', () async {
    await library.add(name: 'Validator', description: 'v', content: 'vc');
    await library.delete('validator');
    expect(await library.list(), isEmpty);
    expect(await library.contentFor('validator'), isNull);

    await library.delete('does-not-exist'); // must not throw
  });

  test('contentFor returns null for an unknown slug', () async {
    expect(await library.contentFor('nope'), isNull);
  });

  test('list returns empty (not throws) when manifest.json is corrupt', () async {
    await library.root.create(recursive: true);
    await File('${library.root.path}/manifest.json').writeAsString('{not valid json');

    expect(await library.list(), isEmpty);
  });
}
