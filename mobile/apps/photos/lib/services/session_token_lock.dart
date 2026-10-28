import 'dart:async';

import 'package:ente_photos_platform/ente_photos_platform.dart';
import 'package:synchronized/synchronized.dart';

class SessionTokenLock {
  SessionTokenLock({
    ProcessLockClient? client,
    Duration waitTimeout = const Duration(seconds: 30),
  }) : _client = client ?? ProcessLockClient.instance,
       _waitTimeout = waitTimeout;

  static final instance = SessionTokenLock();
  static const _lockName = 'session_token';
  static const _pollInterval = Duration(milliseconds: 50);

  final ProcessLockClient _client;
  final Duration _waitTimeout;
  final Lock _funnel = Lock();

  Future<T> runExclusive<T>(Future<T> Function() action) =>
      _funnel.synchronized(() => _runExclusive(action));

  Future<T> _runExclusive<T>(Future<T> Function() action) async {
    final deadline = DateTime.now().add(_waitTimeout);
    while (!await _client.tryAcquire(
      name: _lockName,
      origin: 'configuration',
      operation: 'update',
    )) {
      if (!DateTime.now().isBefore(deadline)) {
        throw TimeoutException('Timed out waiting for session token storage');
      }
      await Future<void>.delayed(_pollInterval);
    }
    try {
      return await action();
    } finally {
      if (!await _client.release(name: _lockName)) {
        throw StateError('Session token storage lock could not be released');
      }
    }
  }
}
