import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/view/theme.dart';
import 'package:voicenotetaker_app/view/widgets/waveform.dart';

/// The band the mock draws, at the mock's screen width less its gutters.
const Size _band = Size(342, ScrubWaveform.bandHeight);

/// Renders [painter] onto an opaque screen-coloured ground and hands back the
/// pixels it actually produced. Asserting on the widget tree would only prove
/// the widget was built; this proves what was drawn.
Future<_Pixels> _render(CustomPainter painter, Size size) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Offset.zero & size,
    Paint()..color = AppColors.screen,
  );
  painter.paint(canvas, size);
  final image = await recorder.endRecording().toImage(
        size.width.round(),
        size.height.round(),
      );
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final pixels = _Pixels(data!.buffer.asUint8List(), image.width);
  image.dispose();
  return pixels;
}

class _Pixels {
  _Pixels(this.bytes, this.width);

  final Uint8List bytes;
  final int width;

  Color at(int x, int y) {
    final i = (y * width + x) * 4;
    return Color.fromARGB(
      bytes[i + 3],
      bytes[i],
      bytes[i + 1],
      bytes[i + 2],
    );
  }

  /// Which of [candidates] the pixel at (x, y) is closest to.
  ///
  /// Nearest-match rather than exact equality because the bars are drawn
  /// anti-aliased; a bar centre still lands unambiguously on its own colour.
  Color nearest(int x, int y, List<Color> candidates) {
    final pixel = at(x, y);
    var best = candidates.first;
    var bestDistance = double.infinity;
    for (final candidate in candidates) {
      final d = _distance(pixel, candidate);
      if (d < bestDistance) {
        bestDistance = d;
        best = candidate;
      }
    }
    return best;
  }

  static double _distance(Color a, Color b) {
    final dr = a.r - b.r;
    final dg = a.g - b.g;
    final db = a.b - b.b;
    return dr * dr + dg * dg + db * db;
  }
}

/// The x of bar [i]'s centre, mirroring the painter's own layout.
double _barCentre(int i, double width) {
  final span = (width - ScrubWaveform.barWidth) / (ScrubWaveform.mockBarHeights.length - 1);
  return i * span + ScrubWaveform.barWidth / 2;
}

