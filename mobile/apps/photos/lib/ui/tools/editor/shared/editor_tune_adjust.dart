import "package:ente_components/ente_components.dart";
import 'package:flutter/material.dart';

class EditorTuneAdjustWidget extends StatelessWidget {
  final double min;
  final double max;
  final double value;
  final ValueChanged<double> onChanged;
  final double leftMargin;
  final double rightMargin;

  const EditorTuneAdjustWidget({
    super.key,
    required this.min,
    required this.max,
    required this.value,
    required this.onChanged,
    this.leftMargin = 20.0,
    this.rightMargin = 20.0,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.componentColors;
    final Widget sliderStack = SizedBox(
      height: 40,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: Container(
              margin: EdgeInsets.only(left: leftMargin, right: rightMargin),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(25),
                color: colors.fillLight,
              ),
            ),
          ),
          Container(
            margin: EdgeInsets.only(left: leftMargin, right: rightMargin),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(25)),
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                thumbShape: EditorTuneThumbShape(
                  thumbOuterColor: Colors.white,
                  thumbInnerColor: colors.primary,
                ),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 0),
                activeTrackColor: colors.primary,
                inactiveTrackColor: colors.fillLight,
                trackShape: EditorTuneTrackShape(isBipolar: min < 0),
                trackHeight: 24,
              ),
              child: Slider(
                value: value,
                onChanged: onChanged,
                min: min,
                max: max,
              ),
            ),
          ),
          Container(
            margin: EdgeInsets.only(
              left: leftMargin + 18,
              right: rightMargin + 18,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: colors.fillBase.withAlpha(30),
                  ),
                ),
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: colors.fillBase.withAlpha(30),
                  ),
                ),
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: colors.fillBase.withAlpha(30),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    return sliderStack;
  }
}

class EditorTuneThumbShape extends SliderComponentShape {
  final Color thumbOuterColor;
  final Color thumbInnerColor;

  const EditorTuneThumbShape({
    required this.thumbOuterColor,
    required this.thumbInnerColor,
  });

  static const double thumbRadius = 15.0;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) {
    return const Size(thumbRadius * 2, thumbRadius * 2);
  }

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required Size sizeWithOverflow,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double textScaleFactor,
    required double value,
  }) {
    final canvas = context.canvas;

    final trackRect = sliderTheme.trackShape!.getPreferredRect(
      parentBox: parentBox,
      offset: Offset.zero,
      sliderTheme: sliderTheme,
      isEnabled: true,
      isDiscrete: isDiscrete,
    );

    final constrainedCenter = Offset(
      center.dx.clamp(
        trackRect.left + thumbRadius,
        trackRect.right - thumbRadius,
      ),
      center.dy,
    );

    final paint = Paint()
      ..color = thumbOuterColor
      ..style = PaintingStyle.fill;

    canvas.drawCircle(constrainedCenter, thumbRadius, paint);

    final innerPaint = Paint()
      ..color = thumbInnerColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(constrainedCenter, 12.5, innerPaint);
  }
}

class EditorTuneTrackShape extends SliderTrackShape {
  const EditorTuneTrackShape({this.isBipolar = true});

  static const double horizontalPadding = 6.0;

  final bool isBipolar;

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    final double trackHeight = sliderTheme.trackHeight ?? 8;
    final double trackLeft = offset.dx + horizontalPadding;
    final double trackTop =
        offset.dy + (parentBox.size.height - trackHeight) / 2;
    final double trackWidth = parentBox.size.width - (horizontalPadding * 2);
    return Rect.fromLTWH(trackLeft, trackTop, trackWidth, trackHeight);
  }

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    double? additionalActiveTrackHeight,
  }) {
    final Canvas canvas = context.canvas;
    final Rect trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );

    final double centerX = trackRect.left + trackRect.width / 2;

    final double clampedThumbDx = thumbCenter.dx.clamp(
      trackRect.left + EditorTuneThumbShape.thumbRadius,
      trackRect.right - EditorTuneThumbShape.thumbRadius,
    );

    final double activeStartDx = isBipolar ? centerX : trackRect.left;

    final Paint inactivePaint = Paint()
      ..color = sliderTheme.inactiveTrackColor!
      ..style = PaintingStyle.fill;

    final RRect inactiveRRect = RRect.fromRectAndRadius(
      trackRect,
      Radius.circular(trackRect.height / 2),
    );

    canvas.drawRRect(inactiveRRect, inactivePaint);

    if ((clampedThumbDx - activeStartDx).abs() >
        EditorTuneThumbShape.thumbRadius) {
      final Paint activePaint = Paint()
        ..color = sliderTheme.activeTrackColor!
        ..style = PaintingStyle.fill;

      final Rect activeRect = clampedThumbDx >= activeStartDx
          ? Rect.fromLTWH(
              activeStartDx,
              trackRect.top,
              clampedThumbDx - activeStartDx,
              trackRect.height,
            )
          : Rect.fromLTWH(
              clampedThumbDx,
              trackRect.top,
              activeStartDx - clampedThumbDx,
              trackRect.height,
            );

      final RRect activeRRect = RRect.fromRectAndRadius(
        activeRect,
        Radius.circular(trackRect.height / 2),
      );

      canvas.drawRRect(activeRRect, activePaint);
    }
  }
}
