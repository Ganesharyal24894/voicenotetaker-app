import 'package:flutter/material.dart';

import '../theme.dart';
import 'app_icons.dart';
import 'common.dart';

/// The disabled transport's opacity - the same value [PrimaryButton] uses, so
/// "you cannot press this" looks the same everywhere in the app.
const double transportDisabledOpacity = 0.45;

/// A skip control: a circular arrow over its `15s` / `30s` label.
class SkipButton extends StatelessWidget {
  const SkipButton({
    required this.glyph,
    required this.label,
    required this.semanticLabel,
    required this.onTap,
    this.glyphSize = 24,
    super.key,
  });

  final AppGlyph glyph;
  final String label;
  final String semanticLabel;
  final double glyphSize;

  /// Null disables the control.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return TapTarget(
      onTap: onTap,
      semanticLabel: semanticLabel,
      minSize: 48,
      child: Opacity(
        opacity: onTap == null ? transportDisabledOpacity : 1,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AppIcon(
              glyph,
              size: glyphSize,
              color: AppColors.textSecondary,
              strokeWidth: 1.6,
            ),
            const SizedBox(height: 3),
            Text(label, style: AppText.micro10),
          ],
        ),
      ),
    );
  }
}

/// The purple play/pause disc. The glyph on it is LIGHT - the contrast rule.
class PlayPauseButton extends StatelessWidget {
  const PlayPauseButton({
    required this.playing,
    required this.onTap,
    this.size = 64,
    super.key,
  });

  final bool playing;
  final double size;

  /// Null disables the button.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    // Everything on the disc scales with it: 64px carries 5x21 bars.
    final scale = size / 64;
    return Semantics(
      button: true,
      enabled: enabled,
      label: playing ? 'Pause' : 'Play',
      container: true,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Opacity(
          opacity: enabled ? 1 : transportDisabledOpacity,
          child: Container(
            width: size,
            height: size,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.primaryFill,
            ),
            alignment: Alignment.center,
            child: playing
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      for (var i = 0; i < 2; i++) ...<Widget>[
                        if (i > 0) SizedBox(width: 6 * scale),
                        Container(
                          width: 5 * scale,
                          height: 21 * scale,
                          decoration: const BoxDecoration(
                            color: AppColors.onPrimaryFill,
                            borderRadius: BorderRadius.all(Radius.circular(2)),
                          ),
                        ),
                      ],
                    ],
                  )
                : Padding(
                    padding: EdgeInsets.only(left: 3 * scale),
                    child: AppIcon(
                      AppGlyph.play,
                      size: 24 * scale,
                      color: AppColors.onPrimaryFill,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

/// The `1.0×` chip. Cycles through [speeds]; the rate itself is the caller's.
class SpeedChip extends StatelessWidget {
  const SpeedChip({required this.speed, required this.onChanged, super.key});

  /// The order the chip walks through.
  static const List<double> speeds = <double>[1.0, 1.5, 2.0, 0.5];

  final double speed;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return TapTarget(
      semanticLabel: 'Playback speed',
      onTap: () {
        final current = speeds.indexOf(speed);
        onChanged(speeds[(current + 1) % speeds.length]);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.border),
          borderRadius: AppShape.pill,
        ),
        child: Text('${speed.toStringAsFixed(1)}×', style: AppText.label13),
      ),
    );
  }
}
