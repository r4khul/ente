import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:logging/logging.dart';
import 'package:photos/db/device_files_db.dart';
import 'package:photos/db/files_db.dart';
import 'package:photos/models/device_collection.dart';
import 'package:photos/models/file/file.dart';
import 'package:photos/service_locator.dart';
import 'package:photos/services/collections_service.dart';
import 'package:synchronized/synchronized.dart';

class DeviceFolderMoveInEnteSuggestion {
  DeviceFolderMoveInEnteSuggestion._();

  static final instance = DeviceFolderMoveInEnteSuggestion._();

  static const _preferenceKey = 'device_folder_move_in_ente_suggestion';
  static const _maximumAge = Duration(days: 7);
  static const _previewFileLimit = 4;
  static final _logger = Logger('DeviceFolderMoveInEnteSuggestion');
  final _preferenceLock = Lock();

  Future<String?> record({
    required DeviceCollection source,
    required DeviceCollection destination,
    required Iterable<String> localIDs,
  }) {
    return _preferenceLock.synchronized(() async {
      final sourceCollectionID = source.collectionID;
      final ids = localIDs.toSet().toList(growable: false);
      if (!source.shouldBackup ||
          !destination.shouldBackup ||
          sourceCollectionID == null ||
          sourceCollectionID == -1 ||
          ids.isEmpty) {
        return null;
      }
      final candidates = _readCandidates()?.candidates ?? <_StoredCandidate>[];
      _removeExpiredCandidates(candidates);
      final createdAt = DateTime.now();
      final candidateID = _nextCandidateID(candidates, createdAt);
      candidates.add(
        _StoredCandidate(
          id: candidateID,
          sourceFolderID: source.id,
          destinationFolderID: destination.id,
          sourceCollectionID: sourceCollectionID,
          localIDs: ids.toSet(),
          createdAt: createdAt,
        ),
      );
      await _writeCandidates(candidates);
      return candidateID;
    });
  }

  Future<DeviceFolderMoveInEnteCandidate?> loadForDestination(
    DeviceCollection openedDestination,
  ) => _loadForDestination(openedDestination);

  Future<DeviceFolderMoveInEnteCandidate?> _loadForDestination(
    DeviceCollection openedDestination, {
    String? candidateID,
  }) {
    return _preferenceLock.synchronized(() async {
      final hasStoredCandidates = ServiceLocator.instance.prefs.containsKey(
        _preferenceKey,
      );
      final readResult = _readCandidates();
      if (readResult == null) {
        if (hasStoredCandidates) await _writeCandidates(const []);
        return null;
      }

      final candidates = readResult.candidates;
      var candidatesChanged =
          readResult.needsRewrite || _removeExpiredCandidates(candidates);
      for (final candidate in candidates.sortedBy((value) => value.createdAt)) {
        if (candidate.destinationFolderID != openedDestination.id ||
            (candidateID != null && candidate.id != candidateID)) {
          continue;
        }
        final resolved = await _resolveCandidate(candidate);
        if (resolved != null) {
          if (candidatesChanged) await _writeCandidates(candidates);
          return resolved;
        }
        candidates.remove(candidate);
        candidatesChanged = true;
      }
      if (candidatesChanged) await _writeCandidates(candidates);
      return null;
    });
  }

