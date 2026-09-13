import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/view/theme.dart';

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

  int linesOf(String text, TextStyle style, double width) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: ui.TextDirection.ltr,
    )..layout(maxWidth: width);
    return painter.computeLineMetrics().length;
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

  test('the repeat heading fits beside its own circled i', () {
    fitsOneLine(
      'Each check is taken several times',
      style: AppText.devValue,
      width: cardWidth - 44,
    );
    fitsOneLine('Noise floor 7 times, voice 3 times.');
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
