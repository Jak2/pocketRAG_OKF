// test/settings/agent_config_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pocket_rag_okf/settings/agent_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('load returns defaults when nothing saved', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final config = await AgentConfig.load(prefs);
    expect(config.defaultPersonaSlug, isNull);
    expect(config.guardrails, '');
    expect(config.langchainEnabled, isFalse);
    expect(config.graphOrchestrationEnabled, isFalse);
    expect(config.maxSteps, 5);
  });

  test('save then load round-trips the framework toggles and loop depth', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    const config = AgentConfig(
      langchainEnabled: true,
      graphOrchestrationEnabled: true,
      maxSteps: 7,
    );
    await config.save(prefs);

    final loaded = await AgentConfig.load(prefs);
    expect(loaded.langchainEnabled, isTrue);
    expect(loaded.graphOrchestrationEnabled, isTrue);
    expect(loaded.maxSteps, 7);
  });

  test('copyWith carries the framework fields through unrelated edits', () {
    const config = AgentConfig(langchainEnabled: true, graphOrchestrationEnabled: true, maxSteps: 3);
    final edited = config.copyWith(guardrails: 'be terse');
    expect(edited.langchainEnabled, isTrue);
    expect(edited.graphOrchestrationEnabled, isTrue);
    expect(edited.maxSteps, 3);
  });

  test('maxSteps is clamped to its bounds on construction and copyWith', () {
    expect(const AgentConfig(maxSteps: 0).maxSteps, AgentConfig.stepsMin);
    expect(const AgentConfig(maxSteps: -20).maxSteps, AgentConfig.stepsMin);
    expect(const AgentConfig(maxSteps: 99).maxSteps, AgentConfig.stepsMax);
    expect(const AgentConfig().copyWith(maxSteps: 500).maxSteps, AgentConfig.stepsMax);
  });

  test('an out-of-range stored depth loads clamped, never out of bounds', () async {
    SharedPreferences.setMockInitialValues({'agent_max_steps': 4000});
    final prefs = await SharedPreferences.getInstance();
    final loaded = await AgentConfig.load(prefs);
    expect(loaded.maxSteps, AgentConfig.stepsMax);

    // ...and saving it back writes the clamped value, so the bad value dies here.
    await loaded.save(prefs);
    expect(prefs.getInt('agent_max_steps'), AgentConfig.stepsMax);
  });

  test('save then load round-trips persona slug and guardrails', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    const config = AgentConfig(defaultPersonaSlug: 'code-reviewer', guardrails: 'Never invent facts.');
    await config.save(prefs);

    final loaded = await AgentConfig.load(prefs);
    expect(loaded.defaultPersonaSlug, 'code-reviewer');
    expect(loaded.guardrails, 'Never invent facts.');
  });

  test('copyWith with clearPersona removes the default persona', () async {
    const config = AgentConfig(defaultPersonaSlug: 'debugger', guardrails: 'g');
    final cleared = config.copyWith(clearPersona: true);
    expect(cleared.defaultPersonaSlug, isNull);
    expect(cleared.guardrails, 'g');
  });

  test('saving a null defaultPersonaSlug removes any previously saved value', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await const AgentConfig(defaultPersonaSlug: 'analyst').save(prefs);
    await const AgentConfig().save(prefs);

    final loaded = await AgentConfig.load(prefs);
    expect(loaded.defaultPersonaSlug, isNull);
  });
}
