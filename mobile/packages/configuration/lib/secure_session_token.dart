import 'package:ente_configuration/secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SecureSessionToken {
  static const tokenKey = 'token';
  static const stateKey = 'session_token_state';
  static const secureState = 'secure';
  static const migratingState = 'migrating';
  static const loggingOutState = 'logging_out';
  static const loggedOutState = 'logged_out';

  final SharedPreferences _preferences;
  final FlutterSecureStorage _secureStorage;
  final Future<T> Function<T>(Future<T> Function() action)? _runExclusive;
  Future<void> _pending = Future.value();
  String? _token;
  final Set<String> _ownedTokens = {};
  int _generation = 0;
  bool _requiresLogout = false;

  SecureSessionToken(
    this._preferences,
    this._secureStorage, {
    Future<T> Function<T>(Future<T> Function() action)? runExclusive,
  }) : _runExclusive = runExclusive;

  String? get token => _token;
  bool get requiresLogout => _requiresLogout;

  Future<void> initialize({
    required Future<void> Function() resetSecureStorage,
  }) {
    final generation = _generation;
    _token = null;
    _requiresLogout = false;
    return _run(() async {
      await _preferences.reload();
      if (generation != _generation) return;
      var state = _preferences.getString(stateKey);
      final legacyToken = _preferences.getString(tokenKey);
      if (state == loggingOutState) {
        _requiresLogout = true;
        return;
      }
      if (state == loggedOutState) {
        await _deleteToken();
        await _removeLegacyToken();
        _ownedTokens.clear();
        return;
      }
      if (state == null && legacyToken == null) {
        await resetSecureStorage();
        await flushSecureStorage(_secureStorage);
        if (generation != _generation) return;
        await _setState(loggedOutState);
        _ownedTokens.clear();
        return;
      }
      if (state == null) {
        await _setState(migratingState);
        if (generation != _generation) return;
        state = migratingState;
      }
      var token = await readSecureStorage(_secureStorage, tokenKey);
      if (generation != _generation) return;
      if (token == null && state == migratingState && legacyToken != null) {
        _ownedTokens.add(legacyToken);
        await _secureStorage.write(key: tokenKey, value: legacyToken);
        token = await readSecureStorage(_secureStorage, tokenKey);
        if (token != legacyToken) {
          throw StateError('Session token could not be verified');
        }
      }
      if (token == null) {
        _requiresLogout = true;
        return;
      }
      if (legacyToken != null) await flushSecureStorage(_secureStorage);
      await _preferences.reload();
      if (generation != _generation ||
          _preferences.getString(stateKey) != state ||
          _preferences.getString(tokenKey) != legacyToken) {
        return;
      }
      await _setState(secureState);
      if (generation != _generation) return;
      await _removeLegacyToken();
      if (generation == _generation) {
        _token = token;
        _ownedTokens
          ..clear()
          ..add(token);
      }
    });
  }

  Future<bool> setToken(String token) {
    final generation = _generation;
    return _run(() async {
      await _preferences.reload();
      if (generation != _generation) return false;
      if (_preferences.getString(stateKey) == loggingOutState) {
        throw StateError('Account cleanup is incomplete');
      }
      _ownedTokens.add(token);
      await _secureStorage.write(key: tokenKey, value: token);
      await flushSecureStorage(_secureStorage);
      if (await readSecureStorage(_secureStorage, tokenKey) != token) {
        throw StateError('Session token could not be verified');
      }
      if (generation != _generation) return false;
      await _setState(secureState);
      if (generation != _generation) return false;
      await _removeLegacyToken();
      if (generation != _generation) return false;
      _token = token;
      _ownedTokens
        ..clear()
        ..add(token);
      return true;
    });
  }

  Future<bool> logout(
    Future<void> Function() clearAccount, {
    bool autoLogout = false,
  }) {
    final ownedTokens = Set<String>.of(_ownedTokens);
    _generation++;
    _token = null;
    _requiresLogout = true;
    return _run(() async {
      await _preferences.reload();
      final state = _preferences.getString(stateKey);
      if (state != loggingOutState) {
        String? storedToken;
        bool unreadableToken = false;
        try {
          storedToken = await readSecureStorage(_secureStorage, tokenKey);
        } on PlatformException catch (e) {
          if (!e.toString().contains('BadPaddingException')) rethrow;
          unreadableToken = true;
        }
        if (!unreadableToken &&
            ((storedToken != null && !ownedTokens.contains(storedToken)) ||
                (autoLogout &&
                    state == loggedOutState &&
                    storedToken == null))) {
          _requiresLogout = false;
          _ownedTokens.clear();
          return false;
        }
      }
      await _setState(loggingOutState);
      await _deleteToken();
      await _removeLegacyToken();
      await clearAccount();
      await flushSecureStorage(_secureStorage);
      await _setState(loggedOutState);
      _requiresLogout = false;
      _ownedTokens.clear();
      return true;
    });
  }

  Future<void> clearPreferences() async {
    await _preferences.reload();
    for (final key in _preferences.getKeys().where((key) => key != stateKey)) {
      if (!await _preferences.remove(key)) {
        throw StateError('Preferences could not be cleared');
      }
    }
  }

  static Future<String?> read(
    SharedPreferences preferences,
    FlutterSecureStorage secureStorage,
  ) async {
    await preferences.reload();
    final state = preferences.getString(stateKey);
    final legacyToken = preferences.getString(tokenKey);
    if (state == loggedOutState ||
        state == loggingOutState ||
        (state == null && legacyToken == null)) {
      return null;
    }
    final token = await readSecureStorage(secureStorage, tokenKey);
    await preferences.reload();
    if (preferences.getString(stateKey) != state ||
        preferences.getString(tokenKey) != legacyToken) {
      return null;
    }
    return token ??
        (state == null || state == migratingState ? legacyToken : null);
  }

  Future<void> _deleteToken() async {
    await deleteSecureStorage(_secureStorage, key: tokenKey);
    await flushSecureStorage(_secureStorage);
    if (await readSecureStorage(_secureStorage, tokenKey) != null) {
      throw StateError('Session token could not be deleted');
    }
  }

  Future<void> _removeLegacyToken() async {
    if (!await _preferences.remove(tokenKey)) {
      throw StateError('Legacy session token could not be removed');
    }
  }

  Future<void> _setState(String state) async {
    if (!await _preferences.setString(stateKey, state)) {
      throw StateError('Session token state could not be saved');
    }
  }

  Future<T> _run<T>(Future<T> Function() action) {
    final result = _pending.then((_) {
      final runExclusive = _runExclusive;
      return runExclusive == null ? action() : runExclusive<T>(action);
    });
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
