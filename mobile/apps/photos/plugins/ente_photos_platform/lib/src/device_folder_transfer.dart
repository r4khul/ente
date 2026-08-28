import 'dart:io';

import 'package:flutter/services.dart';

enum DeviceFolderTransferOperation { copy, move }

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
    required this.targetFolderID,
    required this.sourceLocalIDs,
    this.transferID,
    this.recoveryContext,
  });

  final DeviceFolderTransferOperation operation;
  final String sourceFolderID;
  final String targetFolderID;
  final List<String> sourceLocalIDs;
  final String? transferID;
  final Map<String, Object>? recoveryContext;

  DeviceFolderTransferRequest copyWith({
    String? transferID,
    Map<String, Object>? recoveryContext,
  }) => DeviceFolderTransferRequest(
    operation: operation,
    sourceFolderID: sourceFolderID,
    targetFolderID: targetFolderID,
    sourceLocalIDs: sourceLocalIDs,
    transferID: transferID ?? this.transferID,
    recoveryContext: recoveryContext ?? this.recoveryContext,
  );

  Map<String, Object> toChannelMap() => {
    'operation': operation.name,
    'sourceFolderID': sourceFolderID,
    'targetFolderID': targetFolderID,
    'sourceLocalIDs': sourceLocalIDs,
    'transferID': ?transferID,
    'recoveryContext': ?recoveryContext,
  };
}

class DeviceFolderTransferResult {
  const DeviceFolderTransferResult({
    required this.destinations,
    required this.failures,
    this.requiresRecovery = false,
  });

  final Map<String, DeviceFolderTransferDestination> destinations;
  final Map<String, DeviceFolderTransferFailure> failures;
  final bool requiresRecovery;

  Set<String> get successLocalIDs => destinations.keys.toSet();

  Map<String, String> get destinationLocalIDs => {
    for (final entry in destinations.entries) entry.key: entry.value.localID,
  };

  bool get wasCancelled =>
      failures.isNotEmpty &&
      failures.values.every(
        (failure) => failure == DeviceFolderTransferFailure.cancelled,
      );

  factory DeviceFolderTransferResult.fromChannelMap(Map<dynamic, dynamic> map) {
    final destinations = <String, DeviceFolderTransferDestination>{};
    final rawDestinations =
        map['destinations'] as Map<dynamic, dynamic>? ?? const {};
    rawDestinations.forEach((sourceID, value) {
      if (sourceID is String && value is Map<dynamic, dynamic>) {
        final destination = DeviceFolderTransferDestination.fromChannelMap(
          value,
        );
        if (destination != null) {
          destinations[sourceID] = destination;
        }
      }
    });
    final legacyDestinationIDs =
        map['destinationLocalIDs'] as Map<dynamic, dynamic>? ?? const {};
    legacyDestinationIDs.forEach((sourceID, destinationID) {
      if (sourceID is String &&
          destinationID is String &&
          !destinations.containsKey(sourceID)) {
        destinations[sourceID] = DeviceFolderTransferDestination(
          localID: destinationID,
          displayName: null,
        );
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
      destinations: destinations,
      failures: failures,
      requiresRecovery: map['requiresRecovery'] == true,
    );
  }
}

class DeviceFolderTransferDestination {
  const DeviceFolderTransferDestination({
    required this.localID,
    required this.displayName,
  });

  final String localID;
  final String? displayName;

  static DeviceFolderTransferDestination? fromChannelMap(
    Map<dynamic, dynamic> map,
  ) {
    final localID = map['localID'];
    final displayName = map['displayName'];
    if (localID is! String || (displayName != null && displayName is! String)) {
      return null;
    }
    return DeviceFolderTransferDestination(
      localID: localID,
      displayName: displayName,
    );
  }
}

class DeviceFolderTransferRecovery {
  const DeviceFolderTransferRecovery({
    required this.transferID,
    required this.operation,
    required this.result,
    required this.sourceFolderID,
    required this.targetFolderID,
    required this.ownerID,
    required this.cloudMoveStarted,
    required this.cloudMoveCompleted,
    this.cloudMoveSourceCollectionID,
  });

  final String transferID;
  final DeviceFolderTransferOperation operation;
  final DeviceFolderTransferResult result;
  final String sourceFolderID;
  final String targetFolderID;
  final int ownerID;
  final bool cloudMoveStarted;
  final bool cloudMoveCompleted;
  final int? cloudMoveSourceCollectionID;

  bool get hasCloudMove =>
      cloudMoveSourceCollectionID != null && cloudMoveSourceCollectionID != -1;

  factory DeviceFolderTransferRecovery.fromChannelMap(
    Map<dynamic, dynamic> map,
  ) {
    return DeviceFolderTransferRecovery(
      transferID: map['transferID'] as String,
      operation: DeviceFolderTransferOperation.values.firstWhere(
        (operation) => operation.name == (map['operation'] ?? 'move'),
        orElse: () => DeviceFolderTransferOperation.move,
      ),
      result: DeviceFolderTransferResult.fromChannelMap(map),
      sourceFolderID: map['sourceFolderID'] as String,
      targetFolderID: map['targetFolderID'] as String,
      ownerID: map['ownerID'] as int,
      cloudMoveStarted: map['cloudMoveStarted'] == true,
      cloudMoveCompleted: map['cloudMoveCompleted'] == true,
      cloudMoveSourceCollectionID: (map['cloudMoveSourceCollectionID'] as num?)
          ?.toInt(),
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
    required List<String> sourceLocalIDs,
    required List<String> candidateFolderIDs,
  }) async {
    final result = await _methodChannel.invokeMethod<List<dynamic>>(
      'deviceFolderTransfer.eligibleDestinations',
      {
        'sourceFolderID': sourceFolderID,
        'operation': operation.name,
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

  Future<void> markCloudMoveStarted(String transferID) {
    return _methodChannel.invokeMethod<void>(
      'deviceFolderTransfer.markCloudMoveStarted',
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
