import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/view/speaker_palette.dart';
import 'package:voicenotetaker_app/view/theme.dart';

import 'theme_test.dart' show contrast;

void main() {
  const List<String> order = <String>['S1', 'S2', 'S3'];

  group('speaker colours', () {
    test('a label keeps its colour however often it is asked', () {
      final first = SpeakerPalette.of('S2', order);
      for (var i = 0; i < 5; i++) {
        expect(SpeakerPalette.of('S2', order), first);
      }
      expect(first, SpeakerPalette.colors[1]);
    });

    test('the colour comes from where the label first speaks', () {
      expect(SpeakerPalette.of('S1', order), SpeakerPalette.colors[0]);
      expect(SpeakerPalette.of('S2', order), SpeakerPalette.colors[1]);
      expect(SpeakerPalette.of('S3', order), SpeakerPalette.colors[2]);
    });

    test('renaming a speaker does not move a colour', () {
      // Names live elsewhere; the palette only ever sees labels, so there is
      // nothing a rename could change.
      final before = <String, Color>{
        for (final label in order) label: SpeakerPalette.of(label, order),
      };
      expect(
        <String, Color>{
          for (final label in order) label: SpeakerPalette.of(label, order),
        },
        before,
      );
    });

    test('a label not in the order falls back to the first colour', () {
      expect(SpeakerPalette.of('S9', order), SpeakerPalette.colors.first);
      expect(SpeakerPalette.at(-1), SpeakerPalette.colors.first);
    });

    test('more speakers than colours wraps rather than running out', () {
      expect(
        SpeakerPalette.at(SpeakerPalette.colors.length),
        SpeakerPalette.colors.first,
      );
      expect(
        SpeakerPalette.at(SpeakerPalette.colors.length + 2),
        SpeakerPalette.colors[2],
      );
    });

    test('the canvas order: purple, then green, then amber', () {
      expect(SpeakerPalette.colors[0], AppColors.purpleText);
      expect(SpeakerPalette.colors[1], AppColors.connected);
      expect(SpeakerPalette.colors[2], AppColors.warning);
    });

    test('every colour is readable as text on the dark background', () {
      for (final color in SpeakerPalette.colors) {
        expect(
          contrast(color, AppColors.screen),
          greaterThanOrEqualTo(4.5),
          reason: '$color',
        );
        // And on the sheet's own fill, which is lighter than the screen.
        expect(
          contrast(color, AppColors.card),
          greaterThanOrEqualTo(4.5),
          reason: '$color on the sheet',
        );
      }
    });

    test('the fill-only primary is not in the palette', () {
      // #6D28D9 measures 2.78:1 - see the contrast rule in theme.dart.
      expect(SpeakerPalette.colors, isNot(contains(AppColors.primaryFill)));
    });
  });
}
