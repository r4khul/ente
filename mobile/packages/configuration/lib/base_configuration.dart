import 'dart:io' as io;

import 'package:ente_base/models/database.dart';
import 'package:ente_base/models/key_attributes.dart';
import 'package:ente_configuration/app_identity.dart';
import 'package:ente_configuration/constants.dart';
import 'package:ente_configuration/secure_session_token.dart';
import 'package:ente_configuration/secure_storage.dart';
import 'package:ente_crypto_api/ente_crypto_api.dart';
import 'package:ente_events/event_bus.dart';
import 'package:ente_events/models/endpoint_updated_event.dart';
import 'package:ente_events/models/signed_in_event.dart';
import 'package:ente_events/models/signed_out_event.dart';
import 'package:ente_logging/logging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

export 'package:ente_configuration/app_identity.dart';

abstract class BaseConfiguration {
  static const endpoint = String.fromEnvironment(
    "endpoint",
    defaultValue: kDefaultProductionEndpoint,
  );
  static const emailKey = "email";
  static const keyAttributesKey = "key_attributes";
  static const keyKey = "key";
  static const secretKeyKey = "secret_key";
  static const tokenKey = SecureSessionToken.tokenKey;
  static const encryptedTokenKey = "encrypted_token";
  static const userIDKey = "user_id";
  static const endPointKey = "endpoint";
  static const lastTempFolderClearTimeKey = "last_temp_folder_clear_time";
  static const accountSecureStorageKeys = [keyKey, secretKeyKey, tokenKey];

  final kTempFolderDeletionTimeBuffer = const Duration(days: 1).inMicroseconds;

  static final _logger = Logger("Configuration");

  SecureSessionToken? _sessionToken;
  late SharedPreferences _preferences;
  String? _key;
  String? _secretKey;
  late FlutterSecureStorage _secureStorage;
  late String _cacheDirectory;
  late String _tempDocumentsDirPath;
  late List<EnteBaseDatabase> _databases;

  String? _volatilePassword;

  EnteAppIdentity get appIdentity;

  List<String> get secureStorageKeys;

  List<String> get lockScreenSecureStorageKeys => const [];

