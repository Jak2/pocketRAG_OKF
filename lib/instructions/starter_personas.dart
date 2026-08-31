import 'instruction_library.dart';

const starterPersonaAssets = <String, String>{
  'Code Reviewer': 'assets/personas/code_reviewer.md',
  'Debugger': 'assets/personas/debugger.md',
  'Solution Architect': 'assets/personas/solution_architect.md',
  'Validator': 'assets/personas/validator.md',
  'Analyst': 'assets/personas/analyst.md',
  'SEO Optimizer': 'assets/personas/seo_optimizer.md',
  'Security Analyst': 'assets/personas/security_analyst.md',
};

Future<void> seedStarterPersonasIfEmpty(
  InstructionLibrary personas,
  Future<String> Function(String assetPath) loadAsset,
) async {
  final existing = await personas.list();
  if (existing.isNotEmpty) return;
  for (final entry in starterPersonaAssets.entries) {
    final content = await loadAsset(entry.value);
    await personas.add(name: entry.key, description: '${entry.key} persona', content: content);
  }
}
