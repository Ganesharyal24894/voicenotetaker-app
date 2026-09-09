import 'package:flutter/material.dart';

import '../theme.dart';

/// The live capture meter from screen 3.
///
/// 32 bars, 3px wide, 3px apart, 2px radius, in a 118px tall band - the exact
/// geometry of `design/Main.dc.html`. The bar heights are the mock's own
/// values; [advance] rotates through them so the meter moves as frames land,
/// which is why the mock's still frame is reproduced exactly at `advance == 0`.
///
/// PLACEHOLDER AMPLITUDES: nothing below `view/` exposes a sample level yet -
/// `CaptureStats` counts packets, not loudness - so these heights are a
/// stand-in, not measured audio. When a level-meter service exists, feed it in
/// through [levels] and delete [advance].
class LiveWaveform extends StatelessWidget {
  const LiveWaveform({this.advance = 0, this.levels, super.key});

  /// How far to rotate the placeholder pattern. Feed it a monotonically
  /// increasing counter (frames received) to make the meter move.
  final int advance;

  /// Real, measured levels in `0.0 .. 1.0`, once something can produce them.
  final List<double>? levels;

  static const double barWidth = 3;
  static const double barGap = 3;
  static const double bandHeight = 118;

  /// Bar heights straight out of the mock, in pixels of the 118px band.
  static const List<double> mockHeights = <double>[
    14, 26, 19, 41, 58, 33, 72, 47, 88, 61, 104, 77, 52, 91, 66, 38,
    83, 112, 69, 44, 96, 57, 29, 74, 49, 86, 35, 63, 22, 45, 17, 31,
  ];

  /// The mock colours bars by how tall they are: the floor stays inert, the
  /// peaks brighten. These are the thresholds that reproduce its ramp.
  static Color colorForLevel(double level) {
    if (level < 0.20) return AppColors.waveFloor;
    if (level < 0.30) return AppColors.purple900;
    if (level < 0.43) return AppColors.purple800;
    if (level < 0.55) return AppColors.purple700;
    if (level < 0.65) return AppColors.purple600;
    if (level < 0.85) return AppColors.purple500;
    if (level < 0.92) return AppColors.purple400;
    return AppColors.purple300;
  }

  List<double> get _levels {
    final measured = levels;
    if (measured != null && measured.isNotEmpty) return measured;
    final count = mockHeights.length;
    final shift = advance % count;
    return <double>[
      for (var i = 0; i < count; i++)
        mockHeights[(i + shift) % count] / bandHeight,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final levels = _levels;
    return SizedBox(
      height: bandHeight,
      width: double.infinity,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          for (var i = 0; i < levels.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: barGap),
            Container(
              width: barWidth,
              height: (levels[i].clamp(0.0, 1.0) * bandHeight)
                  .clamp(2.0, bandHeight),
              decoration: BoxDecoration(
                color: colorForLevel(levels[i]),
                borderRadius: const BorderRadius.all(Radius.circular(2)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The playback scrubber from screen 5: 22 flexible bars in a 92px band, 2px
/// apart, 1px radius. Bars before the playhead are filled with the primary
/// (peaks a step lighter); bars after it are the hairline colour.
class ScrubWaveform extends StatelessWidget {
  const ScrubWaveform({
    required this.progress,
    this.onSeek,
    this.levels = mockLevels,
    super.key,
  });

  /// Playhead position in `0.0 .. 1.0`.
  final double progress;

  /// Called with the fraction that was tapped.
  final ValueChanged<double>? onSeek;

  final List<double> levels;

  static const double bandHeight = 92;

  /// The mock's bar heights, as fractions of the band.
  static const List<double> mockLevels = <double>[
    0.24, 0.52, 0.38, 0.71, 0.88, 0.46, 0.63, 0.97, 0.41, 0.29, 0.66,
    0.34, 0.78, 0.51, 0.22, 0.69, 0.44, 0.83, 0.31, 0.57, 0.26, 0.48,
  ];

  @override
  Widget build(BuildContext context) {
    final played = (progress.clamp(0.0, 1.0) * levels.length).round();
    return Semantics(
      slider: true,
      value: '${(progress.clamp(0.0, 1.0) * 100).round()}%',
      child: LayoutBuilder(
        builder: (context, constraints) {
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: onSeek == null
                ? null
                : (details) => onSeek!(
                      (details.localPosition.dx / constraints.maxWidth)
                          .clamp(0.0, 1.0),
                    ),
            child: SizedBox(
              height: bandHeight,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  for (var i = 0; i < levels.length; i++) ...<Widget>[
                    if (i > 0) const SizedBox(width: 2),
                    Expanded(
                      child: Container(
                        height: (levels[i] * bandHeight).clamp(2.0, bandHeight),
                        decoration: BoxDecoration(
                          color: i < played
                              ? (levels[i] >= 0.85
                                  ? AppColors.purple600
                                  : AppColors.purple700)
                              : AppColors.border,
                          borderRadius:
                              const BorderRadius.all(Radius.circular(1)),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
