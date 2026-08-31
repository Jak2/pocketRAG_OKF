import 'package:shared_preferences/shared_preferences.dart';

enum EngineChoice { cloud, onDevice }

class EngineSettings {
  final EngineChoice choice;
  final String cloudEndpoint;
  final String cloudApiKey;
  final String cloudModel;
  final String cloudHeaders; // raw "Header: value" lines, one per line
  final String onDeviceModelPath;
  final String okfBundlePath;
  final String embedModelPath;

  /// Last position of the RAG/OKF/Auto switch, so a reopened app answers the
  /// same way it did when the user closed it.
  final String retrievalMode;

  /// `dark` or `light`. Persisted because a theme that resets on every launch
  /// is worse than having no toggle.
  final String themeMode;

  /// Comma-separated file extensions the indexer may read beyond `.md`, e.g.
  /// `pdf,docx`. Empty means markdown only — the app's original behaviour, and
  /// still the default, since every other format costs extraction time.
  final String fileTools;

  /// Bundle-relative path to a markdown file defining the active agent's
  /// persona and routing rules. Empty means the built-in system prompt.
  final String agentLogicPath;

  const EngineSettings({
    this.choice = EngineChoice.cloud,
    this.cloudEndpoint = '',
    this.cloudApiKey = '',
    this.cloudModel = '',
    this.cloudHeaders = '',
    this.onDeviceModelPath = '',
    this.okfBundlePath = '',
    this.embedModelPath = '',
    this.retrievalMode = 'auto',
    this.themeMode = 'dark',
    this.fileTools = '',
    this.agentLogicPath = '',
  });

  /// Extensions the indexer may read, lowercase and without dots.
  Set<String> get fileToolSet => fileTools
      .split(',')
      .map((e) => e.trim().toLowerCase())
      .where((e) => e.isNotEmpty)
      .toSet();

  EngineSettings copyWith({
    EngineChoice? choice,
    String? cloudEndpoint,
    String? cloudApiKey,
    String? cloudModel,
    String? cloudHeaders,
    String? onDeviceModelPath,
    String? okfBundlePath,
    String? embedModelPath,
    String? retrievalMode,
    String? themeMode,
    String? fileTools,
    String? agentLogicPath,
  }) {
    return EngineSettings(
      choice: choice ?? this.choice,
      cloudEndpoint: cloudEndpoint ?? this.cloudEndpoint,
      cloudApiKey: cloudApiKey ?? this.cloudApiKey,
      cloudModel: cloudModel ?? this.cloudModel,
      cloudHeaders: cloudHeaders ?? this.cloudHeaders,
      onDeviceModelPath: onDeviceModelPath ?? this.onDeviceModelPath,
      okfBundlePath: okfBundlePath ?? this.okfBundlePath,
      embedModelPath: embedModelPath ?? this.embedModelPath,
      retrievalMode: retrievalMode ?? this.retrievalMode,
      themeMode: themeMode ?? this.themeMode,
      fileTools: fileTools ?? this.fileTools,
      agentLogicPath: agentLogicPath ?? this.agentLogicPath,
    );
  }

  Map<String, String> get cloudHeadersMap {
    final map = <String, String>{};
    for (final line in cloudHeaders.split('\n')) {
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      map[line.substring(0, idx).trim()] = line.substring(idx + 1).trim();
    }
    return map;
  }

  static const _keyChoice = 'engine_choice';
  static const _keyEndpoint = 'cloud_endpoint';
  static const _keyModel = 'cloud_model';
  static const _keyHeaders = 'cloud_headers';
  static const _keyModelPath = 'on_device_model_path';
  static const _keyOkfBundlePath = 'okf_bundle_path';
  static const _keyEmbedModelPath = 'embed_model_path';
  static const _keyRetrievalMode = 'retrieval_mode';
  static const _keyThemeMode = 'theme_mode';
  static const _keyFileTools = 'file_tools';
  static const _keyAgentLogicPath = 'agent_logic_path';

  static Future<EngineSettings> load(SharedPreferences prefs) async {
    return EngineSettings(
      choice: EngineChoice.values.firstWhere(
        (c) => c.name == prefs.getString(_keyChoice),
        orElse: () => EngineChoice.cloud,
      ),
      cloudEndpoint: prefs.getString(_keyEndpoint) ?? '',
      cloudModel: prefs.getString(_keyModel) ?? '',
      cloudHeaders: prefs.getString(_keyHeaders) ?? '',
      onDeviceModelPath: prefs.getString(_keyModelPath) ?? '',
      okfBundlePath: prefs.getString(_keyOkfBundlePath) ?? '',
      embedModelPath: prefs.getString(_keyEmbedModelPath) ?? '',
      retrievalMode: prefs.getString(_keyRetrievalMode) ?? 'auto',
      themeMode: prefs.getString(_keyThemeMode) ?? 'dark',
      fileTools: prefs.getString(_keyFileTools) ?? '',
      agentLogicPath: prefs.getString(_keyAgentLogicPath) ?? '',
    );
  }

  Future<void> save(SharedPreferences prefs) async {
    await prefs.setString(_keyChoice, choice.name);
    await prefs.setString(_keyEndpoint, cloudEndpoint);
    await prefs.setString(_keyModel, cloudModel);
    await prefs.setString(_keyHeaders, cloudHeaders);
    await prefs.setString(_keyModelPath, onDeviceModelPath);
    await prefs.setString(_keyOkfBundlePath, okfBundlePath);
    await prefs.setString(_keyEmbedModelPath, embedModelPath);
    await prefs.setString(_keyRetrievalMode, retrievalMode);
    await prefs.setString(_keyThemeMode, themeMode);
    await prefs.setString(_keyFileTools, fileTools);
    await prefs.setString(_keyAgentLogicPath, agentLogicPath);
  }
}
