import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../secrets/secret_store.dart';
import 'engine_settings.dart';

enum LlmKind { onDevice, cloud }

/// One saved LLM the user can activate.
///
/// Two shapes share one class (mirroring [EngineChoice] in engine_settings.dart):
/// on-device carries [modelPath]; cloud carries [endpoint], [model] and optional
/// [headers]. The unused fields are null.
///
/// An API key is NEVER a field here — this object is persisted to
/// shared_preferences. Cloud entries expose [secretKey], the name under which
/// the key lives in `flutter_secure_storage` (see lib/secrets/secret_store.dart).
class LlmEntry {
  final LlmKind kind;
  final String id;
  final String label;

  /// on-device only
  final String? modelPath;

  /// cloud only
  final String? endpoint;
  final String? model;

  /// cloud only — raw "Header: value" lines, one per line, as in [EngineSettings].
  final String? headers;

  const LlmEntry.onDevice({
    required this.id,
    required this.label,
    required this.modelPath,
  })  : kind = LlmKind.onDevice,
        endpoint = null,
        model = null,
        headers = null;

  const LlmEntry.cloud({
    required this.id,
    required this.label,
    required this.endpoint,
    required this.model,
    this.headers,
  })  : kind = LlmKind.cloud,
        modelPath = null;

  const LlmEntry._({
    required this.kind,
    required this.id,
    required this.label,
    this.modelPath,
    this.endpoint,
    this.model,
    this.headers,
  });

  /// Secure-storage key holding this entry's API key, or null for on-device.
  /// Derived from [id] so the secret itself can never be stored on the entry.
  String? get secretKey => kind == LlmKind.cloud ? '$secretKeyCloudApiKeyPrefix$id' : null;

  static const secretKeyCloudApiKeyPrefix = 'cloud_api_key_';

  LlmEntry copyWith({
    String? label,
    String? modelPath,
    String? endpoint,
    String? model,
    String? headers,
  }) {
    return LlmEntry._(
      kind: kind,
      id: id,
      label: label ?? this.label,
      modelPath: modelPath ?? this.modelPath,
      endpoint: endpoint ?? this.endpoint,
      model: model ?? this.model,
      headers: headers ?? this.headers,
    );
  }

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'id': id,
        'label': label,
        if (modelPath != null) 'modelPath': modelPath,
        if (endpoint != null) 'endpoint': endpoint,
        if (model != null) 'model': model,
        if (headers != null) 'headers': headers,
      };

  static LlmEntry fromJson(Map<String, dynamic> json) => LlmEntry._(
        kind: LlmKind.values.firstWhere(
          (k) => k.name == json['kind'],
          orElse: () => LlmKind.cloud,
        ),
        id: json['id'] as String,
        label: json['label'] as String? ?? '',
        modelPath: json['modelPath'] as String?,
        endpoint: json['endpoint'] as String?,
        model: json['model'] as String?,
        headers: json['headers'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is LlmEntry &&
      other.kind == kind &&
      other.id == id &&
      other.label == label &&
      other.modelPath == modelPath &&
      other.endpoint == endpoint &&
      other.model == model &&
      other.headers == headers;

  @override
  int get hashCode => Object.hash(kind, id, label, modelPath, endpoint, model, headers);
}

/// The saved list of LLMs plus which one is active. Immutable; every operation
/// returns a new library.
class LlmLibrary {
  final List<LlmEntry> entries;
  final String? activeEntryId;

  const LlmLibrary({this.entries = const [], this.activeEntryId});

  LlmLibrary copyWith({
    List<LlmEntry>? entries,
    String? activeEntryId,
    bool clearActive = false,
  }) {
    return LlmLibrary(
      entries: entries ?? this.entries,
      activeEntryId: clearActive ? null : (activeEntryId ?? this.activeEntryId),
    );
  }

  LlmEntry? get activeEntry {
    for (final e in entries) {
      if (e.id == activeEntryId) return e;
    }
    return null;
  }

  /// Appends [entry]. Never replaces an existing one — that was the bug.
  /// The first entry added becomes active; later ones do not steal the
  /// selection. Throws [ArgumentError] on a duplicate id, since a duplicate
  /// would make [remove] and [setActive] ambiguous.
  LlmLibrary add(LlmEntry entry) {
    if (entries.any((e) => e.id == entry.id)) {
      throw ArgumentError.value(entry.id, 'entry.id', 'An LLM with this id already exists');
    }
    return LlmLibrary(
      entries: [...entries, entry],
      activeEntryId: activeEntryId ?? entry.id,
    );
  }

  /// Removes the entry with [id]; unknown ids are a no-op.
  ///
  /// If the removed entry was active, [activeEntryId] is cleared to null rather
  /// than silently reassigned to a neighbour — the user picks the next model
  /// explicitly, so the UI can never imply a model is loaded that the user did
  /// not choose. It is never left dangling at a deleted id.
  LlmLibrary remove(String id) {
    final kept = entries.where((e) => e.id != id).toList();
    if (kept.length == entries.length) return this;
    return LlmLibrary(
      entries: kept,
      activeEntryId: activeEntryId == id ? null : activeEntryId,
    );
  }

  /// Activates [id]. Throws [ArgumentError] if no such entry exists.
  LlmLibrary setActive(String id) {
    if (!entries.any((e) => e.id == id)) {
      throw ArgumentError.value(id, 'id', 'No LLM with this id');
    }
    return LlmLibrary(entries: entries, activeEntryId: id);
  }

  static const _key = 'llm_library_v1';

  static Future<LlmLibrary> load(SharedPreferences prefs) async {
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const LlmLibrary();
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final entries = (json['entries'] as List)
          .map((e) => LlmEntry.fromJson(e as Map<String, dynamic>))
          .toList();
      final active = json['activeEntryId'] as String?;
      return LlmLibrary(
        entries: entries,
        activeEntryId: entries.any((e) => e.id == active) ? active : null,
      );
    } on Object catch (e) {
      // ponytail: corrupt stored JSON is unrecoverable — start empty rather than
      // crash the app on launch. Logged, not swallowed silently.
      // ignore: avoid_print
      print('LlmLibrary.load: discarding unreadable $_key ($e)');
      return const LlmLibrary();
    }
  }

  Future<void> save(SharedPreferences prefs) async {
    await prefs.setString(
      _key,
      jsonEncode({
        'entries': entries.map((e) => e.toJson()).toList(),
        'activeEntryId': activeEntryId,
      }),
    );
  }
}