  Future<DeviceFolderMoveInEnteCandidate?> _resolveCandidate(
    _StoredCandidate candidate,
  ) async {
    final folders = await FilesDB.instance.getDeviceCollections();
    final source = folders
        .where((folder) => folder.id == candidate.sourceFolderID)
        .firstOrNull;
    final destination = folders
        .where((folder) => folder.id == candidate.destinationFolderID)
        .firstOrNull;
    if (source == null ||
        destination == null ||
        !source.shouldBackup ||
        !destination.shouldBackup ||
        source.collectionID != candidate.sourceCollectionID) {
      return null;
    }

    final movedIDs = await FilesDB.instance.getLocalIDsInDeviceCollection(
      candidate.localIDs,
      destination.id,
    );
    if (movedIDs.isEmpty) {
      return null;
    }
    final uploadedIDs = await FilesDB.instance.getUploadedLocalIDs(
      movedIDs,
      collectionID: candidate.sourceCollectionID,
    );
    if (uploadedIDs.isEmpty) {
      return null;
    }
    final previewFiles = await FilesDB.instance.getUploadedFilesForLocalIDs(
      uploadedIDs.take(_previewFileLimit),
      collectionID: candidate.sourceCollectionID,
    );
    return DeviceFolderMoveInEnteCandidate(
      id: candidate.id,
      destination: destination,
      sourceCollectionID: candidate.sourceCollectionID,
      localIDs: uploadedIDs,
      previewFiles: _oneFilePerLocalID(previewFiles),
    );
  }

  Future<void> moveInEnte(DeviceFolderMoveInEnteCandidate candidate) async {
    final fresh = await _loadForDestination(
      candidate.destination,
      candidateID: candidate.id,
    );
    if (fresh == null) {
      throw StateError(
        'The device move is no longer eligible for an Ente move',
      );
    }
    final targetCollectionID = fresh.destination.hasCollectionID()
        ? fresh.destination.collectionID!
        : (await CollectionsService.instance.getOrCreateForPath(
            fresh.destination.name,
          )).id;
    if (targetCollectionID != fresh.sourceCollectionID) {
      final files = await FilesDB.instance.getUploadedFilesForLocalIDs(
        fresh.localIDs,
        collectionID: fresh.sourceCollectionID,
      );
      if (files
              .map((file) => file.localID)
              .whereType<String>()
              .toSet()
              .length !=
          fresh.localIDs.length) {
        throw StateError('The source files changed before the Ente move');
      }
      await CollectionsService.instance.move(
        files.map((file) => file.copyWith()).toList(),
        toCollectionID: targetCollectionID,
        fromCollectionID: fresh.sourceCollectionID,
      );
    }
    if (!fresh.destination.hasCollectionID()) {
      await FilesDB.instance.updateDeviceCollection(
        fresh.destination.id,
        targetCollectionID,
      );
    }
    await discard(fresh.id);
  }

  Future<void> discard(String candidateID) {
    return _preferenceLock.synchronized(() async {
      final readResult = _readCandidates();
      if (readResult == null) {
        await _writeCandidates(const []);
        return;
      }
      final candidates = readResult.candidates;
      candidates.removeWhere((candidate) => candidate.id == candidateID);
      await _writeCandidates(candidates);
    });
  }

  List<EnteFile> _oneFilePerLocalID(Iterable<EnteFile> files) {
    final seenLocalIDs = <String>{};
    return files
        .where(
          (file) => file.localID != null && seenLocalIDs.add(file.localID!),
        )
        .toList(growable: false);
  }

