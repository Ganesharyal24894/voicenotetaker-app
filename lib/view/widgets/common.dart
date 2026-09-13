import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';
import 'app_icons.dart';

/// The phone frame from the mock, translated to a real device.
///
/// `design/Main.dc.html` draws each screen as a 390x844 box with
/// `padding: 62px 24px 32px`. That 62px top includes the OS status bar - the
/// mock has no fake status bar and neither does this - so the gutter is
/// reconstructed as `viewPadding.top + 15`, which lands on exactly 62 on a
/// notched iPhone (47 + 15) and stays proportionate elsewhere. The bottom is
/// the larger of the mock's 32 and the home-indicator inset.
class ScreenScaffold extends StatelessWidget {
  const ScreenScaffold({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final viewPadding = MediaQuery.viewPaddingOf(context);
    return Scaffold(
      backgroundColor: AppColors.screen,
      body: SafeArea(
        // Top and bottom insets are applied by hand below so the mock's
        // measurements survive; SafeArea still handles landscape side notches.
        top: false,
        bottom: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            AppShape.gutter,
            viewPadding.top + 15,
            AppShape.gutter,
            math.max(32, viewPadding.bottom),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Wraps a small control so its hit area is never below 44x44, whatever the
/// painted glyph measures.
class TapTarget extends StatelessWidget {
  const TapTarget({
    required this.child,
    this.onTap,
    this.semanticLabel,
    this.minSize = AppShape.minTapTarget,
    super.key,
  });

  final Widget child;
  final VoidCallback? onTap;
  final String? semanticLabel;
  final double minSize;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: onTap != null,
      label: semanticLabel,
      // With a label of its own the control is one node: the glyph or text
      // inside must not add a second, duplicate one.
      container: semanticLabel != null,
      excludeSemantics: semanticLabel != null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: minSize, minHeight: minSize),
          child: Center(widthFactor: 1, heightFactor: 1, child: child),
        ),
      ),
    );
  }
}

/// A filled button on [AppColors.primaryFill].
///
/// THE CONTRAST RULE: the label and any glyph are forced to
/// [AppColors.onPrimaryFill]; nothing dark is ever drawn on this fill.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    required this.label,
    required this.onPressed,
    this.glyph,
    this.height = 46,
    this.borderRadius = AppShape.control,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final AppGlyph? glyph;
  final double height;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      container: true,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Opacity(
          opacity: enabled ? 1 : 0.45,
          child: Container(
            height: math.max(height, AppShape.minTapTarget),
            decoration: BoxDecoration(
              color: AppColors.primaryFill,
              borderRadius: borderRadius,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                if (glyph != null) ...<Widget>[
                  AppIcon(
                    glyph!,
                    size: 18,
                    color: AppColors.onPrimaryFill,
                    strokeWidth: 1.7,
                  ),
                  const SizedBox(width: 10),
                ],
                // Flexible, because the edge states put long labels here -
                // "Open Bluetooth settings" - and a large text scale or a
                // narrow phone must ellipsise rather than overflow the button.
                Flexible(
                  child: Text(
                    label,
                    style: AppText.buttonLabel,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// An outlined, quiet button - the mock's "Export diagnostics".
class QuietButton extends StatelessWidget {
  const QuietButton({
    required this.label,
    required this.onPressed,
    this.height = 46,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      container: true,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Container(
          height: math.max(height, AppShape.minTapTarget),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.border),
            borderRadius: AppShape.control,
          ),
          alignment: Alignment.center,
          child: Text(label, style: AppText.buttonLabelQuiet),
        ),
      ),
    );
  }
}

/// The small state dot that precedes "Connected" / "Recording".
class StatusDot extends StatelessWidget {
  const StatusDot({required this.color, this.size = 6, super.key});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// `.card` from the mock: #14121B on a #1D1927 hairline, 16px radius.
class AppCard extends StatelessWidget {
  const AppCard({
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.borderColor = AppColors.raised,
    super.key,
  });

  final Widget child;
  final EdgeInsets padding;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        border: Border.all(color: borderColor),
        borderRadius: AppShape.card,
      ),
      padding: padding,
      child: child,
    );
  }
}

/// `.cap` - a tracked, uppercase section label.
class SectionCaption extends StatelessWidget {
  const SectionCaption(this.text, {this.small = false, super.key});

  final String text;
  final bool small;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: small ? AppText.captionSmall : AppText.caption,
    );
  }
}

/// A label/value line inside a Developer card.
class KeyValueRow extends StatelessWidget {
  const KeyValueRow({
    required this.label,
    required this.value,
    this.valueColor = AppColors.textPrimary,
    super.key,
  });

  final String label;
  final String value;
  final Color valueColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: <Widget>[
        Expanded(
          child: Text(
            label,
            style: AppText.devLabel,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 12),
        Text(value, style: AppText.devValue.copyWith(color: valueColor)),
      ],
    );
  }
}


/// The app's ONE delete confirmation, so the library row and the playback
/// screen cannot drift apart in how they ask.
///
/// Returns true only on an explicit Delete. [what] is the recording's name -
/// naming it is the point of the dialog, because the alternative is asking
/// "delete this?" about a row the user may have mis-tapped - and [detail] is
/// the day and length that confirm it is the right one.
///
/// Destructive-red on the confirming action, from [AppColors.error]; Cancel is
/// the quiet one and is what a dismissal returns.
Future<bool> confirmDeleteRecording(
  BuildContext context, {
  required String what,
  required String detail,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(borderRadius: AppShape.card),
      title: const Text('Delete recording?', style: AppText.title22),
      content: Text(
        'Delete \u201C$what\u201D ($detail)? This cannot be undone.',
        style: AppText.footnote12,
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel', style: AppText.label13),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(
            'Delete',
            style: AppText.label13.copyWith(color: AppColors.error),
          ),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