void main() {
  group('the scrubber matches the design', () {
    test('58 bars, 3px wide, on an amplitude envelope', () {
      expect(ScrubWaveform.mockBarHeights, hasLength(58));
      expect(ScrubWaveform.mockEnvelope, hasLength(58));
      expect(ScrubWaveform.barWidth, 3);
      expect(ScrubWaveform.bandHeight, 92);

      // Not uniform, and not monotonic: an envelope.
      final distinct = ScrubWaveform.mockEnvelope.toSet();
      expect(distinct.length, greaterThan(20));
      expect(ScrubWaveform.mockEnvelope.reduce((a, b) => a > b ? a : b),
          greaterThan(0.7));
      expect(ScrubWaveform.mockEnvelope.reduce((a, b) => a < b ? a : b),
          lessThan(0.2));
    });

    test('the ramp is by height, and only played bars are purple', () {
      // Played: the purple ramp, three steps.
      expect(ScrubWaveform.colorFor(24 / 92, played: true), AppColors.purple700);
      expect(ScrubWaveform.colorFor(39 / 92, played: true), AppColors.purple600);
      expect(ScrubWaveform.colorFor(71 / 92, played: true), AppColors.purple400);

      // Unplayed: the two track colours, never purple.
      expect(
        ScrubWaveform.colorFor(28 / 92, played: false),
        AppColors.waveUnplayed,
      );
      expect(
        ScrubWaveform.colorFor(57 / 92, played: false),
        AppColors.waveUnplayedTall,
      );
      expect(AppColors.waveUnplayed, const Color(0xFF2C2738));
      expect(AppColors.waveUnplayedTall, const Color(0xFF332C44));
      expect(AppColors.playhead, const Color(0xFFEDE9FE));
    });

    test('the played count follows the position', () {
      expect(ScrubWaveform.playedBars(0, 58), 0);
      expect(ScrubWaveform.playedBars(1, 58), 58);
      expect(ScrubWaveform.playedBars(26 / 58, 58), 26);
    });
  });

  testWidgets('it renders played, unplayed and the playhead at a given '
      'position', (tester) async {
    // 26 of 58 bars played - the mock's own 44.8%.
    const progress = 26 / 58;
    late _Pixels pixels;
    await tester.runAsync(() async {
      pixels = await _render(
        ScrubWaveformPainter(
          levels: ScrubWaveform.mockEnvelope,
          progress: progress,
        ),
        _band,
      );
    });

    const palette = <Color>[
      AppColors.screen,
      AppColors.purple700,
      AppColors.purple600,
      AppColors.purple400,
      AppColors.waveUnplayed,
      AppColors.waveUnplayedTall,
      AppColors.playhead,
    ];
    final midY = (_band.height / 2).round();

    // Bar 0 is played and short: the base of the purple ramp.
    expect(
      pixels.nearest(_barCentre(0, _band.width).round(), midY, palette),
      AppColors.purple700,
      reason: 'played, 24/92 tall',
    );

    // Bar 20 is played and the tallest peak before the playhead.
    expect(
      pixels.nearest(_barCentre(20, _band.width).round(), midY, palette),
      AppColors.purple400,
      reason: 'played, 71/92 tall',
    );

    // Bar 33 is past the playhead and short: the darker track colour.
    expect(
      pixels.nearest(_barCentre(33, _band.width).round(), midY, palette),
      AppColors.waveUnplayed,
      reason: 'unplayed, 28/92 tall',
    );

    // Bar 30 is past the playhead and tall: the lighter track colour.
    expect(
      pixels.nearest(_barCentre(30, _band.width).round(), midY, palette),
      AppColors.waveUnplayedTall,
      reason: 'unplayed, 57/92 tall',
    );

    // The playhead itself, a bright line at the play position.
    final playheadX = ScrubWaveformPainter.playheadCentre(
      progress,
      _band.width,
    ).round();
    expect(
      pixels.nearest(playheadX, midY, palette),
      AppColors.playhead,
      reason: 'the playhead sits at the play position',
    );

    // ...and it glows: the pixels either side of the line are lifted above
    // the bare screen colour.
    final glow = pixels.at(playheadX + 4, 8);
    expect(glow.r, greaterThan(AppColors.screen.r));
    expect(glow.g, greaterThan(AppColors.screen.g));
  });

  testWidgets('moving the position repaints a different split', (tester) async {
    late _Pixels early;
    late _Pixels late_;
    await tester.runAsync(() async {
      early = await _render(
        ScrubWaveformPainter(
          levels: ScrubWaveform.mockEnvelope,
          progress: 0.1,
        ),
        _band,
      );
      late_ = await _render(
        ScrubWaveformPainter(
          levels: ScrubWaveform.mockEnvelope,
          progress: 0.9,
        ),
        _band,
      );
    });

    const palette = <Color>[
      AppColors.screen,
      AppColors.purple700,
      AppColors.purple600,
      AppColors.purple400,
      AppColors.waveUnplayed,
      AppColors.waveUnplayedTall,
      AppColors.playhead,
    ];
    final midY = (_band.height / 2).round();
    final x = _barCentre(30, _band.width).round();

    expect(early.nearest(x, midY, palette), AppColors.waveUnplayedTall);
    expect(late_.nearest(x, midY, palette), isNot(AppColors.waveUnplayedTall));
  });

  testWidgets('it is still a scrubber: dragging across it seeks',
      (tester) async {
    final seeks = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: _band.width,
              child: ScrubWaveform(progress: 0.2, onSeek: seeks.add),
            ),
          ),
        ),
      ),
    );

    final box = tester.getRect(find.byType(ScrubWaveform));
    await tester.tapAt(Offset(box.left + box.width * 0.75, box.center.dy));
    await tester.pump();
    expect(seeks.single, moreOrLessEquals(0.75, epsilon: 0.01));

    seeks.clear();
    await tester.drag(
      find.byType(ScrubWaveform),
      const Offset(60, 0),
    );
    await tester.pump();
    expect(seeks, isNotEmpty);
  });

  group('the live capture meter', () {
    testWidgets('draws a flat line when no level source is publishing',
        (tester) async {
      late _Pixels pixels;
      await tester.runAsync(() async {
        pixels = await _render(
          const LiveWaveformPainter(levels: null),
          const Size(342, LiveWaveform.bandHeight),
        );
      });

      const mid = LiveWaveform.bandHeight ~/ 2;
      // A line across the middle...
      expect(pixels.at(170, mid), isNot(AppColors.screen));
      // ...and nothing above or below it. No fabricated bars.
      expect(pixels.at(170, 10), AppColors.screen);
      expect(pixels.at(170, LiveWaveform.bandHeight.round() - 10),
          AppColors.screen);
    });

    testWidgets('draws bars from measured levels', (tester) async {
      late _Pixels pixels;
      await tester.runAsync(() async {
        pixels = await _render(
          const LiveWaveformPainter(levels: <double>[0.9, 0.9, 0.9, 0.9]),
          const Size(342, LiveWaveform.bandHeight),
        );
      });

      // Something tall is drawn well away from the centre line.
      const mid = LiveWaveform.bandHeight ~/ 2;
      var painted = 0;
      for (var x = 0; x < 342; x++) {
        if (pixels.at(x, mid - 40) != AppColors.screen) painted++;
      }
      expect(painted, greaterThan(0));
    });

    test('the flat state is what the widget reports', () {
      expect(const LiveWaveform().isFlat, isTrue);
      expect(const LiveWaveform(levels: <double>[]).isFlat, isTrue);
      expect(const LiveWaveform(levels: <double>[0.5]).isFlat, isFalse);
    });
  });
}
