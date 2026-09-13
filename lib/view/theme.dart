import 'package:flutter/material.dart';

/// Design tokens, lifted verbatim from `design/Palette.dc.html` and
/// `design/Main.dc.html`. This file is the single source of truth for colour
/// and type in `lib/view/`; no screen may hard-code a hex value.
///
/// ---------------------------------------------------------------------------
/// THE CONTRAST RULE - LOAD-BEARING, DO NOT VIOLATE
///
/// [AppColors.purple700] (#6D28D9) is the PRIMARY, but it measures only
/// 2.78:1 against the dark background. That fails the 4.5:1 floor for text
/// AND the 3:1 floor for UI elements. Therefore:
///
///   * #6D28D9 is a FILL colour only - buttons, waveform bars, filled chips.
///   * Content ON that fill must be LIGHT ([AppColors.textPrimary] #F4F1FB,
///     6.37:1). NEVER a dark icon or dark text on the purple fill: that is
///     2.78:1 and fails.
///   * Purple TEXT and ICONS on the dark background use
///     [AppColors.purpleText] (#A78BFA, 7.25:1), never #6D28D9.
///
/// The two aliases [AppColors.onPrimaryFill] and [AppColors.purpleText] exist
/// so the rule is expressed in the type system of the palette rather than left
/// to memory at each call site.
/// ---------------------------------------------------------------------------
abstract final class AppColors {
  // Surfaces.
  static const Color canvas = Color(0xFF08070C);
  static const Color screen = Color(0xFF0B0A0F);
  static const Color card = Color(0xFF14121B);
  static const Color raised = Color(0xFF1D1927);
  static const Color border = Color(0xFF2C2738);

  // Text.
  static const Color textPrimary = Color(0xFFF4F1FB);
  static const Color textSecondary = Color(0xFF9A93AC);
  static const Color textTertiary = Color(0xFF665F78);

  // Purple ramp.
  static const Color purple100 = Color(0xFFEDE9FE);
  static const Color purple300 = Color(0xFFC4B5FD);
  static const Color purple400 = Color(0xFFA78BFA);
  static const Color purple500 = Color(0xFF8B5CF6);
  static const Color purple600 = Color(0xFF7C3AED);
  static const Color purple700 = Color(0xFF6D28D9);

  /// The primary. FILL ONLY - see the contrast rule above.
  static const Color primaryFill = purple700;

  /// The only content colour permitted on top of [primaryFill].
  static const Color onPrimaryFill = textPrimary;

  /// Purple for text and icons ON THE DARK BACKGROUND. Never [primaryFill].
  static const Color purpleText = purple400;

  // Device state.
  static const Color connected = Color(0xFF4ADE80);
  static const Color recording = Color(0xFFFB7185);
  static const Color warning = Color(0xFFFBBF24);
  static const Color error = Color(0xFFF87171);
  static const Color disconnected = Color(0xFF665F78);

  // Deeper ramp steps used only as waveform bar fills in the mock. They are
  // fills, never text, so the contrast rule is satisfied by construction.
  static const Color waveFloor = Color(0xFF3A3350);
  static const Color purple900 = Color(0xFF4C1D95);
  static const Color purple800 = Color(0xFF5B21B6);

  /// Unplayed scrubber bars, the short ones. `#2C2738` - the same value as
  /// [border], named separately because here it is a waveform fill rather than
  /// a hairline.
  static const Color waveUnplayed = border;

  /// Unplayed scrubber bars, the tall ones. `#332C44`, from screen 5 of
  /// `design/Main.dc.html`.
  static const Color waveUnplayedTall = Color(0xFF332C44);

  /// The playback playhead. `#EDE9FE` - it has to read as a bright line
  /// against both the played and the unplayed bars.
  static const Color playhead = purple100;

  /// The scan ripple rings. `#4C1D95`.
  static const Color scanRipple = purple900;

  /// The board artwork in `design/DeviceMotion.dc.html`, `#board`. These are
  /// fills in a 38x46 logo, never text.
  static const Color boardTop = Color(0xFF241F33);
  static const Color boardBottom = Color(0xFF14111D);
  static const Color boardEdge = Color(0xFF3A3350);
  static const Color boardShieldTop = Color(0xFF4A4460);
  static const Color boardShieldBottom = Color(0xFF2E2940);
  static const Color boardShieldEdge = Color(0xFF5B5470);
  static const Color boardMetal = Color(0xFF6E6880);
  static const Color boardSlot = Color(0xFF171423);
  static const Color boardGold = Color(0xFFC9A227);

