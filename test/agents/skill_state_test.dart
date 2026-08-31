// test/agents/skill_state_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pocket_rag_okf/agents/skill_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  const known = ['summarize-a-source-doc', 'explain-a-routing-decision'];

  test('nothing is enabled in a fresh install', () async {
    final prefs = await SharedPreferences.getInstance();
    final state = await SkillState.load(prefs, knownSlugs: known);
    expect(state.enabledSlugs, isEmpty);
    expect(state.isEnabled('summarize-a-source-doc'), isFalse);
  });

  test('enabling a skill round-trips through save and load', () async {
    final prefs = await SharedPreferences.getInstance();
    await SkillState().toggle('summarize-a-source-doc').save(prefs);

    final reloaded = await SkillState.load(prefs, knownSlugs: known);
    expect(reloaded.isEnabled('summarize-a-source-doc'), isTrue);
    expect(reloaded.isEnabled('explain-a-routing-decision'), isFalse);
  });

  test('toggling twice disables again', () async {
    final prefs = await SharedPreferences.getInstance();
    await SkillState().toggle('summarize-a-source-doc').toggle('summarize-a-source-doc').save(prefs);
    expect((await SkillState.load(prefs, knownSlugs: known)).enabledSlugs, isEmpty);
  });

  test('toggle returns a new state and leaves the old one untouched', () {
    final before = SkillState(['a']);
    final after = before.toggle('b');
    expect(before.enabledSlugs, {'a'});
    expect(after.enabledSlugs, {'a', 'b'});
  });

  // A skill deleted from the library must not come back on. If its slug is
  // later reused by an unrelated skill, resurrecting it would silently inject
  // instructions the user never enabled.
  test('a slug that no longer exists in the library is dropped on load', () async {
    final prefs = await SharedPreferences.getInstance();
    await SkillState(['summarize-a-source-doc', 'deleted-skill']).save(prefs);

    final state = await SkillState.load(prefs, knownSlugs: known);
    expect(state.enabledSlugs, {'summarize-a-source-doc'});
    expect(state.isEnabled('deleted-skill'), isFalse);
  });

  test('a dropped slug is gone for good once the state is saved again', () async {
    final prefs = await SharedPreferences.getInstance();
    await SkillState(['deleted-skill']).save(prefs);
    await (await SkillState.load(prefs, knownSlugs: known)).save(prefs);
    expect((await SkillState.load(prefs, knownSlugs: ['deleted-skill'])).enabledSlugs, isEmpty);
  });
}
