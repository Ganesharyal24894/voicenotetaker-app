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
      // THE TAP ACTION HAS TO BE DECLARED HERE. `excludeSemantics` below drops
      // the descendants' semantics, and the [GestureDetector]'s tap action is
      // one of them - so without this the node is a button a screen reader can
      // read out and cannot activate. Every small control in the app goes
      // through this widget, so it is declared once, here.
      onTap: onTap,
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


/// One segment of a two-way (or four-way) selector - the codec pick, the
/// auto-sleep flag, the samples-per-check count.
///
/// Selected: purple fill with LIGHT text, per the contrast rule in `theme.dart`.
///
/// [enabled] false dims the segment and takes its tap away, which is how a
/// control with nothing truthful behind it is shown: present, and visibly not
/// answerable. That is the same three-state discipline `AppController` uses for
/// auto-sleep and the battery, and it is why this is a shared widget rather than
/// one each for the diagnostics and developer screens.
class SegmentButton extends StatelessWidget {
  const SegmentButton({
    required this.label,
    required this.selected,
    required this.onTap,
    this.semanticLabel,
    this.enabled = true,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// Read out instead of [label] when the visible word is too short to say
  /// what it does on its own - "On" means nothing without "Auto-sleep".
  final String? semanticLabel;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: enabled,
      selected: selected,
      label: semanticLabel ?? label,
      container: true,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.45,
          child: SizedBox(
            height: AppShape.minTapTarget,
            child: Center(
              child: Container(
                height: 38,
                decoration: BoxDecoration(
                  color: selected ? AppColors.primaryFill : null,
                  border:
                      selected ? null : Border.all(color: AppColors.border),
                  borderRadius: AppShape.segment,
                ),
                alignment: Alignment.center,
                child: Text(
                  label,
                  style: selected
                      ? AppText.devValue.copyWith(
                          fontWeight: FontWeight.w500,
                          color: AppColors.onPrimaryFill,
                        )
                      : AppText.devLabel.copyWith(
                          fontWeight: FontWeight.w400,
                          color: AppColors.textSecondary,
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}


/// The circled i beside a heading: one tap for a longer explanation, one tap to
/// put it away.
///
/// A FLOATING SHEET RATHER THAN AN EXPANDING ROW, and that is the point of the
/// design. Every card on Diagnostics is live - the signal, the counters and the
/// temperature all move while somebody is reading them - so an explanation that
/// grew inside the card would shove the readings down the page, and on a 390px
/// screen the ones somebody opened the screen for would leave it. This floats
/// above instead: nothing moves, and when it closes every figure is where it
/// was.
///
/// REACHABLE AND DISMISSIBLE WITHOUT SIGHT. [TapTarget] gives it the 44px hit
/// area and the spoken label; the dialog is a route, so a screen reader moves
/// into it and announces it, the barrier is labelled, tapping outside it or the
/// system back gesture closes it, and Close is a real focusable button rather
/// than a swipe nobody can find.
class InfoButton extends StatelessWidget {
  const InfoButton({required this.title, required this.body, super.key});

  /// The heading this explains, used as the sheet's title and read out as
  /// "About the signal".
  final String title;

  /// Two or three plain sentences: what to do, and what an unusual reading
  /// might mean. No jargon - moving jargon behind a tap does not fix it.
  final String body;

  @override
  Widget build(BuildContext context) {
    return TapTarget(
      onTap: () {
        // Nothing is awaited: the sheet's only outcome is being closed.
        showInfoSheet(context, title: title, body: body);
      },
      semanticLabel: 'About $title',
      child: const AppIcon(
        AppGlyph.info,
        size: 17,
        color: AppColors.textSecondary,
        strokeWidth: 1.6,
      ),
    );
  }
}

/// The sheet [InfoButton] opens. Separate so a screen can explain something
/// from a control that is not a circled i.
///
/// Scrollable content, because these run to three sentences and a phone at a
/// large text scale has less room than this reads like it needs.
Future<void> showInfoSheet(
  BuildContext context, {
  required String title,
  required String body,
}) {
  return showDialog<void>(
    context: context,
    barrierLabel: '$title, more detail',
    builder: (context) => AlertDialog(
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(borderRadius: AppShape.card),
      title: Text(title, style: AppText.title22),
      content: SingleChildScrollView(
        child: Text(body, style: AppText.footnote12),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close', style: AppText.label13),
        ),
      ],
    ),
  );
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
