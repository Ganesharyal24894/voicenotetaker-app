import 'package:flutter/widgets.dart';

import '../theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/common.dart';

/// Small pieces of the recorder-update screens, drawn from the canvas with
/// the app's own tokens.
abstract final class UpdateText {
  /// 14px / 400 primary - a check or a card's lead line.
  static final TextStyle item = AppText.rowTitle.copyWith(fontSize: 14);

  /// 14px / 300 primary at 1.5 - the release notes.
  static final TextStyle notes =
      AppText.meta14.copyWith(color: AppColors.textPrimary, height: 1.5);

  /// 13px / 300 secondary at 1.55 - the paragraphs under a section.
  static final TextStyle paragraph = AppText.body13.copyWith(height: 1.55);
}

/// The back chevron (or the empty space where it would be), the title and the
/// line under it.
class UpdateHeader extends StatelessWidget {
  const UpdateHeader({
    required this.title,
    this.subtitle,
    this.onBack,
    this.gapBelow = 24,
    super.key,
  });

  final String title;
  final String? subtitle;
  final VoidCallback? onBack;
  final double gapBelow;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (onBack != null)
          Transform.translate(
            offset: const Offset(-12, 0),
            child: TapTarget(
              onTap: onBack,
              semanticLabel: 'Back',
              child: const AppIcon(AppGlyph.chevronLeft,
                  size: 20, color: AppColors.textSecondary, strokeWidth: 1.7),
            ),
          )
        else
          const SizedBox(height: AppShape.minTapTarget),
        Text(title, style: AppText.title22),
        if (subtitle != null) ...<Widget>[
          const SizedBox(height: 6),
          Text(subtitle!, style: AppText.body13),
        ],
        SizedBox(height: gapBelow),
      ],
    );
  }
}

/// The 52px pill at the foot of each screen. Disabled, it goes quiet - a
/// raised fill and tertiary text - rather than fading the purple.
class UpdateButton extends StatelessWidget {
  const UpdateButton({required this.label, required this.onPressed, super.key});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      onTap: onPressed,
      container: true,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Container(
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: enabled ? AppColors.primaryFill : AppColors.raised,
            borderRadius: const BorderRadius.all(Radius.circular(26)),
          ),
          child: Text(
            label,
            style: enabled
                ? AppText.buttonLabel
                : AppText.buttonLabel.copyWith(color: AppColors.textTertiary),
          ),
        ),
      ),
    );
  }
}

/// "Not now", "Later": a quiet 48px text button under the pill.
class UpdateTextButton extends StatelessWidget {
  const UpdateTextButton({required this.label, required this.onPressed, super.key});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      onTap: onPressed,
      container: true,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Container(
          height: 48,
          alignment: Alignment.center,
          child: Text(label, style: AppText.buttonLabelQuiet),
        ),
      ),
    );
  }
}

/// A "Before you start" check: a green tick when it is met, an amber ring and
/// what to do about it when it is not.
class CheckRow extends StatelessWidget {
  const CheckRow({required this.met, required this.title, this.why, super.key});

  final bool met;
  final String title;
  final String? why;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: <Widget>[
          if (met)
            const Tick(size: 20)
          else
            const Ring(size: 20, color: AppColors.warning),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: UpdateText.item),
                if (!met && why != null) ...<Widget>[
                  const SizedBox(height: 3),
                  Text(why!,
                      style: AppText.rowMeta.copyWith(color: AppColors.textSecondary)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

enum StepMark { done, active, pending }

/// One line of "What's happening", with a hairline above it.
class StepRow extends StatelessWidget {
  const StepRow({required this.label, required this.mark, super.key});

  final String label;
  final StepMark mark;

  @override
  Widget build(BuildContext context) {
    final (Widget icon, TextStyle style) = switch (mark) {
      StepMark.done => (
          const Tick(size: 18),
          UpdateText.item.copyWith(
              fontWeight: FontWeight.w300, color: AppColors.textSecondary),
        ),
      StepMark.active => (
          const Ring(size: 18, color: AppColors.purpleText),
          UpdateText.item,
        ),
      StepMark.pending => (
          const Ring(size: 18, color: AppColors.border),
          UpdateText.item.copyWith(
              fontWeight: FontWeight.w300, color: AppColors.textTertiary),
        ),
    };
    return Semantics(
      label: '$label, ${mark.name}',
      container: true,
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.raised)),
        ),
        child: Row(
          children: <Widget>[
            icon,
            const SizedBox(width: 12),
            Expanded(child: Text(label, style: style)),
          ],
        ),
      ),
    );
  }
}

/// An open circle, 1.5px stroke - a check not yet met, a step not yet done.
class Ring extends StatelessWidget {
  const Ring({required this.size, required this.color, super.key});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: color, width: 1.5),
        ),
      );
}

/// The canvas's green tick, `M5 12l4 4 10-10` at a 1.8 stroke.
class Tick extends StatelessWidget {
  const Tick({required this.size, super.key});

  final double size;

  @override
  Widget build(BuildContext context) => StrokeGlyph(
        size: size,
        color: AppColors.connected,
        strokeWidth: 1.8,
        paths: _tick,
      );

  static List<Path> _tick() => <Path>[
        Path()
          ..moveTo(5, 12)
          ..lineTo(9, 16)
          ..lineTo(19, 6),
      ];
}

/// An arrow up out of a tray - the Today row's glyph.
List<Path> updateGlyph() => <Path>[
      Path()
        ..moveTo(12, 16)
        ..lineTo(12, 4),
      Path()
        ..moveTo(7, 9)
        ..lineTo(12, 4)
        ..lineTo(17, 9),
      Path()
        ..moveTo(4, 16)
        ..lineTo(4, 19)
        ..arcToPoint(const Offset(5, 20), radius: const Radius.circular(1), clockwise: false)
        ..lineTo(19, 20)
        ..arcToPoint(const Offset(20, 19), radius: const Radius.circular(1), clockwise: false)
        ..lineTo(20, 16),
    ];

/// Stroke paths in the app's 24-unit box, round caps and joins.
class StrokeGlyph extends StatelessWidget {
  const StrokeGlyph({
    required this.size,
    required this.color,
    required this.paths,
    this.strokeWidth = 1.7,
    super.key,
  });

  final double size;
  final Color color;
  final double strokeWidth;
  final List<Path> Function() paths;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: CustomPaint(
          size: Size.square(size),
          painter: _StrokePainter(paths, color, strokeWidth),
        ),
      );
}

class _StrokePainter extends CustomPainter {
  const _StrokePainter(this.paths, this.color, this.strokeWidth);

  final List<Path> Function() paths;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..save()
      ..scale(size.width / 24, size.height / 24);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    for (final path in paths()) {
      canvas.drawPath(path, stroke);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_StrokePainter old) =>
      old.paths != paths || old.color != color || old.strokeWidth != strokeWidth;
}
