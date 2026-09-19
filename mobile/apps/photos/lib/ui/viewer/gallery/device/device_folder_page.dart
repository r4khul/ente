import "package:ente_pure_utils/ente_pure_utils.dart";
import "package:ente_strings/ente_strings.dart";
import "package:flutter/material.dart";
import "package:logging/logging.dart";
import "package:photos/core/configuration.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/db/device_files_db.dart";
import "package:photos/db/files_db.dart";
import "package:photos/events/files_updated_event.dart";
import "package:photos/events/local_photos_updated_event.dart";
import "package:photos/models/device_collection.dart";
import "package:photos/models/file/file.dart";
import "package:photos/models/file_load_result.dart";
import "package:photos/models/gallery_type.dart";
import "package:photos/models/selected_files.dart";
import "package:photos/service_locator.dart";
import "package:photos/services/device_folder_move_in_ente_suggestion.dart";
import "package:photos/services/sync/remote_sync_service.dart";
import "package:photos/ui/collections/device/device_folder_action_sheet.dart";
import "package:photos/ui/notification/toast.dart";
import "package:photos/ui/viewer/actions/file_selection_overlay_bar.dart";
import "package:photos/ui/viewer/gallery/device/backup_header_widget.dart";
import "package:photos/ui/viewer/gallery/device/skipped_device_folder_page.dart";
import "package:photos/ui/viewer/gallery/gallery.dart";
import "package:photos/ui/viewer/gallery/gallery_app_bar_widget.dart";
import "package:photos/ui/viewer/gallery/state/gallery_boundaries_provider.dart";
import "package:photos/ui/viewer/gallery/state/gallery_files_inherited_widget.dart";
import "package:photos/ui/viewer/gallery/state/selection_state.dart";
import "package:photos/utils/dialog_util.dart";

class DeviceFolderPage extends StatefulWidget {
  final DeviceCollection deviceCollection;

  const DeviceFolderPage(this.deviceCollection, {super.key});

  @override
  State<DeviceFolderPage> createState() => _DeviceFolderPageState();
}

class _DeviceFolderPageState extends State<DeviceFolderPage> {
  final _logger = Logger("_DeviceFolderPageState");
  final _selectedFiles = SelectedFiles();
  late bool _shouldBackup;

  @override
  void initState() {
    super.initState();
    _shouldBackup = widget.deviceCollection.shouldBackup;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _offerMoveInEnteSuggestion();
    });
  }

  Future<void> _offerMoveInEnteSuggestion() async {
    try {
      final candidate = await DeviceFolderMoveInEnteSuggestion.instance
          .loadForDestination(widget.deviceCollection);
      if (candidate == null || !mounted) return;
      final moveInEnte = await showMoveInEnteSuggestionSheet(
        context,
        previewFiles: candidate.previewFiles,
        itemCount: candidate.localIDs.length,
      );
      if (!mounted) return;
      if (moveInEnte == null) return;
      if (!moveInEnte) {
        await DeviceFolderMoveInEnteSuggestion.instance.discard(candidate.id);
        return;
      }
      final dialog = createProgressDialog(
        context,
        context.strings.movingItemsTo(
          count: candidate.localIDs.length,
          albumName: candidate.destination.name,
        ),
      );
      await dialog.show();
      try {
        await DeviceFolderMoveInEnteSuggestion.instance.moveInEnte(candidate);
        if (mounted) {
          showShortToast(
            context,
            context.strings.movedItemsTo(
              count: candidate.localIDs.length,
              albumName: candidate.destination.name,
            ),
          );
        }
      } catch (error, stackTrace) {
        _logger.warning(
          'Could not move device-folder files in Ente',
          error,
          stackTrace,
        );
        if (mounted) {
          showShortToast(
            context,
            context.strings.somethingWentWrongPleaseTryAgain,
          );
        }
      } finally {
        await dialog.hide();
      }
    } catch (error, stackTrace) {
      _logger.warning(
        'Could not load a device-folder Ente move suggestion',
        error,
        stackTrace,
      );
    }
  }

  Future<FileLoadResult> _loadFiles(
    int creationStartTime,
    int creationEndTime, {
    int? limit,
    bool? asc,
  }) async {
    final int? userID = Configuration.instance.getUserID();
    return FilesDB.instance.getFilesInDeviceCollection(
      widget.deviceCollection,
      userID,
      creationStartTime,
      creationEndTime,
      limit: limit,
      asc: asc,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.strings;
    final appBar = GalleryAppBarWidget.sliverConfig(
      GalleryType.localFolder,
      widget.deviceCollection.name,
      _selectedFiles,
      subtitle: _shouldBackup ? l10n.backedUpAutomatically : l10n.notBackedUp,
      deviceCollection: widget.deviceCollection,
      isDeviceFolderBackedUp: _shouldBackup,
      onDisableDeviceFolderBackup: () async {
        await _updateBackupStatus(false);
      },
    );
    final gallery = Gallery(
      key: ValueKey("device_folder:${widget.deviceCollection.id}"),
      appBar: appBar,
      asyncLoader: _loadFiles,
      reloadEvent: Bus.instance.on<LocalPhotosUpdatedEvent>(),
      removalEventTypes: const {
        EventType.deletedFromDevice,
        EventType.deletedFromEverywhere,
        EventType.hide,
      },
      tagPrefix: "device_folder:${widget.deviceCollection.name}",
      galleryType: GalleryType.localFolder,
      selectedFiles: _selectedFiles,
      header: Configuration.instance.hasConfiguredAccount()
          ? BackupHeaderWidget(
              widget.deviceCollection,
              shouldBackup: _shouldBackup,
              onBackupChanged: _updateBackupStatus,
              onOpenSkippedFiles: _openSkippedFiles,
            )
          : const SizedBox.shrink(),
      initialFiles: _initialFiles,
    );
    return GalleryBoundariesProvider(
      child: GalleryFilesState(
        child: Scaffold(
          body: SelectionState(
            selectedFiles: _selectedFiles,
            child: Stack(
              alignment: Alignment.bottomCenter,
              children: [
                gallery,
                FileSelectionOverlayBar(
                  GalleryType.localFolder,
                  _selectedFiles,
                  deviceCollection: widget.deviceCollection.copyWith(
                    shouldBackup: _shouldBackup,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<EnteFile>? get _initialFiles {
    final thumbnail = widget.deviceCollection.thumbnail;
    return thumbnail != null ? [thumbnail] : null;
  }

  Future<bool> _updateBackupStatus(bool shouldBackup) async {
    if (_shouldBackup == shouldBackup) {
      return true;
    }
    _logger.info("Toggling device folder sync status to $shouldBackup");
    try {
      await RemoteSyncService.instance.updateDeviceFolderSyncStatus({
        widget.deviceCollection.id: shouldBackup,
      });
      await backupPreferenceService.setHasManualFolderSelection(true);
      if (!mounted) {
        return true;
      }
      setState(() {
        _shouldBackup = shouldBackup;
      });
      return true;
    } catch (e, s) {
      _logger.severe("Could not update device folder sync status", e, s);
      return false;
    }
  }

  Future<void> _openSkippedFiles() async {
    await routeToPage(
      context,
      SkippedDeviceFolderPage(widget.deviceCollection),
    );
  }
}