  /// `rgba(109, 40, 217, 0.22)` - the Transcribe chip fill.
  static const Color purpleChipFill = Color(0x386D28D9);

  /// `rgba(167, 139, 250, 0.30)` - the Transcribe chip hairline.
  static const Color purpleChipBorder = Color(0x4DA78BFA);

  /// `rgba(251, 191, 36, 0.14)` - the DEBUG ONLY badge fill.
  /// Outline for a destructive control. The full-strength [error] would
  /// shout next to the record button; this is the same hue at a border's
  /// weight, matching how [border] relates to the fills around it.
  static const Color errorBorder = Color(0x66F87171);

  static const Color warningBadgeFill = Color(0x24FBBF24);

  /// `rgba(251, 191, 36, 0.32)` - the DEBUG ONLY badge hairline.
  static const Color warningBadgeBorder = Color(0x52FBBF24);
}

/// Type scale from the mock. Sora, bundled at `assets/fonts/` in the five
/// weights the design uses (200, 300, 400, 500, 600) so nothing is fetched at
/// runtime.
///
/// The mock expresses tracking in `em`; these are the same values multiplied
/// out into logical pixels, which is what Flutter's `letterSpacing` takes.
abstract final class AppText {
  static const String family = 'Sora';

  static const List<FontFeature> _tabular = <FontFeature>[
    FontFeature.tabularFigures(),
  ];

  static const TextStyle _base = TextStyle(
    fontFamily: family,
    color: AppColors.textPrimary,
    height: 1.2,
  );

  /// `.h1` - 26px / 500 / -0.02em.
  static const TextStyle h1 = TextStyle(
    fontFamily: family,
    fontSize: 26,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.52,
    color: AppColors.textPrimary,
  );

  /// Screen title on Home and the Developer heading - 21px / 500 / -0.02em.
  static const TextStyle title21 = TextStyle(
    fontFamily: family,
    fontSize: 21,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.42,
    color: AppColors.textPrimary,
  );

  /// Playback title - 24px / 500 / -0.02em.
  static const TextStyle title24 = TextStyle(
    fontFamily: family,
    fontSize: 24,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.48,
    color: AppColors.textPrimary,
  );

  /// Developer heading - 22px / 500 / -0.02em.
  static const TextStyle title22 = TextStyle(
    fontFamily: family,
    fontSize: 22,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.44,
    color: AppColors.textPrimary,
  );

  /// `.cap` - 12px / 400 / 0.09em, uppercased by the caller.
  static const TextStyle caption = TextStyle(
    fontFamily: family,
    fontSize: 12,
    fontWeight: FontWeight.w400,
    letterSpacing: 1.08,
    color: AppColors.textTertiary,
  );

  /// The Developer cards use the same cap at 10px.
  static const TextStyle captionSmall = TextStyle(
    fontFamily: family,
    fontSize: 10,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.9,
    color: AppColors.textTertiary,
  );

  /// `.rt` - list row title, 15px / 400.
  static const TextStyle rowTitle = TextStyle(
    fontFamily: family,
    fontSize: 15,
    fontWeight: FontWeight.w400,
    color: AppColors.textPrimary,
  );

  /// `.rs` - list row meta, 12px / 300.
  static const TextStyle rowMeta = TextStyle(
    fontFamily: family,
    fontSize: 12,
    fontWeight: FontWeight.w300,
    color: AppColors.textTertiary,
  );

  /// Device card name - 16px / 500.
  static const TextStyle deviceName = TextStyle(
    fontFamily: family,
    fontSize: 16,
    fontWeight: FontWeight.w500,
    color: AppColors.textPrimary,
  );

  /// MAC address under a device name - 12px / 300 / 0.02em.
  ///
  /// The address is deliberately user-visible: it is how two identical
  /// recorders are told apart.
  static const TextStyle macAddress = TextStyle(
    fontFamily: family,
    fontSize: 12,
    fontWeight: FontWeight.w300,
    letterSpacing: 0.24,
    color: AppColors.textTertiary,
  );

  /// Filled-button label - 15px / 500, always on [AppColors.primaryFill].
  static const TextStyle buttonLabel = TextStyle(
    fontFamily: family,
    fontSize: 15,
    fontWeight: FontWeight.w500,
    color: AppColors.onPrimaryFill,
  );

