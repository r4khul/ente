import 'dart:math';

import 'package:collection/collection.dart';
import 'package:ente_components/ente_components.dart';
import 'package:ente_strings/ente_strings.dart';
import 'package:ente_ui/components/loading_widget.dart';
import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';
import 'package:photos/models/device_collection.dart';
import 'package:photos/models/file/file.dart';
import 'package:photos/ui/collections/device/device_folder_list_item.dart';
import 'package:photos/ui/components/thumbnail_list_item.dart';
import 'package:photos/ui/viewer/file/thumbnail_widget.dart';

Future<DeviceCollection?> showDeviceFolderActionSheet(
  BuildContext context, {
  required Future<List<DeviceCollection>> destinations,
  required String title,
}) {
  final topPadding = MediaQuery.paddingOf(context).top;
  final bottomPadding = MediaQuery.paddingOf(context).bottom;
  final screenHeight = MediaQuery.sizeOf(context).height;
  const sheetHeaderHeight = 76.0;
  final sheetTopGap = screenHeight * 0.20;
  final height = max(
    0.0,
    screenHeight - topPadding - bottomPadding - sheetTopGap - sheetHeaderHeight,
  );

  return showBottomSheetComponent<DeviceCollection>(
    context: context,
    builder: (_) => BottomSheetComponent(
      title: title,
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      content: SizedBox(
        height: height,
        child: DeviceFolderActionSheet(destinations: destinations),
      ),
    ),
  );
}

Future<bool> showBackedUpDeviceFolderCopyWarningSheet(
  BuildContext context, {
  required int backedUpFileCount,
}) async {
  final confirmed = await showBottomSheetComponent<bool>(
    context: context,
    builder: (sheetContext) => BottomSheetComponent(
      title: sheetContext.strings.createDuplicateBackupsQuestion,
      message: sheetContext.strings.copyAlreadyBackedUpFilesWarning(
        count: backedUpFileCount,
      ),
      illustration: Image.asset("assets/warning-grey.png"),
      closeTooltip: sheetContext.strings.close,
      closeResult: false,
      actions: [
        ButtonComponent(
          label: sheetContext.strings.copyAnyway,
          shouldSurfaceExecutionStates: false,
          onTap: () => Navigator.of(sheetContext).pop(true),
        ),
      ],
    ),
  );

  return confirmed == true;
}

Future<bool?> showMoveInEnteSuggestionSheet(
  BuildContext context, {
  required List<EnteFile> previewFiles,
  required int itemCount,
}) async {
  final moveInEnte = await showBottomSheetComponent<bool>(
    context: context,
    builder: (sheetContext) => BottomSheetComponent(
      title: sheetContext.strings.moveBackedUpFilesQuestion,
      illustration: Image.asset("assets/warning-grey.png"),
      closeTooltip: sheetContext.strings.close,
      content: _MoveInEntePreview(
        files: previewFiles,
        itemCount: itemCount,
        description: sheetContext.strings.moveBackedUpFilesDescription,
      ),
      actions: [
        ButtonComponent(
          label: sheetContext.strings.moveInEnte,
          shouldSurfaceExecutionStates: false,
          onTap: () => Navigator.of(sheetContext).pop(true),
        ),
        ButtonComponent(
          label: sheetContext.strings.moveOnDeviceOnly,
          shouldSurfaceExecutionStates: false,
          onTap: () => Navigator.of(sheetContext).pop(false),
        ),
      ],
    ),
  );
  return moveInEnte;
}

class _MoveInEntePreview extends StatelessWidget {
  const _MoveInEntePreview({
    required this.files,
    required this.itemCount,
    required this.description,
  });

  static const _thumbnailExtent = ThumbnailListItem.defaultLeadingSize;
  static const _maximumThumbnailCount = 4;

  final List<EnteFile> files;
  final int itemCount;
  final String description;

