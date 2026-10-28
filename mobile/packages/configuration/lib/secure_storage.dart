import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const _channel = MethodChannel('io.ente.configuration/secure_storage');

Future<void> flushSecureStorage(FlutterSecureStorage storage) async {
  if (!Platform.isAndroid) return;
  await _channel.invokeMethod<void>('flush', {
    'options': storage.aOptions.toMap(),
  });
}

Future<String?> readSecureStorage(FlutterSecureStorage storage, String key) {
  if (!Platform.isIOS) return storage.read(key: key);
  return _channel.invokeMethod<String>('read', {
    'key': key,
    'options': storage.iOptions.toMap(),
  });
}

Future<void> deleteSecureStorage(FlutterSecureStorage storage, {String? key}) {
  if (!Platform.isIOS) {
    return key == null ? storage.deleteAll() : storage.delete(key: key);
  }
  return _channel.invokeMethod<void>(key == null ? 'deleteAll' : 'delete', {
    'key': ?key,
    'options': storage.iOptions.toMap(),
  });
}
