import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class AiConfigStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
  Future<List<String>> readApiKeys();
  Future<void> writeApiKeys(List<String> apiKeys);
}

class SecureAiConfigStore implements AiConfigStore {
  const SecureAiConfigStore({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
  }) : _storage = storage;

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<List<String>> readApiKeys() async {
    final encodedKeys = await read('ai_api_keys');
    if (encodedKeys != null) {
      final decoded = jsonDecode(encodedKeys);
      if (decoded is! List || decoded.any((key) => key is! String)) {
        throw const FormatException(
            'Gemini API key list in keyring is invalid.');
      }
      return decoded.cast<String>();
    }

    final legacyKey = await read('ai_api_key');
    if (legacyKey == null || legacyKey.isEmpty) return [];
    final keys = [legacyKey];
    await writeApiKeys(keys);
    await delete('ai_api_key');
    return keys;
  }

  @override
  Future<void> writeApiKeys(List<String> apiKeys) async {
    if (apiKeys.isEmpty) {
      await delete('ai_api_keys');
      return;
    }
    await write('ai_api_keys', jsonEncode(apiKeys));
  }
}
