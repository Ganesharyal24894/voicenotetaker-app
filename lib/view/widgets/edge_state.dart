import 'package:flutter/material.dart';

import '../theme.dart';
import 'app_icons.dart';
import 'common.dart';

/// The one empty/edge state in the app: an icon well, a headline, a line of
/// body copy, an optional primary action and an optional secondary one.
///
/// All seven states in `design/edge-states/` are this structure with different
/// content, so they are this widget with different content - seven near-copies
/// would be seven places for the spacing to drift.
///
/// COLOUR ENCODES CATEGORY, and it is load-bearing:
///
///   * [AppColors.warning] - the user can fix it (Bluetooth off, permission
///     denied, link dropped).
///   * [AppColors.error] - it genuinely failed, or cannot work at all
///     (handshake failed, no Bluetooth LE on this phone).
///   * [AppColors.purpleText] - NOTHING IS WRONG. "No recorder nearby" and
///     "No recordings yet" are results, not failures, and must not be tinted
///     as if they were.
///
/// An [onPrimary] of null means there is no primary action, and that too is a
/// deliberate state rather than an oversight: the unsupported-phone screen
/// offers none, because retrying cannot help and a retry button would be a
/// lie.
///
/// Place it inside an [Expanded]; it fills the space it is given and centres
/// its content, lifted by [bottomLift] so the block sits on the optical centre
/// rather than the geometric one.
class EdgeState extends StatelessWidget {
  const EdgeState({
    required this.glyph,
    required this.tint,
    required this.headline,
    required this.body,
    this.primaryLabel,
    this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
    super.key,
  })  : assert(
          (primaryLabel == null) == (onPrimary == null),
          'a primary action needs both a label and a callback, or neither',
        ),
        assert(
          (secondaryLabel == null) == (onSecondary == null),
          'a secondary action needs both a label and a callback, or neither',
        );

  /// The glyph in the well. Every edge state has one, and they differ.
  final AppGlyph glyph;

  /// The glyph's colour, and the state's category - see the class comment.
  final Color tint;

  final String headline;
  final String body;

  final String? primaryLabel;
  final VoidCallback? onPrimary;

  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  /// Edge of the square icon well.
  static const double wellSize = 64;

  /// The glyph inside it.
  static const double glyphSize = 28;

  /// The body copy is measured, not full-bleed: 292px is what the mockups set,
  /// and it is what keeps the line length readable.
  static const double bodyMaxWidth = 292;

  /// How far above the geometric centre the block sits.
  static const double bottomLift = 72;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: bottomLift),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          // Stretched so the primary button spans the content width; the text
          // centres itself with `textAlign`.
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Center(
              child: Container(
                width: wellSize,
                height: wellSize,
                decoration: BoxDecoration(
                  color: AppColors.card,
                  // #2C2738, a step brighter than the cards' hairline: the
                  // well is the only thing on the screen and has to hold.
                  border: Border.all(color: AppColors.border),
                  borderRadius: AppShape.card,
                ),
                alignment: Alignment.center,
                child: AppIcon(
                  glyph,
                  size: glyphSize,
                  color: tint,
                  strokeWidth: 1.6,
                ),
              ),
            ),
            const SizedBox(height: 22),
            Text(
              headline,
              style: AppText.title21,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: bodyMaxWidth),
                child: Text(
                  body,
                  // 14/300 tertiary at a 1.5 line height, which is the mock's
                  // paragraph setting rather than its single-line one.
                  style: AppText.meta14.copyWith(height: 1.5),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
            const SizedBox(height: 28),
            if (onPrimary != null)
              PrimaryButton(
                label: primaryLabel!,
                height: 48,
                onPressed: onPrimary,
              ),
            if (onSecondary != null)
              TapTarget(
                onTap: onSecondary,
                semanticLabel: secondaryLabel,
                child: Text(
                  secondaryLabel!,
                  style: AppText.label13.copyWith(color: AppColors.purpleText),
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
