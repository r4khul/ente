import 'package:ente_photos_platform/ente_photos_platform.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('encodes the transfer operation', () {
    const request = DeviceFolderTransferRequest(
      operation: DeviceFolderTransferOperation.move,
      sourceFolderID: 'source',
      targetFolderID: 'target',
      sourceLocalIDs: ['one'],
      recoveryContext: {'ownerID': 7},
    );

    expect(
      request.toChannelMap()['operation'],
      DeviceFolderTransferOperation.move.name,
    );
  });

  test('copies a request while adding recovery information', () {
    const request = DeviceFolderTransferRequest(
      operation: DeviceFolderTransferOperation.move,
      sourceFolderID: 'source',
      targetFolderID: 'target',
      sourceLocalIDs: ['one'],
    );
    final recovered = request.copyWith(
      transferID: 'transfer-id',
      recoveryContext: const {'ownerID': 7},
    );

    expect(recovered.toChannelMap()['transferID'], 'transfer-id');
    expect(recovered.toChannelMap()['recoveryContext'], {'ownerID': 7});
  });

  test('passes operation while loading destinations', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('device-folder-transfer-test');
    MethodCall? receivedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          receivedCall = call;
          return ['destination'];
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final result = await DeviceFolderTransferClient(methodChannel: channel)
        .eligibleDestinationIDs(
          sourceFolderID: 'source',
          operation: DeviceFolderTransferOperation.move,
          sourceLocalIDs: ['file-1'],
          candidateFolderIDs: ['destination'],
        );

    expect(result, {'destination'});
    expect(
      receivedCall?.arguments,
      containsPair('operation', DeviceFolderTransferOperation.move.name),
    );
  });

  test('decodes the native operation capability set', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('device-folder-transfer-capabilities-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'deviceFolderTransfer.supportedOperations');
          return ['copy', 'unknown'];
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final supported = await DeviceFolderTransferClient(
      methodChannel: channel,
    ).supportedOperations();

    expect(supported, {DeviceFolderTransferOperation.copy});
  });

  test('decodes valid per-file transfer outcomes', () {
    final result = DeviceFolderTransferResult.fromChannelMap({
      'destinations': {
        'one': {'localID': 'new-one', 'displayName': 'new-name.jpg'},
      },
      'failures': {'two': 'missingSource', 'three': 'unknown'},
    });

    expect(result.successLocalIDs, {'one'});
    expect(result.destinationLocalIDs, {'one': 'new-one'});
    expect(result.destinations['one']?.displayName, 'new-name.jpg');
    expect(result.failures['two'], DeviceFolderTransferFailure.missingSource);
    expect(result.failures['three'], DeviceFolderTransferFailure.failed);
  });

  test('recognizes a fully cancelled transfer', () {
    final result = DeviceFolderTransferResult.fromChannelMap({
      'successLocalIDs': <String>[],
      'failures': {'one': 'cancelled', 'two': 'cancelled'},
    });

    expect(result.wasCancelled, isTrue);
  });

  test('decodes a legacy destination without a display name', () {
    final result = DeviceFolderTransferResult.fromChannelMap({
      'destinationLocalIDs': {'one': 'new-one'},
      'failures': <String, String>{},
    });

    expect(result.destinationLocalIDs, {'one': 'new-one'});
    expect(result.destinations['one']?.displayName, isNull);
  });

  test('retains an unresolved move journal', () {
    final result = DeviceFolderTransferResult.fromChannelMap({
      'destinations': <String, Map<String, String>>{},
      'failures': {'one': 'failed'},
      'requiresRecovery': true,
    });

    expect(result.requiresRecovery, isTrue);
  });

  test('decodes a native transfer recovery record', () {
    final recovery = DeviceFolderTransferRecovery.fromChannelMap({
      'transferID': 'transfer-id',
      'operation': 'copy',
      'sourceFolderID': 'source',
      'targetFolderID': 'target',
      'ownerID': 7,
      'cloudMoveStarted': true,
      'cloudMoveCompleted': false,
      'cloudMoveSourceCollectionID': 9,
      'destinations': {
        'one': {'localID': 'new-one', 'displayName': 'new-name.jpg'},
      },
      'failures': <String, String>{},
    });

    expect(recovery.transferID, 'transfer-id');
    expect(recovery.operation, DeviceFolderTransferOperation.copy);
    expect(recovery.ownerID, 7);
    expect(recovery.cloudMoveStarted, isTrue);
    expect(recovery.cloudMoveSourceCollectionID, 9);
    expect(recovery.hasCloudMove, isTrue);
    expect(recovery.result.destinationLocalIDs, {'one': 'new-one'});
  });
}
