import 'dart:math';

import 'package:collection/collection.dart';
import 'package:ente_components/ente_components.dart';
import 'package:ente_strings/ente_strings.dart';
import 'package:ente_ui/components/loading_widget.dart';
import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';
import 'package:photos/models/device_collection.dart';
import 'package:photos/ui/collections/device/device_folder_list_item.dart';

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

enum BackedUpDeviceFolderMoveChoice { deviceOnly, moveInEnte }

Future<BackedUpDeviceFolderMoveChoice?> showBackedUpDeviceFolderMoveSheet(
  BuildContext context,
) {
  return showBottomSheetComponent<BackedUpDeviceFolderMoveChoice>(
    context: context,
    builder: (sheetContext) => BottomSheetComponent(
      title: sheetContext.strings.moveBackedUpFilesQuestion,
      message: sheetContext.strings.moveBackedUpFilesDescription,
      illustration: Image.asset("assets/warning-grey.png"),
      closeTooltip: sheetContext.strings.close,
      actions: [
        ButtonComponent(
          label: sheetContext.strings.moveInEnte,
          shouldSurfaceExecutionStates: false,
          onTap: () => Navigator.of(
            sheetContext,
          ).pop(BackedUpDeviceFolderMoveChoice.moveInEnte),
        ),
        ButtonComponent(
          label: sheetContext.strings.moveOnDeviceOnly,
          shouldSurfaceExecutionStates: false,
          onTap: () => Navigator.of(
            sheetContext,
          ).pop(BackedUpDeviceFolderMoveChoice.deviceOnly),
        ),
      ],
    ),
  );
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
