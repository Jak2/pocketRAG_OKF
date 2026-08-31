// test/agents/agent_registry_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pocket_rag_okf/agents/agent_registry.dart';
import 'package:pocket_rag_okf/settings/llm_library.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  const triage = AgentEntry(id: 'a1', name: 'Incident triage agent', modelId: 'm1');
  const drafter = AgentEntry(id: 'a2', name: 'Retry-policy drafter', modelId: 'm2', logicPath: 'agent/retry.md');

  test('load returns an empty registry when nothing saved', () async {
    final prefs = await SharedPreferences.getInstance();
    final registry = await AgentRegistry.load(prefs);
    expect(registry.agents, isEmpty);
    expect(registry.activeAgentId, isNull);
    expect(registry.activeAgent, isNull);
  });

  test('add appends and makes only the first agent active', () {
    final registry = const AgentRegistry().add(triage).add(drafter);
    expect(registry.agents.length, 2);
    expect(registry.activeAgentId, 'a1');
  });

  test('add rejects a duplicate id', () {
    expect(() => const AgentRegistry().add(triage).add(triage), throwsArgumentError);
  });

  test('update replaces in place and keeps the active selection', () {
    final registry = const AgentRegistry()
        .add(triage)
        .add(drafter)
        .update(triage.copyWith(name: 'Renamed', modelId: 'm9'));
    expect(registry.agents.first.name, 'Renamed');
    expect(registry.agents.first.modelId, 'm9');
    expect(registry.agents.length, 2);
    expect(registry.activeAgentId, 'a1');
  });

  test('update with an unknown id is a no-op', () {
    final registry = const AgentRegistry()
        .add(triage)
        .update(const AgentEntry(id: 'nope', name: 'Ghost', modelId: 'm1'));
    expect(registry.agents, [triage]);
  });

  // The bug the llm_library tests guard against for models: a deleted active
  // entry must not leave the id dangling, and must not silently promote a
  // neighbour the user never picked.
  test('deleting the active agent clears the active id', () {
    final registry = const AgentRegistry().add(triage).add(drafter).remove('a1');
    expect(registry.activeAgentId, isNull);
    expect(registry.activeAgent, isNull);
    expect(registry.agents, [drafter]);
  });

  test('deleting a non-active agent leaves the active id alone', () {
    final registry = const AgentRegistry().add(triage).add(drafter).remove('a2');
    expect(registry.activeAgentId, 'a1');
  });

  test('setActive throws for an unknown id', () {
    expect(() => const AgentRegistry().add(triage).setActive('nope'), throwsArgumentError);
  });

  test('save and load round-trip agents and the active id', () async {
    final prefs = await SharedPreferences.getInstance();
    await const AgentRegistry().add(triage).add(drafter).setActive('a2').save(prefs);

    final loaded = await AgentRegistry.load(prefs);
    expect(loaded.agents, [triage, drafter]);
    expect(loaded.activeAgentId, 'a2');
    expect(loaded.activeAgent?.logicPath, 'agent/retry.md');
  });

  test('load clears an active id that no longer names a stored agent', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('agent_registry_v1',
        '{"agents":[{"id":"a1","name":"Triage","modelId":"m1"}],"activeAgentId":"gone"}');
    expect((await AgentRegistry.load(prefs)).activeAgentId, isNull);
  });

  test('corrupt stored json degrades to an empty registry instead of throwing', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('agent_registry_v1', 'not json');
    expect((await AgentRegistry.load(prefs)).agents, isEmpty);
  });

  // An agent points at a model by id, so deleting the model leaves a reference
  // the registry deliberately does not repair — the UI resolves it and can say
  // "pick a model". Nothing here may throw or drop the agent.
  test('an agent referencing a deleted model survives, unresolved', () async {
    final prefs = await SharedPreferences.getInstance();
    const library = LlmLibrary(entries: [
      LlmEntry.onDevice(id: 'm1', label: 'Qwen', modelPath: '/models/q.gguf'),
    ]);
    final afterDelete = library.remove('m1');

    await const AgentRegistry().add(triage).save(prefs);
    final registry = await AgentRegistry.load(prefs);

    expect(registry.agents.single.modelId, 'm1');
    expect(afterDelete.entries.where((e) => e.id == registry.agents.single.modelId), isEmpty);
  });
}
