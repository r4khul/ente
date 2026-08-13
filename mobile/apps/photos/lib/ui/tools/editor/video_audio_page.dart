import "package:ente_components/ente_components.dart";
import 'package:flutter/material.dart';
import "package:hugeicons/hugeicons.dart";
import "package:photos/ui/tools/editor/shared/editor_tune_adjust.dart";
import "package:photos/ui/tools/editor/video_editor/video_editor_controller.dart";
import "package:photos/ui/tools/editor/video_editor/video_editor_widgets.dart";

class VideoAudioPage extends StatefulWidget {
  const VideoAudioPage({super.key, required this.controller});

  final VideoEditorController controller;

  @override
  State<VideoAudioPage> createState() => _VideoAudioPageState();
}

class _VideoAudioPageState extends State<VideoAudioPage> {
  double? _preMuteVolume;

  @override
  Widget build(BuildContext context) {
    return VideoEditorSubPage(
      controller: widget.controller,
      preview: VideoEditorPreview(controller: widget.controller),
      actions: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: widget.controller,
              builder: (context, _) {
                final isMuted = widget.controller.volume == 0.0;
                final volumeText = (widget.controller.volume * 100)
                    .round()
                    .toString();

                return Row(
                  children: [
                    Expanded(
                      child: EditorTuneAdjustWidget(
                        min: 0.0,
                        max: 1.0,
                        value: widget.controller.volume,
                        onChanged: widget.controller.updateVolume,
                        leftMargin: 8,
                        rightMargin: 16,
                      ),
                    ),
                    IconButton(
                      icon: HugeIcon(
                        icon: isMuted
                            ? HugeIcons.strokeRoundedVolumeOff
                            : HugeIcons.strokeRoundedVolumeHigh,
                        color: context.componentColors.iconColor,
                        size: 24,
                      ),
                      onPressed: () {
                        if (isMuted) {
                          widget.controller.updateVolume(_preMuteVolume ?? 1.0);
                          _preMuteVolume = null;
                        } else {
                          _preMuteVolume = widget.controller.volume;
                          widget.controller.updateVolume(0.0);
                        }
                      },
                    ),
                    SizedBox(
                      width: 36,
                      child: Text(
                        volumeText,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: context.componentColors.textBase,
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