  /// 14px / 400 - the outlined "Export diagnostics" label.
  static const TextStyle buttonLabelQuiet = TextStyle(
    fontFamily: family,
    fontSize: 14,
    fontWeight: FontWeight.w400,
    color: AppColors.textSecondary,
  );

  /// 13px / 300 secondary body ("Scanning...", "Connected").
  static const TextStyle body13 = TextStyle(
    fontFamily: family,
    fontSize: 13,
    fontWeight: FontWeight.w300,
    color: AppColors.textSecondary,
  );

  /// 13px / 400 - chips and the purple "All" link.
  static const TextStyle label13 = TextStyle(
    fontFamily: family,
    fontSize: 13,
    fontWeight: FontWeight.w400,
    color: AppColors.textSecondary,
  );

  /// 12px / 300 tertiary meta.
  static const TextStyle meta12 = TextStyle(
    fontFamily: family,
    fontSize: 12,
    fontWeight: FontWeight.w300,
    color: AppColors.textTertiary,
  );

  /// The battery percentage - 12px / 300 tertiary, tabular. The charge ticks
  /// while the app is open, and the header must not reflow when it does.
  static const TextStyle batteryValue = TextStyle(
    fontFamily: family,
    fontSize: 12,
    fontWeight: FontWeight.w300,
    color: AppColors.textTertiary,
    fontFeatures: _tabular,
  );

  /// 13px / 300 tertiary meta.
  static const TextStyle meta13 = TextStyle(
    fontFamily: family,
    fontSize: 13,
    fontWeight: FontWeight.w300,
    color: AppColors.textTertiary,
  );

  /// 14px / 300 tertiary - "Tap to record", the search placeholder.
  static const TextStyle meta14 = TextStyle(
    fontFamily: family,
    fontSize: 14,
    fontWeight: FontWeight.w300,
    color: AppColors.textTertiary,
  );

  /// The recording timer - 62px / 200 / -0.03em, tabular so the digits do not
  /// jitter as the seconds tick over.
  static const TextStyle timer = TextStyle(
    fontFamily: family,
    fontSize: 62,
    fontWeight: FontWeight.w200,
    letterSpacing: -1.86,
    color: AppColors.textPrimary,
    fontFeatures: _tabular,
  );

  /// Peak reading - 15px / 400, tabular.
  static const TextStyle peakValue = TextStyle(
    fontFamily: family,
    fontSize: 15,
    fontWeight: FontWeight.w400,
    color: AppColors.textSecondary,
    fontFeatures: _tabular,
  );

  /// Elapsed / remaining under the scrubber - 13px / 300, tabular.
  static const TextStyle scrubTime = TextStyle(
    fontFamily: family,
    fontSize: 13,
    fontWeight: FontWeight.w300,
    color: AppColors.textSecondary,
    fontFeatures: _tabular,
  );

  /// Developer card label / value pair.
  static const TextStyle devLabel = TextStyle(
    fontFamily: family,
    fontSize: 13,
    fontWeight: FontWeight.w300,
    color: AppColors.textSecondary,
  );

  static const TextStyle devValue = TextStyle(
    fontFamily: family,
    fontSize: 13,
    fontWeight: FontWeight.w400,
    color: AppColors.textPrimary,
  );

  /// DEBUG ONLY badge - 11px / 500 / 0.06em.
  static const TextStyle badge = TextStyle(
    fontFamily: family,
    fontSize: 11,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.66,
    color: AppColors.warning,
  );

  /// 11px / 300 tertiary footnote inside a card.
  static const TextStyle footnote11 = TextStyle(
    fontFamily: family,
    fontSize: 11,
    fontWeight: FontWeight.w300,
    color: AppColors.textTertiary,
    height: 1.5,
  );

  /// 12px / 300 tertiary footnote, 1.5 line height.
  static const TextStyle footnote12 = TextStyle(
    fontFamily: family,
    fontSize: 12,
    fontWeight: FontWeight.w300,
    color: AppColors.textTertiary,
    height: 1.5,
  );

  /// 10px / 300 tertiary - the "15s" / "30s" skip labels.
  static const TextStyle micro10 = TextStyle(
    fontFamily: family,
    fontSize: 10,
    fontWeight: FontWeight.w300,
    color: AppColors.textTertiary,
  );
}

/// Geometry repeated across the mock.
abstract final class AppShape {
  /// `.card` corner radius.
  static const BorderRadius card = BorderRadius.all(Radius.circular(16));

  /// Buttons and the search field.
  static const BorderRadius control = BorderRadius.all(Radius.circular(12));

