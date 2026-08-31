import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const secretKeyCloudApiKey = 'cloud_api_key';

abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class SecureSecretStore implements SecretStore {
  final FlutterSecureStorage _storage;

  SecureSecretStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);
}
