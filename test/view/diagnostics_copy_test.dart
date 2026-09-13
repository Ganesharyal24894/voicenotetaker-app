import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/device_test_aggregate.dart';
import 'package:voicenotetaker_app/model/device_test_comparison.dart';
import 'package:voicenotetaker_app/model/device_test_result.dart';
import 'package:voicenotetaker_app/view/mic_check_copy.dart';
import 'package:voicenotetaker_app/view/theme.dart';
import 'package:voicenotetaker_app/view/widgets/common.dart';

/// The copy on Device Diagnostics, measured rather than eyeballed.
///
/// WHY THIS FILE EXISTS SEPARATELY FROM `diagnostics_view_test.dart`. "Short"
/// was the whole of the feedback this screen was rewritten for - *"the ui
/// messages in diagnostic are too verbose, it should be short"* - and "short"
/// is a measurement, not an opinion. A sentence that fits on one line in a
/// reviewer's head and wraps to three on a phone has not been shortened. So
/// every line the screen shows without being tapped is laid out here at the
/// width it actually gets, in the real typeface, and has to come out as ONE
/// line.
///
/// THE REAL SORA HAS TO BE LOADED, which is the reason for the [FontLoader] and
/// the reason this is not a group inside the screen's own test file. `flutter
/// test` renders unknown families in a fallback face whose glyphs are all one em
/// wide - about twice Sora's average advance - so a line-fit assertion made
/// against it would be measuring the wrong font, and loading the right one
/// changes the layout of every other test in whatever file does it.
///
/// THE WIDTHS ARE DERIVED, not guessed: 390 is the mock's frame,
/// [AppShape.gutter] is the screen's own padding either side, and a card adds
/// its 16px padding and a 1px hairline each side. Nothing here is a magic
/// number that can drift away from `widgets/common.dart`.
void main() {
  setUpAll(() async {
    final loader = FontLoader(AppText.family);
    for (final path in const <String>[
      'assets/fonts/Sora-Light.ttf',
      'assets/fonts/Sora-Regular.ttf',
    ]) {
      loader.addFont(
        Future<ByteData>.value(
          File(path).readAsBytesSync().buffer.asByteData(),
        ),
      );
    }
    await loader.load();
  });

  /// The mock's frame, less the screen gutter either side.
  const double screenWidth = 390 - AppShape.gutter * 2;

  /// The same, less an [AppCard]'s 16px padding and 1px hairline either side.
  const double cardWidth = screenWidth - (16 + 1) * 2;

  /// A line inside a check row, which shares its width with the circled i (44)
  /// and the Run control (96, plus the 4px between them).
  const double checkRowHeadingWidth = cardWidth - 44 - 4 - 96;

  int linesOfSpan(InlineSpan span, double width) {
    final painter = TextPainter(text: span, textDirection: ui.TextDirection.ltr)
      ..layout(maxWidth: width);
    return painter.computeLineMetrics().length;
  }

  int linesOf(String text, TextStyle style, double width) =>
      linesOfSpan(TextSpan(text: text, style: style), width);

  double widthOf(String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    return painter.width;
  }

  void fitsOneLine(
    String text, {
    TextStyle style = AppText.footnote11,
    double width = cardWidth,
  }) {
    expect(
      linesOf(text, style, width),
      1,
      reason: 'wraps at ${width.toStringAsFixed(0)}px: "$text"',
    );
  }

  test('the screen says what it is in one line', () {
    fitsOneLine(
      'How your recorder is doing. Nothing here changes it.',
      style: AppText.footnote12,
      width: screenWidth,
    );
  });

  test('every card says what it is in one line', () {
    fitsOneLine('How well the recorder is reaching your phone.');
    fitsOneLine('Two measurements to take now and compare later.');
    fitsOneLine('How warm the recorder is. Warmer than the room.');
  });

  test('every check says what it measures in one line', () {
    fitsOneLine('How much hiss the mic picks up in a silent room.');
    fitsOneLine('How loudly your voice reaches the recorder.');
  });

  // -------------------------------------------------------------------------
  // THE TWO LINES A CHECK NOW SHOWS WITHOUT BEING TAPPED
  //
  // This is the measurement that makes the condensing real. The card used to
  // print six things per reading and they were allowed to wrap, because at that
  // volume wrapping was the least of the problem. Two lines that wrap are a
  // different matter: the headline IS the answer, and an answer on three lines
  // has not been condensed, it has been rearranged.
  // -------------------------------------------------------------------------

  /// The disclosure control's own width, derived from its parts rather than
  /// assumed: its word in [AppText.label13], the gap, the chevron - and never
  /// less than the 44px hit target every control on this screen clears.
  ///
  /// A FUNCTION, NOT A FINAL. Anything measured at the top of `main` is measured
  /// before [setUpAll] has loaded Sora, which is the one mistake this whole file
  /// exists to avoid: the fallback face is about twice the advance and the
  /// derived width comes out 70px too wide.
  double detailsControlWidth() => math.max(
        AppShape.minTapTarget,
        widthOf(DetailsDisclosure.label, AppText.label13) +
            DetailsDisclosure.glyphGap +
            DetailsDisclosure.glyphSize,
      );

  /// What is left of a card's width for the line beside that control.
  double summaryWidth() => cardWidth - detailsControlWidth();

  /// The headline exactly as `_Headline` assembles it: the figure in
  /// [AppText.rowTitle], the comparison in [AppText.devLabel]. Measured as the
  /// two spans the widget really builds, because measuring the whole string in
  /// one style would be measuring a line the screen never draws.
  void headlineFitsOneLine(ReadingComparison comparison) {
    final text = MicCheckCopy.value(comparison) +
        MicCheckCopy.separator +
        MicCheckCopy.change(comparison);
    expect(
      linesOfSpan(
        TextSpan(
          children: <InlineSpan>[
            TextSpan(
              text: MicCheckCopy.value(comparison),
              style: AppText.rowTitle,
            ),
            TextSpan(
              text: MicCheckCopy.separator + MicCheckCopy.change(comparison),
              style: AppText.devLabel,
            ),
          ],
        ),
        cardWidth,
      ),
      1,
      reason: 'wraps at ${cardWidth.toStringAsFixed(0)}px: "$text"',
    );
  }

  ReadingComparison comparison(ReadingChange change, {num? latest = -100}) =>
      ReadingComparison(change: change, unit: 'dBFS', latest: latest);

  test('every comparison a check can lead with is one line', () {
    // EVERY ONE OF THEM, not the one a happy path produces. Each replaces the
    // others in the same slot, so each is measured on its own - and the figure
    // is the widest a dBFS reading can be, three digits and a minus sign.
    for (final change in ReadingChange.values) {
      headlineFitsOneLine(
        comparison(
          change,
          latest: change == ReadingChange.notMeasured ? null : -100,
        ),
      );
    }
  });

  test('the summary beside Details is one line, in every state', () {
    // The date on its own, and the date with every tag a batch that did not go
    // to plan can earn beside it. `12 Mar` is the widest form of the date.
    final now = DateTime(2026, 9, 14, 9, 14);
    for (final at in <DateTime>[
      now,
      now.subtract(const Duration(days: 1)),
      now.subtract(const Duration(days: 3)),
      DateTime(2026, 3, 12, 18, 2),
    ]) {
      fitsOneLine(
        MicCheckCopy.measuredWhen(at, now: now),
        width: summaryWidth(),
      );
    }

    /// A batch of [taken] samples out of [requested], every one of them [outcome].
    DeviceTestBatch batch(
      int taken,
      int requested,
      DeviceTestOutcome outcome,
    ) =>
        DeviceTestBatch(
          kind: DeviceTestKind.noiseFloor,
          runs: <DeviceTestResult>[
            for (var i = 0; i < taken; i++)
              DeviceTestResult(
                kind: DeviceTestKind.noiseFloor,
                outcome: outcome,
                startedAt: DateTime(2026, 3, 12, 18, 2 + i),
                duration: const Duration(seconds: 10),
                readings: const <DeviceTestReading>[
                  DeviceTestReading(
                    label: 'Noise floor (RMS)',
                    value: -100,
                    unit: 'dBFS',
                  ),
                ],
                batchId: 'b',
                repeatIndex: i + 1,
                repeatTarget: requested,
              ),
          ],
        );

    // The noise floor asks for seven, which is the widest count either check
    // produces, and `could not run` is the longest tag.
    for (final outcome in DeviceTestOutcome.values) {
      fitsOneLine(
        MicCheckCopy.taken(batch(1, 7, outcome), now: now),
        width: summaryWidth(),
      );
      fitsOneLine(
        MicCheckCopy.taken(batch(6, 7, outcome), now: now),
        width: summaryWidth(),
      );
      fitsOneLine(
        MicCheckCopy.taken(batch(7, 7, outcome), now: now),
        width: summaryWidth(),
      );
    }
  });

  test('what a change is measured against fits inside the details', () {
    // PROSE, AND INSIDE THE DISCLOSURE, so this one is allowed to wrap - but not
    // to balloon. Two lines is the budget: a third would put the sentence back in
    // the same territory the card was condensed out of.
    for (final threshold in <num?>[null, 0.83, 1.6, 12]) {
      final text = MicCheckCopy.basis(
        ReadingComparison(
          change: ReadingChange.same,
          unit: 'dBFS',
          latest: -100,
          previous: -100,
          threshold: threshold,
        ),
      );
      expect(
        linesOf(text, AppText.footnote11, cardWidth),
        lessThanOrEqualTo(2),
        reason: 'runs past two lines: "$text"',
      );
    }
  });

  test('every live state line is one line', () {
    // Each of these replaces the others in the same slot, so each is measured
    // on its own rather than as the longest of them.
    fitsOneLine('Live. Walk away and watch these change.');
    fitsOneLine('Not connected, so there is nothing to measure.');
    fitsOneLine('Paused while the mic check runs.');
    fitsOneLine('Not counting audio.');
  });

  test('every reason a check cannot run is one line', () {
    fitsOneLine('Connect to the recorder first.');
    fitsOneLine('A recording is running. Stop it, then try again.');
    fitsOneLine('Another check is running.');
  });

  test('every instruction given mid-check is one line', () {
    // These sit in a check row under the heading, at full card width.
    fitsOneLine('Keep it quiet and do not touch it. Measuring…');
    fitsOneLine('Speak now, about 30 cm away.');
    fitsOneLine('Get back to about 30 cm and speak again.');
    fitsOneLine('Saving…');
  });

  test('the temperature card\'s other two outcomes are one line each', () {
    fitsOneLine('This recorder does not report its temperature.');
    fitsOneLine('Connect to the recorder to read this.');
  });

  test('a check row heading has room for its own name', () {
    // The names share their line with the circled i and the Run control, which
    // is the tightest slot on the screen.
    fitsOneLine(
      'Noise floor',
      style: AppText.devValue,
      width: checkRowHeadingWidth,
    );
    fitsOneLine(
      'Sensitivity',
      style: AppText.devValue,
      width: checkRowHeadingWidth,
    );
  });

  test('the history line is one line at a plausible number of runs', () {
    fitsOneLine('0 runs saved on this phone, newest first.');
    fitsOneLine('137 runs saved on this phone, newest first.');
  });
}
