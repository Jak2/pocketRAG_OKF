// test/settings/llm_library_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pocket_rag_okf/secrets/secret_store.dart';
import 'package:pocket_rag_okf/settings/engine_settings.dart';
import 'package:pocket_rag_okf/settings/llm_library.dart';

class _FakeSecretStore implements SecretStore {
  final Map<String, String> values;
  _FakeSecretStore([Map<String, String>? initial]) : values = {...?initial};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  const onDeviceA = LlmEntry.onDevice(
    id: 'a',
    label: 'Qwen 0.5B',
    modelPath: '/sdcard/models/qwen.gguf',
  );
  const onDeviceB = LlmEntry.onDevice(
    id: 'b',
    label: 'TinyLlama',
    modelPath: '/sdcard/models/tiny.gguf',
  );
  const cloudC = LlmEntry.cloud(
    id: 'c',
    label: 'My OpenAI',
    endpoint: 'https://api.example.com/v1/chat',
    model: 'gpt-x',
    headers: 'X-Org: acme',
  );

  test('load returns an empty library when nothing saved', () async {
    final prefs = await SharedPreferences.getInstance();
    final library = await LlmLibrary.load(prefs);
    expect(library.entries, isEmpty);
    expect(library.activeEntryId, isNull);
    expect(library.activeEntry, isNull);
  });

  test('add does not replace an existing entry', () {
    final library = const LlmLibrary().add(onDeviceA).add(onDeviceB);
    expect(library.entries.length, 2);
    expect(library.entries.map((e) => e.modelPath),
        ['/sdcard/models/qwen.gguf', '/sdcard/models/tiny.gguf']);
  });

  test('add makes the first entry active, later adds do not steal focus', () {
    final library = const LlmLibrary().add(onDeviceA).add(onDeviceB);
    expect(library.activeEntryId, 'a');
  });

  test('add rejects a duplicate id', () {
    final library = const LlmLibrary().add(onDeviceA);
    expect(() => library.add(onDeviceA), throwsArgumentError);
  });

  test('setActive and activeEntry', () {
    final library = const LlmLibrary().add(onDeviceA).add(cloudC).setActive('c');
    expect(library.activeEntryId, 'c');
    expect(library.activeEntry, cloudC);
  });

  test('setActive rejects an unknown id', () {
    final library = const LlmLibrary().add(onDeviceA);
    expect(() => library.setActive('nope'), throwsArgumentError);
  });

  test('removing the active entry clears activeEntryId', () {
    final library = const LlmLibrary().add(onDeviceA).add(onDeviceB).setActive('b');
    final after = library.remove('b');
    expect(after.entries.map((e) => e.id), ['a']);
    expect(after.activeEntryId, isNull);
    expect(after.activeEntry, isNull);
  });

  test('removing a non-active entry keeps the active one', () {
    final library = const LlmLibrary().add(onDeviceA).add(onDeviceB).setActive('a');
    final after = library.remove('b');
    expect(after.entries.map((e) => e.id), ['a']);
    expect(after.activeEntryId, 'a');
  });

  test('removing a non-existent id is a no-op', () {
    final library = const LlmLibrary().add(onDeviceA).setActive('a');
    final after = library.remove('nope');
    expect(after.entries.map((e) => e.id), ['a']);
    expect(after.activeEntryId, 'a');
  });

  test('save then load round-trips both entry kinds losslessly', () async {
    final prefs = await SharedPreferences.getInstance();
    final library = const LlmLibrary().add(onDeviceA).add(cloudC).setActive('c');
    await library.save(prefs);

    final loaded = await LlmLibrary.load(prefs);
    expect(loaded.activeEntryId, 'c');
    expect(loaded.entries, [onDeviceA, cloudC]);

    final device = loaded.entries[0];
    expect(device.kind, LlmKind.onDevice);
    expect(device.modelPath, '/sdcard/models/qwen.gguf');

    final cloud = loaded.entries[1];
    expect(cloud.kind, LlmKind.cloud);
    expect(cloud.endpoint, 'https://api.example.com/v1/chat');
    expect(cloud.model, 'gpt-x');
    expect(cloud.headers, 'X-Org: acme');
  });

  test('a cloud entry exposes a per-entry secret key, never the secret itself', () async {
    final prefs = await SharedPreferences.getInstance();
    expect(cloudC.secretKey, 'cloud_api_key_c');
    expect(onDeviceA.secretKey, isNull);

    await const LlmLibrary().add(cloudC).save(prefs);

    // The key name is derived from the id, so nothing key-shaped is persisted:
    // the entry has nowhere to put a secret value.
    final dump = prefs.getKeys().map((k) => '$k=${prefs.get(k)}').join('\n').toLowerCase();
    expect(dump, isNot(contains('sk-')));
    expect(dump, isNot(contains('secret')));
    expect(dump, isNot(contains('key')));
  });

  test('save writes exactly one preferences key', () async {
    final prefs = await SharedPreferences.getInstance();
    await const LlmLibrary().add(onDeviceA).add(cloudC).save(prefs);
    expect(prefs.getKeys(), {'llm_library_v1'});
  });

  test('load survives corrupt stored JSON by returning an empty library', () async {
    SharedPreferences.setMockInitialValues({'llm_library_v1': 'not json'});
    final prefs = await SharedPreferences.getInstance();
    final library = await LlmLibrary.load(prefs);
    expect(library.entries, isEmpty);
  });