  _CandidateReadResult? _readCandidates() {
    final raw = ServiceLocator.instance.prefs.getString(_preferenceKey);
    if (raw == null) return _CandidateReadResult(<_StoredCandidate>[]);
    try {
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic>) return null;
      final rawCandidates = value['candidates'];
      if (rawCandidates is List) {
        final candidateIDs = <String>{};
        final candidates = <_StoredCandidate>[];
        for (final rawCandidate in rawCandidates) {
          final candidate = _StoredCandidate.fromJson(rawCandidate);
          if (candidate != null && candidateIDs.add(candidate.id)) {
            candidates.add(candidate);
          }
        }
        return _CandidateReadResult(
          candidates,
          needsRewrite: candidates.length != rawCandidates.length,
        );
      }
      final legacyCandidate = _StoredCandidate.fromJson(value);
      return legacyCandidate == null
          ? null
          : _CandidateReadResult([legacyCandidate]);
    } catch (error, stackTrace) {
      _logger.warning(
        'Discarding a malformed device-folder Ente move suggestion',
        error,
        stackTrace,
      );
      return null;
    }
  }

  Future<void> _writeCandidates(List<_StoredCandidate> candidates) async {
    if (candidates.isEmpty) {
      await ServiceLocator.instance.prefs.remove(_preferenceKey);
      return;
    }
    await ServiceLocator.instance.prefs.setString(
      _preferenceKey,
      jsonEncode({
        'candidates': candidates
            .map((candidate) => candidate.toJson())
            .toList(),
      }),
    );
  }

  bool _removeExpiredCandidates(List<_StoredCandidate> candidates) {
    final originalLength = candidates.length;
    final now = DateTime.now();
    candidates.removeWhere(
      (candidate) => now.difference(candidate.createdAt) > _maximumAge,
    );
    return candidates.length != originalLength;
  }

  String _nextCandidateID(
    Iterable<_StoredCandidate> candidates,
    DateTime createdAt,
  ) {
    final existingIDs = candidates.map((candidate) => candidate.id).toSet();
    final timestamp = createdAt.microsecondsSinceEpoch;
    var candidateID = timestamp.toString();
    var suffix = 1;
    while (existingIDs.contains(candidateID)) {
      candidateID = '$timestamp:$suffix';
      suffix++;
    }
    return candidateID;
  }
}

class DeviceFolderMoveInEnteCandidate {
  const DeviceFolderMoveInEnteCandidate({
    required this.id,
    required this.destination,
    required this.sourceCollectionID,
    required this.localIDs,
    required this.previewFiles,
  });

  final String id;
  final DeviceCollection destination;
  final int sourceCollectionID;
  final Set<String> localIDs;
  final List<EnteFile> previewFiles;
}

class _StoredCandidate {
  const _StoredCandidate({
    required this.id,
    required this.sourceFolderID,
    required this.destinationFolderID,
    required this.sourceCollectionID,
    required this.localIDs,
    required this.createdAt,
  });

  final String id;
  final String sourceFolderID;
  final String destinationFolderID;
  final int sourceCollectionID;
  final Set<String> localIDs;
  final DateTime createdAt;

  Map<String, Object> toJson() => {
    'id': id,
    'sourceFolderID': sourceFolderID,
    'destinationFolderID': destinationFolderID,
    'sourceCollectionID': sourceCollectionID,
    'localIDs': localIDs.toList(growable: false),
    'createdAt': createdAt.microsecondsSinceEpoch,
  };

  static _StoredCandidate? fromJson(dynamic value) {
    try {
      if (value is! Map<String, dynamic>) return null;
      final sourceFolderID = value['sourceFolderID'];
      final destinationFolderID = value['destinationFolderID'];
      final sourceCollectionID = value['sourceCollectionID'];
      final localIDs = value['localIDs'];
      final createdAt = value['createdAt'];
      if (sourceFolderID is! String ||
          destinationFolderID is! String ||
          sourceCollectionID is! int ||
          localIDs is! List ||
          createdAt is! int) {
        return null;
      }
      final ids = localIDs.whereType<String>().toSet();
      if (ids.isEmpty) return null;
      final id = value['id'];
      return _StoredCandidate(
        id: id is String
            ? id
            : 'legacy:$createdAt:$sourceFolderID:$destinationFolderID',
        sourceFolderID: sourceFolderID,
        destinationFolderID: destinationFolderID,
        sourceCollectionID: sourceCollectionID,
        localIDs: ids,
        createdAt: DateTime.fromMicrosecondsSinceEpoch(createdAt),
      );
    } catch (error, stackTrace) {
      DeviceFolderMoveInEnteSuggestion._logger.warning(
        'Ignoring a malformed device-folder Ente move suggestion',
        error,
        stackTrace,
      );
      return null;
    }
  }
}

class _CandidateReadResult {
  _CandidateReadResult(this.candidates, {this.needsRewrite = false});

  final List<_StoredCandidate> candidates;
  final bool needsRewrite;
}
