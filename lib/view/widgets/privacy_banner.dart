import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../controller/app_controller.dart';
import '../../model/notes_saving.dart';
import '../theme.dart';
import 'common.dart';

/// Today, in privacy mode: one card under the header saying the recorder is
/// not listening, with Resume. From `canvas-privacy/Main.dc.html`.
///
/// It follows the RECORDER, not the tap: it shows while the recorder reports
/// privacy mode on `fe08`, and Resume only asks - the card goes when the
/// recorder says it has resumed. Nothing shows on an ordinary day.
class PrivacyBanner extends StatelessWidget {
  const PrivacyBanner({required this.controller, super.key});

  final AppController controller;

  static const String title = "Your recorder isn't listening";
  static const String meta = 'Nothing is saved until you resume';
  static const String resume = 'Resume';

  @override
  Widget build(BuildContext context) {
    if (controller.notesSaving != NotesSaving.privacyMode) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppShape.gutter, 0, AppShape.gutter, 14),
      child: AppCard(
        borderColor: AppColors.purpleChipBorder,
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        child: Row(
          children: <Widget>[
            const ShieldIcon(),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(title, style: AppText.rowTitle),
                  const SizedBox(height: 3),
                  Text(
                    meta,
                    style: AppText.rowMeta.copyWith(color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            _ResumeButton(
              onTap: () => unawaited(controller.turnPrivacyModeOff()),
            ),
          ],
        ),
      ),
    );
  }
}

/// A 44 px primary pill that sizes to its label.
class _ResumeButton extends StatelessWidget {
  const _ResumeButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: PrivacyBanner.resume,
      onTap: onTap,
      container: true,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          height: AppShape.minTapTarget,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            color: AppColors.primaryFill,
            borderRadius: BorderRadius.all(Radius.circular(22)),
          ),
          child: Text(
            PrivacyBanner.resume,
            style: AppText.buttonLabel.copyWith(fontSize: 14),
          ),
        ),
      ),
    );
  }
}

/// A shield with a tick, in the app's 24-unit box and 1.7 stroke.
class ShieldIcon extends StatelessWidget {
  const ShieldIcon({super.key, this.size = 22, this.color = AppColors.purple400});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: CustomPaint(size: Size.square(size), painter: _ShieldPainter(color)),
      );
}

class _ShieldPainter extends CustomPainter {
  const _ShieldPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..save()
      ..scale(size.width / 24, size.height / 24);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    // M12 3l7 3v5c0 4.5-3 8.5-7 10-4-1.5-7-5.5-7-10V6l7-3z
    canvas.drawPath(
      Path()
        ..moveTo(12, 3)
        ..lineTo(19, 6)
        ..lineTo(19, 11)
        ..cubicTo(19, 15.5, 16, 19.5, 12, 21)
        ..cubicTo(8, 19.5, 5, 15.5, 5, 11)
        ..lineTo(5, 6)
        ..close(),
      stroke,
    );
    // M9.5 12l2 2 3.5-3.5
    canvas
      ..drawPath(
        Path()
          ..moveTo(9.5, 12)
          ..lineTo(11.5, 14)
          ..lineTo(15, 10.5),
        stroke,
      )
      ..restore();
  }

  @override
  bool shouldRepaint(_ShieldPainter old) => old.color != color;
}
