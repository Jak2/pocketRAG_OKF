import 'package:shared_preferences/shared_preferences.dart';

class AgentConfig {
  /// Bounds for [maxSteps]. Public so the Config screen's stepper and any
  /// future orchestration loop read the same numbers instead of each
  /// inventing their own.
  static const stepsMin = 1;
  static const stepsMax = 10;
  static const stepsDefault = 5;

  final String? defaultPersonaSlug;
  final String guardrails;

  /// Whether the LangChain path is preferred. Storing the preference is all
  /// this currently does — chat generation does not yet route through it.
  final bool langchainEnabled;

  /// Whether the app's own in-app graph engine (lib/agent/graph_engine.dart)
  /// is preferred. Not LangGraph — no Dart LangGraph engine exists.
  final bool graphOrchestrationEnabled;

  final int _maxSteps;

  const AgentConfig({
    this.defaultPersonaSlug,
    this.guardrails = '',
    this.langchainEnabled = false,
    this.graphOrchestrationEnabled = false,
    int maxSteps = stepsDefault,
  }) : _maxSteps = maxSteps < stepsMin
            ? stepsMin
            : (maxSteps > stepsMax ? stepsMax : maxSteps);

  /// Loop depth for graph orchestration, always within [stepsMin]..[stepsMax].
  /// Clamped in the constructor, so no path in — a copyWith, a hand-edited
  /// preference file, a value written by an older build — can hand a loop an
  /// out-of-range depth. (A ternary rather than `clamp()` because this
  /// constructor stays `const`.)
  int get maxSteps => _maxSteps;

  AgentConfig copyWith({
    String? defaultPersonaSlug,
    bool clearPersona = false,
    String? guardrails,
    bool? langchainEnabled,
    bool? graphOrchestrationEnabled,
    int? maxSteps,
  }) {
    return AgentConfig(
      defaultPersonaSlug: clearPersona ? null : (defaultPersonaSlug ?? this.defaultPersonaSlug),
      guardrails: guardrails ?? this.guardrails,
      langchainEnabled: langchainEnabled ?? this.langchainEnabled,
      graphOrchestrationEnabled: graphOrchestrationEnabled ?? this.graphOrchestrationEnabled,
      maxSteps: maxSteps ?? this.maxSteps,
    );
  }

  static const _keyPersona = 'agent_default_persona_slug';
  static const _keyGuardrails = 'agent_guardrails';
  static const _keyLangchain = 'agent_langchain_enabled';
  static const _keyGraph = 'agent_graph_orchestration_enabled';
  static const _keyMaxSteps = 'agent_max_steps';

  static Future<AgentConfig> load(SharedPreferences prefs) async {
    return AgentConfig(
      defaultPersonaSlug: prefs.getString(_keyPersona),
      guardrails: prefs.getString(_keyGuardrails) ?? '',
      langchainEnabled: prefs.getBool(_keyLangchain) ?? false,
      graphOrchestrationEnabled: prefs.getBool(_keyGraph) ?? false,
      maxSteps: prefs.getInt(_keyMaxSteps) ?? stepsDefault,
    );
  }

  Future<void> save(SharedPreferences prefs) async {
    if (defaultPersonaSlug == null) {
      await prefs.remove(_keyPersona);
    } else {
      await prefs.setString(_keyPersona, defaultPersonaSlug!);
    }
    await prefs.setString(_keyGuardrails, guardrails);
    await prefs.setBool(_keyLangchain, langchainEnabled);
    await prefs.setBool(_keyGraph, graphOrchestrationEnabled);
    await prefs.setInt(_keyMaxSteps, maxSteps);
  }
}
