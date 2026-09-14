import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme.dart';

/// The live capture meter from screen 3.
///
/// 32 bars, 3px wide, 3px apart, in a 118px band - the geometry of
/// `design/Main.dc.html`.
///
/// REAL AMPLITUDE OR NOTHING. [levels] must be measured audio - the recording
/// screen builds it from `AppController.level`, which is `LevelMeter`'s
/// reading of the PCM the app just decoded. When it is null or empty - before
/// the first block lands, or if frames stop arriving - the meter draws a FLAT
/// LINE. It is deliberately never animated from canned data: the point of this
/// meter is that it proves the microphone is hearing you, and a meter that
/// moves while nothing is arriving proves the opposite of that.
class LiveWaveform extends StatelessWidget {
  const LiveWaveform({this.levels, super.key});

  /// Measured levels in `0.0 .. 1.0`, newest last. Null until something
  /// downstream of the decoder publishes them.
  final List<double>? levels;

  static const double barWidth = 3;
  static const double barGap = 3;
  static const double bandHeight = 118;

  /// How many bars the band holds.
  static const int barCount = 32;

  /// The mock's own bar heights, in pixels of the 118px band. Reference
  /// geometry for the design - NOT a fallback animation; see the class doc.
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

  /// True when there is nothing measured to draw.
  bool get isFlat => levels == null || levels!.isEmpty;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: isFlat ? 'Level meter, no signal' : 'Level meter',
      container: true,
      child: SizedBox(
        height: bandHeight,
        width: double.infinity,
        child: CustomPaint(painter: LiveWaveformPainter(levels: levels)),
      ),
    );
  }
}

/// Paints [LiveWaveform]. Public so a test can render it and assert on the
/// pixels it produced - in particular, that the no-signal state really is a
/// flat line and not a waveform.
class LiveWaveformPainter extends CustomPainter {
  const LiveWaveformPainter({required this.levels});

  final List<double>? levels;

  @override
  void paint(Canvas canvas, Size size) {
    final measured = levels;
    final centreY = size.height / 2;

    if (measured == null || measured.isEmpty) {
      // No level source: a flat line, not a fabricated waveform.
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, centreY - 1, size.width, 2),
          const Radius.circular(1),
        ),
        Paint()
          ..color = AppColors.waveFloor
          ..isAntiAlias = true,
      );
      return;
    }

    final shown = measured.length > LiveWaveform.barCount
        ? measured.sublist(measured.length - LiveWaveform.barCount)
        : measured;
    const pitch = LiveWaveform.barWidth + LiveWaveform.barGap;
    final totalWidth = shown.length * pitch - LiveWaveform.barGap;
    var x = (size.width - totalWidth) / 2;

    for (final raw in shown) {
      final level = raw.clamp(0.0, 1.0);
      final height =
          math.max(LiveWaveform.barWidth, level * LiveWaveform.bandHeight);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, centreY - height / 2, LiveWaveform.barWidth, height),
          const Radius.circular(2),
        ),
        Paint()
          ..color = LiveWaveform.colorForLevel(level)
          ..isAntiAlias = true,
      );
      x += pitch;
    }
  }

  @override
  bool shouldRepaint(LiveWaveformPainter oldDelegate) =>
      !listEquals(oldDelegate.levels, levels);
}

/// The playback scrubber from screen 5.
///
/// 58 bars, 3px wide with rounded caps, following an amplitude envelope rather
/// than sitting at a uniform height. Played bars take the purple ramp by
/// height (#6D28D9 / #7C3AED / #A78BFA); unplayed bars are #2C2738 or #332C44,
/// also by height, so the shape of the audio is still readable ahead of the
/// playhead. The playhead is a bright #EDE9FE line with a soft glow.
///
/// It remains a scrubber: tapping or dragging anywhere across the band seeks.
class ScrubWaveform extends StatelessWidget {
  const ScrubWaveform({
    required this.progress,
    this.onSeek,
    this.levels,
    this.height = bandHeight,
    super.key,
  });

  /// The band's height. [bandHeight] on a full screen; the note's audio panel
  /// uses a compact one. Bars scale with it.
  final double height;

  /// Playhead position in `0.0 .. 1.0`.
  final double progress;

  /// Called with the fraction that was tapped or dragged to.
  final ValueChanged<double>? onSeek;

  /// Measured levels in `0.0 .. 1.0`. Null falls back to [mockEnvelope]: no
  /// waveform extractor exists under `view/` yet, and unlike the live meter a
  /// scrubber with no envelope at all is not usable.
  final List<double>? levels;

  static const double bandHeight = 92;
  static const double barWidth = 3;

  /// The playhead: 2px wide with a soft glow, inset 6px top and bottom.
  static const double playheadWidth = 2;
  static const double playheadInset = 6;

