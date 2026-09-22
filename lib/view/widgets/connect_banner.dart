import 'package:flutter/widgets.dart';

import '../../controller/app_controller.dart';
import '../../model/notes_saving.dart';
import '../theme.dart';
import 'notice_card.dart';

/// Today, with always listening on and no recorder: the privacy card's shape
/// with an amber edge, and a button to the scan screen. From
/// `canvas-connect/` (option A).
///
/// The header already says notes are not being saved; this is the way to do
/// something about it, which used to be two screens away in Settings.
///
/// IT SHOWS THROUGH RECONNECTING. Always listening retries on its own for as
/// long as there is no link - at once, then backing off to once a minute - so
/// "reconnecting" is not a separate state that ends: hiding the card for it
/// would hide it for good. An attempt in flight lasts seconds and comes back
/// every minute, and hiding the card for those would only make it blink.
class ConnectBanner extends StatelessWidget {
  const ConnectBanner({required this.controller, this.onConnect, super.key});

  final AppController controller;

  /// Opens the scan screen over Home. Null hides the card.
  final VoidCallback? onConnect;

  static const String disconnectedTitle = "Your recorder isn't connected";
  static const String disconnectedMeta = "Nothing is saved until it's back";
  static const String connect = 'Connect';

  static const String oldPairingTitle = 'Pair your recorder again';
  static const String oldPairingMeta = "This phone's old pairing no longer works";
  static const String fix = 'Fix';

  static const String pairedToAnotherTitle = 'Paired to another phone';
  static const String pairedToAnotherMeta =
      'Pair it with this phone to save notes here';
  static const String pair = 'Pair';

  @override
  Widget build(BuildContext context) {
    final onConnect = this.onConnect;
    final notice = switch (controller.notesSaving) {
      NotesSaving.disconnected =>
        (disconnectedTitle, disconnectedMeta, connect, const _Glyph(_linkOff)),
      NotesSaving.oldPairing =>
        (oldPairingTitle, oldPairingMeta, fix, const _Glyph(_key)),
      NotesSaving.pairedToAnother =>
        (pairedToAnotherTitle, pairedToAnotherMeta, pair, const _Glyph(_key)),
      _ => null,
    };
    if (onConnect == null || notice == null) return const SizedBox.shrink();
    final (title, meta, action, icon) = notice;
    return NoticeCard(
      icon: icon,
      title: title,
      meta: meta,
      action: action,
      onAction: onConnect,
      borderColor: AppColors.warningCardBorder,
    );
  }
}

/// Two chain links with a slash through them - no link.
List<Path> _linkOff() => <Path>[
      // M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1
      Path()
        ..moveTo(10, 14)
        ..arcToPoint(const Offset(15.7, 14),
            radius: const Radius.circular(4), clockwise: false)
        ..lineTo(18.7, 11)
        ..arcToPoint(const Offset(13, 5.3),
            radius: const Radius.circular(4), clockwise: false)
        ..lineTo(12, 6.3),
      // M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1
      Path()
        ..moveTo(14, 10)
        ..arcToPoint(const Offset(8.3, 10),
            radius: const Radius.circular(4), clockwise: false)
        ..lineTo(5.3, 13)
        ..arcToPoint(const Offset(11, 18.7),
            radius: const Radius.circular(4), clockwise: false)
        ..lineTo(12, 17.7),
      // M4 4l16 16
      Path()
        ..moveTo(4, 4)
        ..lineTo(20, 20),
    ];

/// A key - the pairing between this phone and the recorder.
List<Path> _key() => <Path>[
      // circle cx=8 cy=15 r=4
      Path()..addOval(Rect.fromCircle(center: const Offset(8, 15), radius: 4)),
      // M11 12l9-9M17 6l3 3
      Path()
        ..moveTo(11, 12)
        ..lineTo(20, 3)
        ..moveTo(17, 6)
        ..lineTo(20, 9),
    ];

/// One amber stroke glyph in the app's 24-unit box and 1.7 stroke, at 22 px.
class _Glyph extends StatelessWidget {
  const _Glyph(this.paths);

  final List<Path> Function() paths;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: CustomPaint(
          size: const Size.square(22),
          painter: _GlyphPainter(paths),
        ),
      );
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter(this.paths);

  final List<Path> Function() paths;

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..save()
      ..scale(size.width / 24, size.height / 24);
    final stroke = Paint()
      ..color = AppColors.warning
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    for (final path in paths()) {
      canvas.drawPath(path, stroke);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.paths != paths;
}
