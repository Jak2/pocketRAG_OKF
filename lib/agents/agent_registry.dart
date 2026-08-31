import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// One user-defined agent: a name, the LLM it runs on, and optionally its own
/// logic file.
///
/// [modelId] is an [LlmEntry.id] from `llm_library.dart` — a reference, never a
/// copy of the model config, so re-pointing a model's endpoint does not leave
/// stale duplicates behind on every agent that uses it. The referenced model
/// may have been deleted; [AgentRegistry] does not repair that, the UI resolves
/// it and shows the agent as needing a model.
///
/// [logicPath] overrides [EngineSettings.agentLogicPath] for this agent only.
/// Null means "use the global one".
class AgentEntry {
  final String id;
  final String name;
  final String modelId;
  final String? logicPath;

  const AgentEntry({
    required this.id,
    required this.name,
    required this.modelId,
    this.logicPath,
  });

  AgentEntry copyWith({String? name, String? modelId, String? logicPath, bool clearLogicPath = false}) =>
      AgentEntry(
        id: id,
        name: name ?? this.name,
        modelId: modelId ?? this.modelId,
        logicPath: clearLogicPath ? null : (logicPath ?? this.logicPath),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'modelId': modelId,
        if (logicPath != null) 'logicPath': logicPath,
      };

  static AgentEntry fromJson(Map<String, dynamic> json) => AgentEntry(
        id: json['id'] as String,
        name: json['name'] as String? ?? '',
        modelId: json['modelId'] as String? ?? '',
        logicPath: json['logicPath'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is AgentEntry &&
      other.id == id &&
      other.name == name &&
      other.modelId == modelId &&
      other.logicPath == logicPath;

  @override
  int get hashCode => Object.hash(id, name, modelId, logicPath);
}

/// The saved agents plus which one is active. Immutable; mirrors [LlmLibrary].
class AgentRegistry {
  final List<AgentEntry> agents;
  final String? activeAgentId;

  const AgentRegistry({this.agents = const [], this.activeAgentId});

  AgentEntry? get activeAgent {
    for (final a in agents) {
      if (a.id == activeAgentId) return a;
    }
    return null;
  }

  /// Appends [agent]; the first one added becomes active. Throws on a
  /// duplicate id, which would make [remove] and [setActive] ambiguous.
  AgentRegistry add(AgentEntry agent) {
    if (agents.any((a) => a.id == agent.id)) {
      throw ArgumentError.value(agent.id, 'agent.id', 'An agent with this id already exists');
    }
    return AgentRegistry(agents: [...agents, agent], activeAgentId: activeAgentId ?? agent.id);
  }

  /// Replaces the agent with [agent].id; an unknown id is a no-op.
  AgentRegistry update(AgentEntry agent) => AgentRegistry(
        agents: [for (final a in agents) a.id == agent.id ? agent : a],
        activeAgentId: activeAgentId,
      );

  /// Removes [id]; unknown ids are a no-op.
  ///
  /// Removing the active agent clears [activeAgentId] rather than reassigning
  /// it, exactly as [LlmLibrary.remove] does: an id pointing at a deleted agent
  /// is a dangling reference, and quietly promoting a neighbour would run a
  /// persona the user never selected.
  AgentRegistry remove(String id) {
    final kept = agents.where((a) => a.id != id).toList();
    if (kept.length == agents.length) return this;
    return AgentRegistry(agents: kept, activeAgentId: activeAgentId == id ? null : activeAgentId);
  }

  AgentRegistry setActive(String id) {
    if (!agents.any((a) => a.id == id)) {
      throw ArgumentError.value(id, 'id', 'No agent with this id');
    }
    return AgentRegistry(agents: agents, activeAgentId: id);
  }

  static const _key = 'agent_registry_v1';

  static Future<AgentRegistry> load(SharedPreferences prefs) async {
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const AgentRegistry();
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final agents = (json['agents'] as List)
          .map((a) => AgentEntry.fromJson(a as Map<String, dynamic>))
          .toList();
      final active = json['activeAgentId'] as String?;
      return AgentRegistry(
        agents: agents,
        activeAgentId: agents.any((a) => a.id == active) ? active : null,
      );
    } on Object catch (e) {
      // ponytail: same call as LlmLibrary.load — corrupt JSON starts empty
      // rather than crashing launch, and says so.
      // ignore: avoid_print
      print('AgentRegistry.load: discarding unreadable $_key ($e)');
      return const AgentRegistry();
    }
  }

  Future<void> save(SharedPreferences prefs) async {
    await prefs.setString(
      _key,
      jsonEncode({
        'agents': agents.map((a) => a.toJson()).toList(),
        'activeAgentId': activeAgentId,
      }),
    );
  }
}
