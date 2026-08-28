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
  });

  final DeviceFolderTransferOperation operation;
  final String sourceFolderID;
  final String targetFolderID;
  final List<String> sourceLocalIDs;
  Map<String, Object> toChannelMap() => {
    'operation': operation.name,
    'sourceFolderID': sourceFolderID,
    'targetFolderID': targetFolderID,
    'sourceLocalIDs': sourceLocalIDs,
  };
}

class DeviceFolderTransferResult {
  const DeviceFolderTransferResult({
    required this.destinations,
    required this.failures,
    this.cloudMoveFailed = false,
    this.localReconciliationFailed = false,
  });

  final Map<String, DeviceFolderTransferDestination> destinations;
  final Map<String, DeviceFolderTransferFailure> failures;
  final bool cloudMoveFailed;
  final bool localReconciliationFailed;

  Set<String> get successLocalIDs => destinations.keys.toSet();

  Map<String, String> get destinationLocalIDs => {
    for (final entry in destinations.entries) entry.key: entry.value.localID,
  };

  DeviceFolderTransferResult copyWith({
    bool? cloudMoveFailed,
    bool? localReconciliationFailed,
  }) => DeviceFolderTransferResult(
    destinations: destinations,
    failures: failures,
    cloudMoveFailed: cloudMoveFailed ?? this.cloudMoveFailed,
    localReconciliationFailed:
        localReconciliationFailed ?? this.localReconciliationFailed,
  );

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
}
