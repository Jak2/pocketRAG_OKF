sealed class SlashCommand {}

class SkillCommand extends SlashCommand {
  final String slug;
  SkillCommand(this.slug);
}

class PersonaCommand extends SlashCommand {
  final String slug;
  PersonaCommand(this.slug);
}

final _slashPattern = RegExp(r'^/([a-z0-9-]+)(:([a-z0-9-]+))?$');

SlashCommand? parseSlashCommand(String text) {
  final trimmed = text.trim();
  final match = _slashPattern.firstMatch(trimmed);
  if (match == null) return null;

  final prefix = match.group(1)!;
  final suffix = match.group(3);

  if (suffix != null) {
    return prefix == 'persona' ? PersonaCommand(suffix) : null;
  }
  return SkillCommand(prefix);
}