/// Ids given to entries imported from a pre-library install. Fixed rather than
/// generated so a second migration pass can never duplicate them.
const legacyOnDeviceEntryId = 'legacy-on-device';
const legacyCloudEntryId = 'legacy-cloud';

/// Loads the library, importing a pre-library setup on first run.
///
/// Before the library existed, Config held exactly one on-device path and one
/// set of cloud fields in [EngineSettings]. On upgrade those become the first
/// entries — including copying the single stored API key to the cloud entry's
/// own [LlmEntry.secretKey] — so nobody loses the LLM they had configured.
/// The entry matching the engine they were actually using stays active.
///
/// Runs only when the stored library is empty; once anything is saved, the
/// library is the truth and [EngineSettings] is its mirror (see
/// [applyActiveEntry]).
Future<LlmLibrary> loadLlmLibrary(SharedPreferences prefs, SecretStore secrets) async {
  final stored = await LlmLibrary.load(prefs);
  if (stored.entries.isNotEmpty) return stored;

  final legacy = await EngineSettings.load(prefs);
  var library = const LlmLibrary();

  if (legacy.onDeviceModelPath.isNotEmpty) {
    library = library.add(LlmEntry.onDevice(
      id: legacyOnDeviceEntryId,
      label: legacy.onDeviceModelPath.split('/').last,
      modelPath: legacy.onDeviceModelPath,
    ));
  }
  if (legacy.cloudEndpoint.isNotEmpty) {
    final imported = LlmEntry.cloud(
      id: legacyCloudEntryId,
      label: legacy.cloudModel.isEmpty ? 'Cloud API' : legacy.cloudModel,
      endpoint: legacy.cloudEndpoint,
      model: legacy.cloudModel,
      headers: legacy.cloudHeaders,
    );
    library = library.add(imported);
    final key = await secrets.read(secretKeyCloudApiKey);
    if (key != null && key.isNotEmpty) {
      await secrets.write(imported.secretKey!, key);
    }
  }

  if (library.entries.isEmpty) return library;

  final wanted =
      legacy.choice == EngineChoice.onDevice ? legacyOnDeviceEntryId : legacyCloudEntryId;
  if (library.entries.any((e) => e.id == wanted)) library = library.setActive(wanted);
  await library.save(prefs);
  return library;
}

/// Mirrors the active entry into [EngineSettings] and the single API-key slot
/// the engine resolution path reads.
///
/// The library is the truth; [EngineSettings] is a derived copy kept in sync so
/// `buildEngine()` and the chat screen keep resolving one engine from one
/// place. With no active entry the mirror is blanked, which makes
/// `buildEngine()` return null — the chat screen then says the LLM is not
/// configured, rather than quietly using a model the user just deleted.
Future<void> applyActiveEntry(
  LlmLibrary library,
  SharedPreferences prefs,
  SecretStore secrets,
) async {
  final base = await EngineSettings.load(prefs);
  final active = library.activeEntry;

  if (active == null) {
    await base
        .copyWith(
          choice: EngineChoice.cloud,
          cloudEndpoint: '',
          cloudModel: '',
          cloudHeaders: '',
          onDeviceModelPath: '',
        )
        .save(prefs);
    await secrets.write(secretKeyCloudApiKey, '');
    return;
  }

  switch (active.kind) {
    case LlmKind.onDevice:
      await base
          .copyWith(
            choice: EngineChoice.onDevice,
            onDeviceModelPath: active.modelPath ?? '',
          )
          .save(prefs);
    case LlmKind.cloud:
      await base
          .copyWith(
            choice: EngineChoice.cloud,
            cloudEndpoint: active.endpoint ?? '',
            cloudModel: active.model ?? '',
            cloudHeaders: active.headers ?? '',
            onDeviceModelPath: '',
          )
          .save(prefs);
      await secrets.write(secretKeyCloudApiKey, await secrets.read(active.secretKey!) ?? '');
  }
}
