import 'dart:io';

import 'package:flutter/services.dart';

enum DeviceFolderTransferOperation { copy, move }

enum DeviceFolderTransferIdentityPolicy {
  preserveSourceLocalID,
  allowReplacementLocalID,
}

enum DeviceFolderTransferFailure {
  cancelled,
  missingSource,
  ineligibleDestination,
  unsupported,
  permissionDenied,
  failed,
}

class DeviceFolderTransferRequest {
  const DeviceFolderTransferRequest({
    required this.operation,
    required this.sourceFolderID,
    required this.identityPolicy,
    required this.targetFolderID,
    required this.sourceLocalIDs,
    this.transferID,
    this.recoveryContext,
  });

  final DeviceFolderTransferOperation operation;
  final String sourceFolderID;
  final DeviceFolderTransferIdentityPolicy identityPolicy;
  final String targetFolderID;
  final List<String> sourceLocalIDs;
  final String? transferID;
  final Map<String, Object>? recoveryContext;

  Map<String, Object> toChannelMap() => {
    'operation': operation.name,
    'sourceFolderID': sourceFolderID,
    'identityPolicy': identityPolicy.name,
    'targetFolderID': targetFolderID,
    'sourceLocalIDs': sourceLocalIDs,
    'transferID': ?transferID,
    'recoveryContext': ?recoveryContext,
  };
}

class DeviceFolderTransferResult {
  const DeviceFolderTransferResult({
    required this.successLocalIDs,
    required this.destinationLocalIDs,
    required this.failures,
  });

  final Set<String> successLocalIDs;
  final Map<String, String> destinationLocalIDs;
  final Map<String, DeviceFolderTransferFailure> failures;

  bool get wasCancelled =>
      failures.isNotEmpty &&
      failures.values.every(
        (failure) => failure == DeviceFolderTransferFailure.cancelled,
      );

  factory DeviceFolderTransferResult.fromChannelMap(Map<dynamic, dynamic> map) {
    final successes = (map['successLocalIDs'] as List<dynamic>? ?? const [])
        .whereType<String>()
        .toSet();
    final rawDestinationIDs =
        map['destinationLocalIDs'] as Map<dynamic, dynamic>? ?? const {};
    final destinationLocalIDs = <String, String>{};
    rawDestinationIDs.forEach((sourceID, destinationID) {
      if (sourceID is String && destinationID is String) {
        destinationLocalIDs[sourceID] = destinationID;
      }
    });
    final rawFailures = map['failures'] as Map<dynamic, dynamic>? ?? const {};
    final failures = <String, DeviceFolderTransferFailure>{};
    rawFailures.forEach((key, value) {
      if (key is String && value is String) {
        failures[key] = DeviceFolderTransferFailure.values.firstWhere(
          (failure) => failure.name == value,
          orElse: () => DeviceFolderTransferFailure.failed,
        );
      }
    });
    return DeviceFolderTransferResult(
      successLocalIDs: successes,
      destinationLocalIDs: destinationLocalIDs,
      failures: failures,
    );
  }
}

class DeviceFolderTransferRecovery {
  const DeviceFolderTransferRecovery({
    required this.transferID,
    required this.result,
    required this.sourceFolderID,
    required this.targetFolderID,
    required this.moveInEnte,
    required this.sourceLocalIDs,
    required this.ownerID,
    required this.cloudMoveCompleted,
  });

  final String transferID;
  final DeviceFolderTransferResult result;
  final String sourceFolderID;
  final String targetFolderID;
  final bool moveInEnte;
  final Set<String> sourceLocalIDs;
  final int ownerID;
  final bool cloudMoveCompleted;

  factory DeviceFolderTransferRecovery.fromChannelMap(
    Map<dynamic, dynamic> map,
  ) {
    return DeviceFolderTransferRecovery(
      transferID: map['transferID'] as String,
      result: DeviceFolderTransferResult.fromChannelMap(map),
      sourceFolderID: map['sourceFolderID'] as String,
      targetFolderID: map['targetFolderID'] as String,
      moveInEnte: map['moveInEnte'] == true,
      sourceLocalIDs: (map['sourceLocalIDs'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toSet(),
      ownerID: map['ownerID'] as int,
      cloudMoveCompleted: map['cloudMoveCompleted'] == true,
    );
  }
}

class DeviceFolderTransferClient {
  DeviceFolderTransferClient({MethodChannel? methodChannel})
    : _methodChannel = methodChannel ?? const MethodChannel(_channelName);

  static const _channelName = 'io.ente.photos.platform';

  static bool get isSupportedOnCurrentPlatform => Platform.isAndroid;

  final MethodChannel _methodChannel;

  Future<Set<DeviceFolderTransferOperation>> supportedOperations() async {
    final result = await _methodChannel.invokeMethod<List<dynamic>>(
      'deviceFolderTransfer.supportedOperations',
    );
    final names = (result ?? const []).whereType<String>().toSet();
    return DeviceFolderTransferOperation.values
        .where((operation) => names.contains(operation.name))
        .toSet();
  }

  Future<Set<String>> eligibleDestinationIDs({
    required String sourceFolderID,
    required DeviceFolderTransferOperation operation,
    required DeviceFolderTransferIdentityPolicy identityPolicy,
    required List<String> sourceLocalIDs,
    required List<String> candidateFolderIDs,
  }) async {
    final result = await _methodChannel.invokeMethod<List<dynamic>>(
      'deviceFolderTransfer.eligibleDestinations',
      {
        'sourceFolderID': sourceFolderID,
        'operation': operation.name,
        'identityPolicy': identityPolicy.name,
        'sourceLocalIDs': sourceLocalIDs,
        'candidateFolderIDs': candidateFolderIDs,
      },
    );
    return (result ?? const []).whereType<String>().toSet();
  }

  Future<DeviceFolderTransferResult> transfer(
    DeviceFolderTransferRequest request,
  ) async {
    final result = await _methodChannel.invokeMethod<Map<dynamic, dynamic>>(
      'deviceFolderTransfer.transfer',
      request.toChannelMap(),
    );
    if (result == null) {
      throw PlatformException(
        code: 'device_folder_transfer_invalid_result',
        message: 'Native transfer returned no result',
      );
    }
    return DeviceFolderTransferResult.fromChannelMap(result);
  }

  Future<List<DeviceFolderTransferRecovery>> pendingRecoveries() async {
    final recoveries = await _methodChannel.invokeMethod<List<dynamic>>(
      'deviceFolderTransfer.pendingRecoveries',
    );
    return (recoveries ?? const [])
        .whereType<Map<dynamic, dynamic>>()
        .map(DeviceFolderTransferRecovery.fromChannelMap)
        .toList(growable: false);
  }

  Future<void> markCloudMoveCompleted(String transferID) {
    return _methodChannel.invokeMethod<void>(
      'deviceFolderTransfer.markCloudMoveCompleted',
      {'transferID': transferID},
    );
  }

  Future<void> acknowledgeRecovery(String transferID) {
    return _methodChannel.invokeMethod<void>(
      'deviceFolderTransfer.acknowledgeRecovery',
      {'transferID': transferID},
    );
  }
}