  @override
  Widget build(BuildContext context) {
    final colors = context.componentColors;
    final requestedPreviewCount = itemCount > _maximumThumbnailCount
        ? _maximumThumbnailCount - 1
        : itemCount;
    final previewFiles = files.take(requestedPreviewCount).toList();
    final remainingCount = itemCount - previewFiles.length;
    return Column(
      children: [
        SizedBox(
          height: _thumbnailExtent,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var index = 0; index < previewFiles.length; index++) ...[
                if (index > 0) const SizedBox(width: Spacing.xs),
                _MoveInEnteThumbnail(file: previewFiles[index]),
              ],
              if (remainingCount > 0) ...[
                if (previewFiles.isNotEmpty) const SizedBox(width: Spacing.xs),
                _MoveInEnteRemainingThumbnail(remainingCount: remainingCount),
              ],
            ],
          ),
        ),
        const SizedBox(height: Spacing.lg),
        Text(
          description,
          textAlign: TextAlign.center,
          style: TextStyles.body.copyWith(color: colors.textLight),
        ),
      ],
    );
  }
}

class _MoveInEnteThumbnail extends StatelessWidget {
  const _MoveInEnteThumbnail({required this.file});

  final EnteFile file;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(
        ThumbnailListItem.defaultLeadingRadius,
      ),
      child: SizedBox(
        width: _MoveInEntePreview._thumbnailExtent,
        height: _MoveInEntePreview._thumbnailExtent,
        child: ThumbnailWidget(
          file,
          shouldShowSyncStatus: false,
          shouldShowFavoriteIcon: false,
          shouldShowVideoDuration: false,
        ),
      ),
    );
  }
}

class _MoveInEnteRemainingThumbnail extends StatelessWidget {
  const _MoveInEnteRemainingThumbnail({required this.remainingCount});

  final int remainingCount;

  @override
  Widget build(BuildContext context) {
    final colors = context.componentColors;
    return Container(
      alignment: Alignment.center,
      width: _MoveInEntePreview._thumbnailExtent,
      height: _MoveInEntePreview._thumbnailExtent,
      decoration: BoxDecoration(
        color: colors.fillDark,
        borderRadius: BorderRadius.circular(
          ThumbnailListItem.defaultLeadingRadius,
        ),
      ),
      child: Text(
        '+$remainingCount',
        style: TextStyles.large.copyWith(color: colors.textBase),
      ),
    );
  }
}

class DeviceFolderActionSheet extends StatefulWidget {
  const DeviceFolderActionSheet({required this.destinations, super.key});

  final Future<List<DeviceCollection>> destinations;

  @override
  State<DeviceFolderActionSheet> createState() =>
      _DeviceFolderActionSheetState();
}

class _DeviceFolderActionSheetState extends State<DeviceFolderActionSheet> {
  String _searchQuery = '';

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextInputComponent(
          hintText: context.strings.searchByAlbumNameHint,
          prefix: HugeIcon(
            icon: HugeIcons.strokeRoundedSearch01,
            size: 18,
            color: context.componentColors.textLight,
          ),
          onChanged: (value) => setState(() => _searchQuery = value.trim()),
          isClearable: true,
          shouldUnfocusOnClearOrSubmit: true,
        ),
        const SizedBox(height: 24),
        Expanded(
          child: FutureBuilder<List<DeviceCollection>>(
            future: widget.destinations,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(
                  child: Text(
                    context.strings.somethingWentWrong,
                    style: TextStyles.body.copyWith(
                      color: context.componentColors.textLight,
                    ),
                  ),
                );
              }
              if (!snapshot.hasData) {
                return const Center(child: EnteLoadingWidget());
              }
              final folders = snapshot.data!
                  .where(
                    (folder) => folder.name.toLowerCase().contains(
                      _searchQuery.toLowerCase(),
                    ),
                  )
                  .sortedByCompare(
                    (folder) => folder.name,
                    compareAsciiLowerCaseNatural,
                  );
              if (folders.isEmpty) {
                return Center(
                  child: Text(
                    context.strings.noResultsFound,
                    style: TextStyles.body.copyWith(
                      color: context.componentColors.textLight,
                    ),
                  ),
                );
              }
              return ListView.separated(
                itemCount: folders.length,
                itemBuilder: (context, index) {
                  final folder = folders[index];
                  return DeviceFolderListItem(
                    folder,
                    onTap: () => Navigator.of(context).pop(folder),
                  );
                },
                separatorBuilder: (_, _) => const SizedBox(height: 8),
              );
            },
          ),
        ),
      ],
    );
  }
}