  Future<void> init(List<EnteBaseDatabase> dbs) async {
    _databases = dbs;
    _tempDocumentsDirPath =
        "${p.join((await getApplicationCacheDirectory()).path, "temp")}${p.separator}";
    final preferences = await SharedPreferences.getInstance();
    _secureStorage = const FlutterSecureStorage(
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
      ),
    );
    if (_sessionToken == null || !identical(_preferences, preferences)) {
      _sessionToken = SecureSessionToken(preferences, _secureStorage);
    }
    _preferences = preferences;
    // Set up folders before keys so the cache directory is initialized before
    // _setupKeys() can trigger an auto-logout whose cleanup needs it.
    await _setupFolders();
    await _setupKeys();
    _logger.info("User ID: ${getUserID()}");
  }

  Future<void> logout({bool autoLogout = false}) async {
    if (await _sessionToken!.logout(clearAccount, autoLogout: autoLogout)) {
      Bus.instance.fire(SignedOutEvent());
    }
  }

  @protected
  Future<void> clearAccount() async {
    await _clearTempFolderOnLogout();
    await _sessionToken!.clearPreferences();
    await resetSecureStorage();
    for (final key in lockScreenSecureStorageKeys) {
      await deleteSecureStorage(_secureStorage, key: key);
    }
    for (final db in _databases) {
      await db.clearTable();
    }
    _key = null;
    _secretKey = null;
  }

  Future<void> _clearTempFolderOnLogout() async {
    final tempDirectory = io.Directory(_tempDocumentsDirPath);
    try {
      if (await tempDirectory.exists()) {
        await tempDirectory.delete(recursive: true);
      }
      await tempDirectory.create(recursive: true);
      _logger.info("Cleared temp folder on logout");
    } catch (e, s) {
      _logger.warning("Failed to clear temp folder on logout", e, s);
    }
  }

  Future<void> resetSecureStorage() async {
    assert(
      secureStorageKeys.isNotEmpty,
      'secureStorageKeys must not be empty. Apps must explicitly define which keys to clear.',
    );
    for (final key in secureStorageKeys.toSet()) {
      await deleteSecureStorage(_secureStorage, key: key);
    }
  }

  String getHttpEndpoint() {
    final savedEndpoint = _preferences.getString(endPointKey) ?? endpoint;
    if (savedEndpoint == kLegacyProductionEndpoint) {
      return kDefaultProductionEndpoint;
    }
    return savedEndpoint;
  }

  bool isEnteProduction() {
    return getHttpEndpoint() == kDefaultProductionEndpoint;
  }

  Future<void> setHttpEndpoint(String endpoint) async {
    await _preferences.setString(endPointKey, endpoint);
    Bus.instance.fire(EndpointUpdatedEvent());
  }

  String? getToken() {
    return _sessionToken?.token;
  }

  bool isLoggedIn() {
    return getToken() != null;
  }

  Future<void> setToken(String token) async {
    if (await _sessionToken!.setToken(token)) {
      Bus.instance.fire(SignedInEvent());
    }
  }

  Future<void> setEncryptedToken(String encryptedToken) async {
    await _preferences.setString(encryptedTokenKey, encryptedToken);
  }

  String? getEncryptedToken() {
    return _preferences.getString(encryptedTokenKey);
  }

  String? getEmail() {
    return _preferences.getString(emailKey);
  }

  Future<void> setEmail(String email) async {
    await _preferences.setString(emailKey, email);
  }

  int? getUserID() {
    return _preferences.getInt(userIDKey);
  }

  Future<void> setUserID(int userID) async {
    await _preferences.setInt(userIDKey, userID);
  }

  Future<void> setKeyAttributes(KeyAttributes attributes) async {
    await _preferences.setString(keyAttributesKey, attributes.toJson());
  }

  KeyAttributes? getKeyAttributes() {
    final jsonValue = _preferences.getString(keyAttributesKey);
    if (jsonValue == null) {
      return null;
    } else {
      return KeyAttributes.fromJson(jsonValue);
    }
  }

  Future<void> setKey(String key) async {
    _key = key;
    await _secureStorage.write(key: keyKey, value: key);
  }

  Future<void> setSecretKey(String? secretKey) async {
    _secretKey = secretKey;
    await _secureStorage.write(key: secretKeyKey, value: secretKey);
  }

  Uint8List? getKey() {
    return _key == null ? null : CryptoUtil.base642bin(_key!);
  }

  Uint8List? getSecretKey() {
    return _secretKey == null ? null : CryptoUtil.base642bin(_secretKey!);
  }

  Uint8List getRecoveryKey() {
    final keyAttributes = getKeyAttributes()!;
    return CryptoUtil.decryptSync(
      CryptoUtil.base642bin(keyAttributes.recoveryKeyEncryptedWithMasterKey),
      getKey()!,
      CryptoUtil.base642bin(keyAttributes.recoveryKeyDecryptionNonce),
    );
  }

  // This directory is cleared on app start.
  String getTempDirectory() {
    return _tempDocumentsDirPath;
  }

  String getCacheDirectory() {
    return _cacheDirectory;
  }

  bool hasConfiguredAccount() {
    return getToken() != null && _key != null;
  }

  void setVolatilePassword(String volatilePassword) {
    _volatilePassword = volatilePassword;
  }

  void resetVolatilePassword() {
    _volatilePassword = null;
  }

  String? getVolatilePassword() {
    return _volatilePassword;
  }

  Future<void> _setupKeys() async {
    _key = null;
    _secretKey = null;
    try {
      await _sessionToken!.initialize(resetSecureStorage: resetSecureStorage);
      if (_sessionToken!.requiresLogout) {
        await logout(autoLogout: true);
        return;
      }
      if (getToken() == null) return;
      final token = getToken();
      final key = await readSecureStorage(_secureStorage, keyKey);
      if (getToken() != token) return;
      if (key == null) {
        await logout(autoLogout: true);
        return;
      }
      _key = key;
      final secretKey = await readSecureStorage(_secureStorage, secretKeyKey);
      if (getToken() == token) _secretKey = secretKey;
    } catch (e, s) {
      _logger.severe("Configuration init failed", e, s);
      if (e is PlatformException &&
          e.toString().contains('BadPaddingException')) {
        await logout(autoLogout: true);
        return;
      }
      rethrow;
    }
  }

  Future<void> _setupFolders() async {
    final tempDirectory = io.Directory(_tempDocumentsDirPath);
    try {
      final currentTime = DateTime.now().microsecondsSinceEpoch;
      if (tempDirectory.existsSync() &&
          (_preferences.getInt(lastTempFolderClearTimeKey) ?? 0) <
              (currentTime - kTempFolderDeletionTimeBuffer)) {
        await tempDirectory.delete(recursive: true);
        await _preferences.setInt(lastTempFolderClearTimeKey, currentTime);
        _logger.info("Cleared temp folder");
      } else {
        _logger.info("Skipping temp folder clear");
      }
    } catch (e) {
      _logger.warning(e);
    }
    tempDirectory.createSync(recursive: true);

    _cacheDirectory =
        "${p.join(p.dirname(_tempDocumentsDirPath), "cache")}${p.separator}";
    if (!io.Directory(_cacheDirectory).existsSync()) {
      io.Directory(_cacheDirectory).createSync(recursive: true);
    }
  }
}