  test('copyWith replaces fields without mutating the original', () {
    final library = const LlmLibrary().add(onDeviceA);
    final renamed = library.copyWith(
      entries: [onDeviceA.copyWith(label: 'Renamed')],
    );
    expect(renamed.entries.single.label, 'Renamed');
    expect(library.entries.single.label, 'Qwen 0.5B');
  });

  group('loadLlmLibrary migration from a pre-library install', () {
    test('imports a saved on-device model as the first, active entry', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await const EngineSettings(
        choice: EngineChoice.onDevice,
        onDeviceModelPath: '/sdcard/models/qwen.gguf',
      ).save(prefs);

      final library = await loadLlmLibrary(prefs, _FakeSecretStore());
      expect(library.entries.length, 1);
      expect(library.activeEntry?.modelPath, '/sdcard/models/qwen.gguf');
      expect(library.activeEntry?.label, 'qwen.gguf');

      // Persisted, so the import happens once rather than on every load.
      final reloaded = await LlmLibrary.load(prefs);
      expect(reloaded.entries.length, 1);
    });

    test('imports saved cloud settings and moves the API key to a per-entry secret', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await const EngineSettings(
        choice: EngineChoice.cloud,
        cloudEndpoint: 'https://api.example.com/v1/chat',
        cloudModel: 'gpt-x',
        cloudHeaders: 'X-Org: acme',
      ).save(prefs);
      final secrets = _FakeSecretStore({secretKeyCloudApiKey: 'sk-legacy'});

      final library = await loadLlmLibrary(prefs, secrets);
      final active = library.activeEntry!;
      expect(active.kind, LlmKind.cloud);
      expect(active.endpoint, 'https://api.example.com/v1/chat');
      expect(active.model, 'gpt-x');
      expect(active.headers, 'X-Org: acme');
      expect(active.label, 'gpt-x');
      expect(secrets.values[active.secretKey], 'sk-legacy');
    });

    test('imports both kinds and keeps the engine the user was actually on active', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await const EngineSettings(
        choice: EngineChoice.onDevice,
        cloudEndpoint: 'https://api.example.com/v1/chat',
        onDeviceModelPath: '/sdcard/models/qwen.gguf',
      ).save(prefs);

      final library = await loadLlmLibrary(prefs, _FakeSecretStore());
      expect(library.entries.length, 2);
      expect(library.activeEntryId, legacyOnDeviceEntryId);
    });

    test('leaves an existing library alone — migration runs only when empty', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await const EngineSettings(onDeviceModelPath: '/sdcard/models/qwen.gguf').save(prefs);
      await const LlmLibrary().add(onDeviceB).save(prefs);

      final library = await loadLlmLibrary(prefs, _FakeSecretStore());
      expect(library.entries.map((e) => e.id), ['b']);
    });

    test('a fresh install migrates nothing and stays empty', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final library = await loadLlmLibrary(prefs, _FakeSecretStore());
      expect(library.entries, isEmpty);
      expect(prefs.getKeys(), isNot(contains('llm_library_v1')));
    });
  });

  group('applyActiveEntry mirrors the active entry into EngineSettings', () {
    test('an on-device entry sets the choice and the model path', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final library = const LlmLibrary().add(onDeviceA);

      await applyActiveEntry(library, prefs, _FakeSecretStore());
      final settings = await EngineSettings.load(prefs);
      expect(settings.choice, EngineChoice.onDevice);
      expect(settings.onDeviceModelPath, '/sdcard/models/qwen.gguf');
    });

    test('a cloud entry copies its own key into the slot engine resolution reads', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final secrets = _FakeSecretStore({cloudC.secretKey!: 'sk-c'});
      final library = const LlmLibrary().add(onDeviceA).add(cloudC).setActive('c');

      await applyActiveEntry(library, prefs, secrets);
      final settings = await EngineSettings.load(prefs);
      expect(settings.choice, EngineChoice.cloud);
      expect(settings.cloudEndpoint, 'https://api.example.com/v1/chat');
      expect(settings.cloudModel, 'gpt-x');
      expect(settings.cloudHeaders, 'X-Org: acme');
      expect(settings.onDeviceModelPath, isEmpty);
      expect(secrets.values[secretKeyCloudApiKey], 'sk-c');
    });

    test('no active entry blanks the mirror so nothing resolves to a deleted model', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final secrets = _FakeSecretStore({secretKeyCloudApiKey: 'sk-old'});
      await const EngineSettings(
        choice: EngineChoice.onDevice,
        cloudEndpoint: 'https://api.example.com/v1/chat',
        onDeviceModelPath: '/sdcard/models/qwen.gguf',
      ).save(prefs);

      await applyActiveEntry(const LlmLibrary(), prefs, secrets);
      final settings = await EngineSettings.load(prefs);
      expect(settings.onDeviceModelPath, isEmpty);
      expect(settings.cloudEndpoint, isEmpty);
      expect(secrets.values[secretKeyCloudApiKey], isEmpty);
    });

    test('unrelated settings survive the mirror', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await const EngineSettings(okfBundlePath: '/docs/structure.md').save(prefs);

      await applyActiveEntry(const LlmLibrary().add(onDeviceA), prefs, _FakeSecretStore());
      final settings = await EngineSettings.load(prefs);
      expect(settings.okfBundlePath, '/docs/structure.md');
    });
  });
}