  /// The "New recording" call to action.
  static const BorderRadius cta = BorderRadius.all(Radius.circular(14));

  /// Codec selector segments.
  static const BorderRadius segment = BorderRadius.all(Radius.circular(10));

  /// Pill chips.
  static const BorderRadius pill = BorderRadius.all(Radius.circular(999));

  /// Screen gutter, from `.scr { padding: ... 24px }`.
  static const double gutter = 24;

  /// Minimum hit target on every interactive element.
  static const double minTapTarget = 44;
}

/// Durations and curves, lifted from the captions in `design/Motion.dc.html`
/// and `design/DeviceMotion.dc.html`.
///
/// REDUCE MOTION: every animation in `lib/view/` is gated on
/// [AppMotion.isReduced]. One-shot animations become instant state changes and
/// the two loops - the scan ripple and the connected dot - become static. See
/// `lib/view/widgets/motion.dart`.
abstract final class AppMotion {
  /// True when the platform asks for reduced motion.
  static bool isReduced(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context);

  /// Scan control: the refresh glyph turns once every 1.6 s, linear.
  static const Duration scanSpin = Duration(milliseconds: 1600);

  /// Scan control: each ripple ring takes 2.4 s to travel out and fade.
  static const Duration scanRipple = Duration(milliseconds: 2400);

  /// The second ring starts half a cycle behind the first.
  static const Duration scanRippleOffset = Duration(milliseconds: 1200);

  /// `scale(1)` to `scale(1.55)` - `design/Main.dc.html`, `@keyframes ripple`.
  static const double scanRippleScale = 1.55;

  /// Peak opacity of a ripple ring, at the moment it leaves the control.
  static const double scanRippleOpacity = 0.55;

  /// Device found: one full `rotateY`, fading up from `scale(.7)`.
  static const Duration deviceFound = Duration(milliseconds: 2100);

  /// `cubic-bezier(.18,.85,.3,1)`.
  static const Curve deviceFoundCurve = Cubic(0.18, 0.85, 0.3, 1);

  /// The overshoot the board settles back from.
  static const double deviceFoundOvershoot = 1.06;

  /// Where in [deviceFound] the overshoot peaks; the rest is the settle.
  static const double deviceFoundPeak = 0.86;

  /// The Hero flight from the scan screen into the Home header slot.
  static const Duration dock = Duration(milliseconds: 620);

  /// The connected dot breathes 1 -> 0.4 and back, for hours.
  static const Duration breathe = Duration(milliseconds: 2000);

  /// The dimmest the connected dot goes.
  static const double breatheMinOpacity = 0.4;

  /// A discovered row slides in from the right.
  static const Duration rowSlideIn = Duration(milliseconds: 450);

  /// `cubic-bezier(.2,.9,.3,1)`.
  static const Curve rowSlideInCurve = Cubic(0.2, 0.9, 0.3, 1);

  /// How far a row travels, in logical pixels.
  static const double rowSlideInOffset = 26;

  /// Rows that arrive together are staggered by this much.
  static const Duration rowStagger = Duration(milliseconds: 40);

  /// A press takes 120 ms down and 180 ms back up.
  static const Duration pressDown = Duration(milliseconds: 120);
  static const Duration pressRelease = Duration(milliseconds: 180);

  /// How far a pressed control shrinks.
  static const double pressScale = 0.93;
}

/// Material glue. The screens paint themselves from [AppColors] / [AppText];
/// this exists so framework-drawn chrome (text selection, the default text
/// style, scroll glow) matches the palette instead of Material's defaults.
abstract final class AppTheme {
  static ThemeData build() {
    const scheme = ColorScheme.dark(
      primary: AppColors.primaryFill,
      onPrimary: AppColors.onPrimaryFill,
      secondary: AppColors.purpleText,
      onSecondary: AppColors.screen,
      surface: AppColors.card,
      onSurface: AppColors.textPrimary,
      error: AppColors.error,
      onError: AppColors.textPrimary,
      outline: AppColors.border,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      fontFamily: AppText.family,
      scaffoldBackgroundColor: AppColors.screen,
      canvasColor: AppColors.canvas,
      splashFactory: InkRipple.splashFactory,
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: AppColors.purpleText,
        selectionColor: AppColors.purpleChipFill,
        selectionHandleColor: AppColors.purpleText,
      ),
      textTheme: const TextTheme(
        bodyMedium: AppText._base,
      ).apply(fontFamily: AppText.family),
    );
  }
}