  /// The mock's 58 bar heights, in pixels of the 92px band. Read straight off
  /// screen 5 of `design/Main.dc.html`, in order.
  static const List<double> mockBarHeights = <double>[
    24, 20, 37, 19, 36, 31, 21, 39, 21, 38, 24, 25, 40, 58, 28,
    33, 52, 68, 51, 43, 71, 27, 67, 39, 32, 31, 41, 66, 34, 55,
    57, 44, 53, 28, 28, 35, 58, 45, 39, 52, 45, 38, 60, 55, 33,
    47, 44, 58, 51, 32, 58, 24, 34, 45, 23, 33, 17, 35,
  ];

  /// [mockBarHeights] as fractions of the band.
  static final List<double> mockEnvelope = List<double>.unmodifiable(
    mockBarHeights.map((h) => h / bandHeight),
  );

  /// The played ramp turns over at 30/92 and 55/92 of the band; the unplayed
  /// track turns over at 40/92. Those are the thresholds that reproduce the
  /// mock's colouring bar for bar.
  static const double playedMidThreshold = 30 / bandHeight;
  static const double playedPeakThreshold = 55 / bandHeight;
  static const double unplayedTallThreshold = 40 / bandHeight;

  /// The colour of one bar. Pure, so the ramp can be asserted directly.
  static Color colorFor(double level, {required bool played}) {
    if (!played) {
      return level >= unplayedTallThreshold
          ? AppColors.waveUnplayedTall
          : AppColors.waveUnplayed;
    }
    if (level >= playedPeakThreshold) return AppColors.purple400;
    if (level >= playedMidThreshold) return AppColors.purple600;
    return AppColors.purple700;
  }

  /// How many bars are behind the playhead at [progress].
  static int playedBars(double progress, int barCount) =>
      (progress.clamp(0.0, 1.0) * barCount).round();

  List<double> get envelope {
    final measured = levels;
    return measured == null || measured.isEmpty ? mockEnvelope : measured;
  }

  @override
  Widget build(BuildContext context) {
    final clamped = progress.clamp(0.0, 1.0);
    return Semantics(
      slider: true,
      label: 'Playback position',
      value: '${(clamped * 100).round()}%',
      container: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          void seek(Offset local) {
            final width = constraints.maxWidth;
            if (width <= 0) return;
            onSeek!((local.dx / width).clamp(0.0, 1.0));
          }

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: onSeek == null ? null : (d) => seek(d.localPosition),
            onHorizontalDragStart:
                onSeek == null ? null : (d) => seek(d.localPosition),
            onHorizontalDragUpdate:
                onSeek == null ? null : (d) => seek(d.localPosition),
            child: SizedBox(
              height: height,
              width: double.infinity,
              child: CustomPaint(
                painter: ScrubWaveformPainter(
                  levels: envelope,
                  progress: clamped,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Paints [ScrubWaveform]. Public so a test can render it to an image and
/// assert on the pixels it actually produced, rather than on the widget tree
/// it was built from.
class ScrubWaveformPainter extends CustomPainter {
  const ScrubWaveformPainter({required this.levels, required this.progress});

  final List<double> levels;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    if (levels.isEmpty || size.width <= 0) return;
    final centreY = size.height / 2;
    final played = ScrubWaveform.playedBars(progress, levels.length);

    // `justify-content: space-between`: the first bar sits on the left edge
    // and the last on the right edge.
    const width = ScrubWaveform.barWidth;
    final span =
        levels.length == 1 ? 0.0 : (size.width - width) / (levels.length - 1);

    for (var i = 0; i < levels.length; i++) {
      final level = levels[i].clamp(0.0, 1.0);
      final height = math.max(width, level * size.height);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(i * span, centreY - height / 2, width, height),
          // A 999px radius on a 3px bar is a capsule: rounded caps.
          const Radius.circular(width / 2),
        ),
        Paint()
          ..color = ScrubWaveform.colorFor(level, played: i < played)
          ..isAntiAlias = true,
      );
    }

    _paintPlayhead(canvas, size);
  }

  /// Where the playhead line is drawn, in logical pixels across [width].
  static double playheadCentre(double progress, double width) =>
      (progress.clamp(0.0, 1.0) * width).clamp(
        ScrubWaveform.playheadWidth / 2,
        math.max(ScrubWaveform.playheadWidth / 2,
            width - ScrubWaveform.playheadWidth / 2),
      );

  void _paintPlayhead(Canvas canvas, Size size) {
    const w = ScrubWaveform.playheadWidth;
    final x = playheadCentre(progress, size.width);
    final line = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        x - w / 2,
        ScrubWaveform.playheadInset,
        w,
        math.max(w, size.height - ScrubWaveform.playheadInset * 2),
      ),
      const Radius.circular(w / 2),
    );

    // `box-shadow: 0 0 8px rgba(237,233,254,0.55)`.
    canvas.drawRRect(
      line,
      Paint()
        ..color = AppColors.playhead.withValues(alpha: 0.55)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4)
        ..isAntiAlias = true,
    );
    canvas.drawRRect(
      line,
      Paint()
        ..color = AppColors.playhead
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(ScrubWaveformPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      !listEquals(oldDelegate.levels, levels);
}
