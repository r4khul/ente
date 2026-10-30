import 'dart:async';

import 'package:ente_photos_platform/ente_photos_platform.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos/services/session_token_lock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/session_token_lock');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late SessionTokenLock lock;

  setUp(() {
    calls = [];
    lock = SessionTokenLock(client: ProcessLockClient(methodChannel: channel));
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'serializes local operations and releases the lock after failure',
    () async {
      final started = Completer<void>();
      final finish = Completer<void>();
      final first = lock.runExclusive<void>(() async {
        started.complete();
        await finish.future;
        throw StateError('storage unavailable');
      });
      final failure = expectLater(first, throwsStateError);
      await started.future;
      var secondStarted = false;
      final second = lock.runExclusive(() async => secondStarted = true);
      await Future<void>.delayed(Duration.zero);
      expect(secondStarted, false);
      expect(calls.single.method, 'processLock.tryAcquire');

      finish.complete();
      await failure;
      await second;
      expect(secondStarted, true);
      expect(calls.map((call) => call.method), [
        'processLock.tryAcquire',
        'processLock.release',
        'processLock.tryAcquire',
        'processLock.release',
      ]);
    },
  );

  test(
    'does not run storage operations while another engine owns the lock',
    () async {
      lock = SessionTokenLock(
        client: ProcessLockClient(methodChannel: channel),
        waitTimeout: Duration.zero,
      );
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return false;
      });
      await expectLater(
        lock.runExclusive(() async => fail('Storage must stay untouched')),
        throwsA(isA<TimeoutException>()),
      );
      expect(calls.single.method, 'processLock.tryAcquire');
    },
  );
}
