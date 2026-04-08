import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists user credentials for auto-login using encrypted storage.
class AuthStorage {
  AuthStorage._();
  static final instance = AuthStorage._();

  static const _keyUsername = 'tuya_username';
  static const _keyPassword = 'tuya_password';
  static const _keyLoggedIn = 'tuya_logged_in';

  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// Save credentials after successful login.
  Future<void> saveCredentials({
    required String username,
    required String password,
  }) async {
    await _storage.write(key: _keyUsername, value: username);
    await _storage.write(key: _keyPassword, value: password);
    await _storage.write(key: _keyLoggedIn, value: 'true');
  }

  /// Retrieve saved credentials for auto-login.
  Future<({String? username, String? password})> getCredentials() async {
    final username = await _storage.read(key: _keyUsername);
    final password = await _storage.read(key: _keyPassword);
    return (username: username, password: password);
  }

  /// Check if we have stored credentials.
  Future<bool> hasCredentials() async {
    final loggedIn = await _storage.read(key: _keyLoggedIn);
    return loggedIn == 'true';
  }

  /// Clear credentials on logout.
  Future<void> clearCredentials() async {
    await _storage.delete(key: _keyUsername);
    await _storage.delete(key: _keyPassword);
    await _storage.delete(key: _keyLoggedIn);
  }
}
