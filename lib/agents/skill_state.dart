import 'package:shared_preferences/shared_preferences.dart';

/// Which skills are switched on.
///
/// The skills themselves — name, description, body — live in
/// [InstructionLibrary] as markdown files on disk. This records nothing but
/// the set of enabled slugs, so a skill can never exist in two places and
/// disagree with itself.
class SkillState {
  final Set<String> enabledSlugs;

  SkillState([Iterable<String> slugs = const []]) : enabledSlugs = {...slugs};

  bool isEnabled(String slug) => enabledSlugs.contains(slug);

  /// Flips [slug]; returns a new state. Enabling an unknown slug is allowed —
  /// [load] is where reality is enforced, and a caller toggling a slug it just
  /// read from the library is not lying.
  SkillState toggle(String slug) => SkillState(
        enabledSlugs.contains(slug)
            ? (enabledSlugs.toSet()..remove(slug))
            : (enabledSlugs.toSet()..add(slug)),
      );

  static const _key = 'enabled_skills_v1';

  /// Reads the saved slugs, dropping any that [knownSlugs] no longer contains.
  ///
  /// A deleted skill whose slug is later reused by an unrelated skill would
  /// otherwise come back switched on, silently injecting instructions the user
  /// never enabled. Filtering on load also means a stale slug disappears for
  /// good on the next save.
  static Future<SkillState> load(
    SharedPreferences prefs, {
    required Iterable<String> knownSlugs,
  }) async {
    final known = knownSlugs.toSet();
    final stored = prefs.getStringList(_key) ?? const [];
    return SkillState(stored.where(known.contains));
  }

  Future<void> save(SharedPreferences prefs) =>
      prefs.setStringList(_key, enabledSlugs.toList()..sort());
}
