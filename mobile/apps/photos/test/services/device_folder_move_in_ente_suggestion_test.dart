import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:photos/models/device_collection.dart';
import 'package:photos/service_locator.dart';
import 'package:photos/services/device_folder_move_in_ente_suggestion.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    ServiceLocator.instance.init(
      prefs,
      Dio(),
      Dio(),
      Dio(),
      PackageInfo(
        appName: 'Photos',
        packageName: 'photos',
        version: '1.0.0',
        buildNumber: '1',
      ),
    );
  });

  setUp(() => prefs.clear());

  test(
    'retains an earlier candidate when a later candidate is discarded',
    () async {
      final service = DeviceFolderMoveInEnteSuggestion.instance;
      final firstID = await service.record(
        source: _folder('source-a', collectionID: 10),
        destination: _folder('destination-a'),
        localIDs: const ['1'],
      );
      final secondID = await service.record(
        source: _folder('source-b', collectionID: 20),
        destination: _folder('destination-b'),
        localIDs: const ['2'],
      );

      await service.discard(secondID!);

      expect(_candidateIDs(prefs), [firstID]);
    },
  );

  test('serializes concurrent candidate records', () async {
    final service = DeviceFolderMoveInEnteSuggestion.instance;
    final ids = await Future.wait([
      service.record(
        source: _folder('source-a', collectionID: 10),
        destination: _folder('destination-a'),
        localIDs: const ['1'],
      ),
      service.record(
        source: _folder('source-b', collectionID: 20),
        destination: _folder('destination-b'),
        localIDs: const ['2'],
      ),
    ]);

    expect(_candidateIDs(prefs).toSet(), ids.whereType<String>().toSet());
  });

  test(
    'migrates the legacy single candidate when recording another move',
    () async {
      await prefs.setString(
        _preferenceKey,
        jsonEncode({
          'sourceFolderID': 'source-a',
          'destinationFolderID': 'destination-a',
          'sourceCollectionID': 10,
          'localIDs': ['1'],
          'createdAt': DateTime.now().microsecondsSinceEpoch,
        }),
      );

      final secondID = await DeviceFolderMoveInEnteSuggestion.instance.record(
        source: _folder('source-b', collectionID: 20),
        destination: _folder('destination-b'),
        localIDs: const ['2'],
      );

      expect(_candidateIDs(prefs), hasLength(2));
      expect(_candidateIDs(prefs), contains(secondID));
    },
  );

  test(
    'preserves valid entries when rewriting malformed candidate data',
    () async {
      final validCandidate = _candidate('valid');
      await prefs.setString(
        _preferenceKey,
        jsonEncode({
          'candidates': [
            validCandidate,
            {...validCandidate},
            {'id': 7},
          ],
        }),
      );

      final newID = await DeviceFolderMoveInEnteSuggestion.instance.record(
        source: _folder('source-b', collectionID: 20),
        destination: _folder('destination-b'),
        localIDs: const ['2'],
      );

      expect(_candidateIDs(prefs).toSet(), {'valid', newID});
    },
  );

  test(
    'expires only the stale candidate when recording another move',
    () async {
      await prefs.setString(
        _preferenceKey,
        jsonEncode({
          'candidates': [
            _candidate(
              'expired',
              createdAt: DateTime.now().subtract(const Duration(days: 8)),
            ),
            _candidate('valid'),
          ],
        }),
      );

      final newID = await DeviceFolderMoveInEnteSuggestion.instance.record(
        source: _folder('source-b', collectionID: 20),
        destination: _folder('destination-b'),
        localIDs: const ['2'],
      );

      expect(_candidateIDs(prefs).toSet(), {'valid', newID});
    },
  );
}

const _preferenceKey = 'device_folder_move_in_ente_suggestion';

DeviceCollection _folder(String id, {int? collectionID}) =>
    DeviceCollection(id, id, collectionID: collectionID, shouldBackup: true);

List<String> _candidateIDs(SharedPreferences prefs) {
  final value = jsonDecode(prefs.getString(_preferenceKey)!) as Map;
  final candidates = value['candidates'] as List;
  return candidates
      .map((candidate) => (candidate as Map)['id'] as String)
      .toList();
}

Map<String, Object> _candidate(String id, {DateTime? createdAt}) => {
  'id': id,
  'sourceFolderID': 'source-$id',
  'destinationFolderID': 'destination-$id',
  'sourceCollectionID': 10,
  'localIDs': ['1'],
  'createdAt': (createdAt ?? DateTime.now()).microsecondsSinceEpoch,
};
