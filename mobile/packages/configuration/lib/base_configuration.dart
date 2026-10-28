import 'dart:convert';
import 'dart:io' as io;

import 'package:bip39/bip39.dart' as bip39;
import 'package:ente_base/models/database.dart';
import 'package:ente_base/models/key_attributes.dart';
import 'package:ente_base/models/key_gen_result.dart';
import 'package:ente_base/models/private_key_attributes.dart';
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
import 'package:tuple/tuple.dart';

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

  Future<KeyGenResult> generateKey(String password) async {
    final masterKey = CryptoUtil.generateKey();

    final recoveryKey = CryptoUtil.generateKey();

    final encryptedMasterKey = CryptoUtil.encryptSync(masterKey, recoveryKey);
    final encryptedRecoveryKey = CryptoUtil.encryptSync(recoveryKey, masterKey);

    final kekSalt = CryptoUtil.getSaltToDeriveKey();
    final derivedKeyResult = await CryptoUtil.deriveSensitiveKey(
      utf8.encode(password),
      kekSalt,
    );
    final loginKey = await CryptoUtil.deriveLoginKey(derivedKeyResult.key);

    final encryptedKeyData = CryptoUtil.encryptSync(
      masterKey,
      derivedKeyResult.key,
    );

    final keyPair = CryptoUtil.generateKeyPair();
    final encryptedSecretKeyData = CryptoUtil.encryptSync(
      keyPair.secretKey,
      masterKey,
    );

    final attributes = KeyAttributes(
      CryptoUtil.bin2base64(kekSalt),
      CryptoUtil.bin2base64(encryptedKeyData.encryptedData!),
      CryptoUtil.bin2base64(encryptedKeyData.nonce!),
      CryptoUtil.bin2base64(keyPair.publicKey),
      CryptoUtil.bin2base64(encryptedSecretKeyData.encryptedData!),
      CryptoUtil.bin2base64(encryptedSecretKeyData.nonce!),
      derivedKeyResult.memLimit,
      derivedKeyResult.opsLimit,
      CryptoUtil.bin2base64(encryptedMasterKey.encryptedData!),
      CryptoUtil.bin2base64(encryptedMasterKey.nonce!),
      CryptoUtil.bin2base64(encryptedRecoveryKey.encryptedData!),
      CryptoUtil.bin2base64(encryptedRecoveryKey.nonce!),
    );
    final privateAttributes = PrivateKeyAttributes(
      CryptoUtil.bin2base64(masterKey),
      CryptoUtil.bin2hex(recoveryKey),
      CryptoUtil.bin2base64(keyPair.secretKey),
    );
    return KeyGenResult(attributes, privateAttributes, loginKey);
  }

  Future<Tuple2<KeyAttributes, Uint8List>> getAttributesForNewPassword(
    String password,
  ) async {
    final masterKey = getKey();

    final kekSalt = CryptoUtil.getSaltToDeriveKey();
    final derivedKeyResult = await CryptoUtil.deriveSensitiveKey(
      utf8.encode(password),
      kekSalt,
    );
    final loginKey = await CryptoUtil.deriveLoginKey(derivedKeyResult.key);

    final encryptedKeyData = CryptoUtil.encryptSync(
      masterKey!,
      derivedKeyResult.key,
    );

    final existingAttributes = getKeyAttributes();

    final updatedAttributes = existingAttributes!.copyWith(
      kekSalt: CryptoUtil.bin2base64(kekSalt),
      encryptedKey: CryptoUtil.bin2base64(encryptedKeyData.encryptedData!),
      keyDecryptionNonce: CryptoUtil.bin2base64(encryptedKeyData.nonce!),
      memLimit: derivedKeyResult.memLimit,
      opsLimit: derivedKeyResult.opsLimit,
    );
    return Tuple2(updatedAttributes, loginKey);
  }

  Future<Uint8List> decryptSecretsAndGetKeyEncKey(
    String password,
    KeyAttributes attributes, {
    Uint8List? keyEncryptionKey,
  }) async {
    _logger.info('Start decryptAndSaveSecrets');
    keyEncryptionKey ??= await CryptoUtil.deriveKey(
      utf8.encode(password),
      CryptoUtil.base642bin(attributes.kekSalt),
      attributes.memLimit,
      attributes.opsLimit,
    );

    _logger.info('user-key done');
    Uint8List key;
    try {
      key = CryptoUtil.decryptSync(
        CryptoUtil.base642bin(attributes.encryptedKey),
        keyEncryptionKey,
        CryptoUtil.base642bin(attributes.keyDecryptionNonce),
      );
    } catch (e) {
      _logger.severe('master-key failed, incorrect password?', e);
      throw Exception("Incorrect password");
    }
    _logger.info("master-key done");
    await setKey(CryptoUtil.bin2base64(key));
    final secretKey = CryptoUtil.decryptSync(
      CryptoUtil.base642bin(attributes.encryptedSecretKey),
      key,
      CryptoUtil.base642bin(attributes.secretKeyDecryptionNonce),
    );
    _logger.info("secret-key done");
    await setSecretKey(CryptoUtil.bin2base64(secretKey));
    final token = CryptoUtil.openSealSync(
      CryptoUtil.base642bin(getEncryptedToken()!),
      CryptoUtil.base642bin(attributes.publicKey),
      secretKey,
    );
    _logger.info('appToken done');
    await setToken(CryptoUtil.bin2base64(token, urlSafe: true));
    return keyEncryptionKey;
  }

  Future<void> recover(String recoveryKey) async {
    if (recoveryKey.contains(' ')) {
      final split = recoveryKey.split(' ');
      if (split.length != mnemonicKeyWordCount) {
        String wordThatIsFollowedByEmptySpaceInSplit = '';
        for (int i = 0; i < split.length; i++) {
          final String word = split[i];
          if (word.isEmpty) {
            wordThatIsFollowedByEmptySpaceInSplit =
                '\n\nExtra space after word at position $i';
            break;
          }
        }
        throw AssertionError(
          '\nRecovery code should have $mnemonicKeyWordCount words, '
          'found ${split.length} words instead.$wordThatIsFollowedByEmptySpaceInSplit',
        );
      }
      recoveryKey = bip39.mnemonicToEntropy(recoveryKey);
    }
    final attributes = getKeyAttributes();
    Uint8List masterKey;
    try {
      masterKey = await CryptoUtil.decrypt(
        CryptoUtil.base642bin(attributes!.masterKeyEncryptedWithRecoveryKey),
        CryptoUtil.hex2bin(recoveryKey),
        CryptoUtil.base642bin(attributes.masterKeyDecryptionNonce),
      );
    } catch (e) {
      _logger.severe(e);
      rethrow;
    }
    await setKey(CryptoUtil.bin2base64(masterKey));
    final secretKey = CryptoUtil.decryptSync(
      CryptoUtil.base642bin(attributes.encryptedSecretKey),
      masterKey,
      CryptoUtil.base642bin(attributes.secretKeyDecryptionNonce),
    );
    await setSecretKey(CryptoUtil.bin2base64(secretKey));
    final token = CryptoUtil.openSealSync(
      CryptoUtil.base642bin(getEncryptedToken()!),
      CryptoUtil.base642bin(attributes.publicKey),
      secretKey,
    );
    await setToken(CryptoUtil.bin2base64(token, urlSafe: true));
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
