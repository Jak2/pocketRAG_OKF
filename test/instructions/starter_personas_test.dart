import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rag_okf/instructions/instruction_library.dart';
import 'package:pocket_rag_okf/instructions/starter_personas.dart';

void main() {
  late Directory tempDir;
  late InstructionLibrary personas;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('starter_personas_test_');
    personas = InstructionLibrary(root: Directory('${tempDir.path}/personas'));
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<String> fakeLoadAsset(String path) async => 'content for $path';

  test('seeds all starter personas into an empty library', () async {
    await seedStarterPersonasIfEmpty(personas, fakeLoadAsset);
    final all = await personas.list();
    expect(all, hasLength(starterPersonaAssets.length));
    final names = all.map((e) => e.name).toSet();
    expect(names, starterPersonaAssets.keys.toSet());
  });

  test('does nothing if the library already has entries', () async {
    await personas.add(name: 'Custom Persona', description: 'd', content: 'c');
    await seedStarterPersonasIfEmpty(personas, fakeLoadAsset);
    final all = await personas.list();
    expect(all, hasLength(1));
    expect(all.single.name, 'Custom Persona');
  });
}
