import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/view/theme.dart';

/// WCAG 2.1 relative luminance.
double _luminance(Color c) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel((c.r * 255).roundToDouble() / 255) +
      0.7152 * channel((c.g * 255).roundToDouble() / 255) +
      0.0722 * channel((c.b * 255).roundToDouble() / 255);
}

/// WCAG 2.1 contrast ratio between two opaque colours.
double contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('surfaces', () {
    test('are the documented token values', () {
      expect(AppColors.canvas, const Color(0xFF08070C));
      expect(AppColors.screen, const Color(0xFF0B0A0F));
      expect(AppColors.card, const Color(0xFF14121B));
      expect(AppColors.raised, const Color(0xFF1D1927));
      expect(AppColors.border, const Color(0xFF2C2738));
    });
  });

  group('text colours', () {
    test('are the documented token values', () {
      expect(AppColors.textPrimary, const Color(0xFFF4F1FB));
      expect(AppColors.textSecondary, const Color(0xFF9A93AC));
      expect(AppColors.textTertiary, const Color(0xFF665F78));
    });
  });

  group('purple ramp', () {
    test('is the documented six-step ramp', () {
      expect(AppColors.purple100, const Color(0xFFEDE9FE));
      expect(AppColors.purple300, const Color(0xFFC4B5FD));
      expect(AppColors.purple400, const Color(0xFFA78BFA));
      expect(AppColors.purple500, const Color(0xFF8B5CF6));
      expect(AppColors.purple600, const Color(0xFF7C3AED));
      expect(AppColors.purple700, const Color(0xFF6D28D9));
    });

    test('the primary is 700 and it is a fill, not a text colour', () {
      expect(AppColors.primaryFill, AppColors.purple700);
      expect(AppColors.purpleText, AppColors.purple400);
      expect(AppColors.onPrimaryFill, AppColors.textPrimary);
    });
  });

  group('device state colours', () {
    test('are the documented token values', () {
      expect(AppColors.connected, const Color(0xFF4ADE80));
      expect(AppColors.recording, const Color(0xFFFB7185));
      expect(AppColors.warning, const Color(0xFFFBBF24));
      expect(AppColors.error, const Color(0xFFF87171));
      expect(AppColors.disconnected, const Color(0xFF665F78));
    });
  });

  // ---------------------------------------------------------------------
  // THE CONTRAST RULE. These are the measurements the palette is built on;
  // if one of them moves, a screen has become unreadable.
  // ---------------------------------------------------------------------
  group('the contrast rule', () {
    test('#6D28D9 fails as a text colour on the dark background', () {
      final ratio = contrast(AppColors.primaryFill, AppColors.screen);
      expect(ratio, closeTo(2.78, 0.01));
      expect(ratio, lessThan(4.5), reason: 'fails the text floor');
      expect(ratio, lessThan(3.0), reason: 'fails the UI-element floor');
    });

    test('#A78BFA is the purple that passes for text and icons', () {
      expect(contrast(AppColors.purpleText, AppColors.screen),
          closeTo(7.25, 0.01));
      expect(contrast(AppColors.purpleText, AppColors.screen),
          greaterThan(4.5));
    });

    test('light content on the primary fill passes', () {
      expect(contrast(AppColors.onPrimaryFill, AppColors.primaryFill),
          closeTo(6.37, 0.01));
      expect(contrast(AppColors.onPrimaryFill, AppColors.primaryFill),
          greaterThan(4.5));
    });

    test('dark content on the primary fill would fail', () {
      expect(contrast(AppColors.screen, AppColors.primaryFill),
          lessThan(3.0));
    });

    test('body text on every surface clears 4.5:1', () {
      for (final surface in <Color>[
        AppColors.canvas,
        AppColors.screen,
        AppColors.card,
        AppColors.raised,
      ]) {
        expect(contrast(AppColors.textPrimary, surface), greaterThan(4.5));
        expect(contrast(AppColors.textSecondary, surface), greaterThan(4.5));
      }
    });
  });

  group('type scale', () {
    test('is Sora throughout', () {
      expect(AppText.family, 'Sora');
      for (final style in <TextStyle>[
        AppText.h1,
        AppText.title21,
        AppText.title22,
        AppText.title24,
        AppText.caption,
        AppText.rowTitle,
        AppText.rowMeta,
        AppText.timer,
        AppText.buttonLabel,
        AppText.badge,
      ]) {
        expect(style.fontFamily, 'Sora');
      }
    });

    test('uses only the five weights the design specifies', () {
      final allowed = <FontWeight>{
        FontWeight.w200,
        FontWeight.w300,
        FontWeight.w400,
        FontWeight.w500,
        FontWeight.w600,
      };
      for (final style in <TextStyle>[
        AppText.h1,
        AppText.title21,
        AppText.title22,
        AppText.title24,
        AppText.caption,
        AppText.captionSmall,
        AppText.rowTitle,
        AppText.rowMeta,
        AppText.deviceName,
        AppText.macAddress,
        AppText.buttonLabel,
        AppText.buttonLabelQuiet,
        AppText.body13,
        AppText.label13,
        AppText.meta12,
        AppText.meta13,
        AppText.meta14,
        AppText.timer,
        AppText.peakValue,
        AppText.scrubTime,
        AppText.devLabel,
        AppText.devValue,
        AppText.badge,
        AppText.footnote11,
        AppText.footnote12,
        AppText.micro10,
      ]) {
        expect(allowed, contains(style.fontWeight));
      }
    });

    test('the recording timer is 62px, weight 200, tabular', () {
      expect(AppText.timer.fontSize, 62);
      expect(AppText.timer.fontWeight, FontWeight.w200);
      expect(AppText.timer.letterSpacing, closeTo(-1.86, 0.001));
      expect(
        AppText.timer.fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );
    });

    test('every figure that ticks is tabular', () {
      for (final style in <TextStyle>[
        AppText.timer,
        AppText.peakValue,
        AppText.scrubTime,
      ]) {
        expect(
          style.fontFeatures,
          contains(const FontFeature.tabularFigures()),
          reason: 'figures must not reflow as they change',
        );
      }
    });

    test('headings carry the mock\'s -0.02em tracking', () {
      expect(AppText.h1.fontSize, 26);
      expect(AppText.h1.letterSpacing, closeTo(26 * -0.02, 0.001));
      expect(AppText.title21.letterSpacing, closeTo(21 * -0.02, 0.001));
      expect(AppText.title24.letterSpacing, closeTo(24 * -0.02, 0.001));
    });
  });

  group('shape tokens', () {
    test('minimum hit target is 44', () {
      expect(AppShape.minTapTarget, 44);
    });

    test('screen gutter is the mock\'s 24px', () {
      expect(AppShape.gutter, 24);
    });
  });

  group('ThemeData', () {
    test('paints on the screen surface with the primary as its fill', () {
      final theme = AppTheme.build();
      expect(theme.scaffoldBackgroundColor, AppColors.screen);
      expect(theme.colorScheme.primary, AppColors.primaryFill);
      expect(theme.colorScheme.onPrimary, AppColors.onPrimaryFill);
      expect(theme.brightness, Brightness.dark);
      expect(theme.textTheme.bodyMedium?.fontFamily, 'Sora');
    });
  });
}
