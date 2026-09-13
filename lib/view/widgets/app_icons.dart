import 'package:flutter/widgets.dart';

import '../theme.dart';

/// Which glyph an [AppIcon] draws.
///
/// Every glyph is transcribed from the inline SVG in `design/Main.dc.html`,
/// in the same 24x24 view box, so the stroke weight is consistent across the
/// whole app no matter what size an icon is rendered at. No icon font, no
/// emoji, no raster assets.
enum AppGlyph {
  /// The Bluetooth rune on the device cards.
  bluetooth,

  /// Microphone - the record button and the "New recording" call to action.
  mic,

  /// Solid play triangle in the recent-recordings rows.
  play,

  chevronLeft,
  chevronRight,

  /// Magnifier in the library search field.
  search,

  /// Vertical overflow dots.
  more,

  /// Skip backwards (counter-clockwise arrow).
  skipBack,

  /// Skip forwards (clockwise arrow).
  skipForward,

  /// Three ragged lines - the Transcribe chip.
  transcribe,

  /// Circular arrow with a head - the scan control's refresh glyph.
  refresh,

  /// Waste bin - deleting a recording.
  trash,

  // ---------------------------------------------------------------------
  // The edge states, transcribed from `design/edge-states/*.dc.html` in the
  // same 24x24 view box as everything above.
  // ---------------------------------------------------------------------

  /// The Bluetooth rune struck through - the adapter is off.
  bluetoothOff,

  /// Padlock - a permission the app has not been granted.
  lock,

  /// Circle with a diagonal - this phone cannot do it at all.
  circleSlash,

  /// Concentric arcs radiating from a dot - listening, and nothing answered.
  broadcast,

  /// Two chain ends pulled apart - the handshake did not complete.
  linkBroken,

  /// Signal arcs with a cross where the bars would be - the link dropped.
  signalLost,

  /// Five bars of a level meter - recordings, and the invitation to make one.
  levels,
}

/// A stroke-based vector icon drawn with a [CustomPainter].
class AppIcon extends StatelessWidget {
  const AppIcon(
    this.glyph, {
    required this.size,
    required this.color,
    this.strokeWidth = 1.6,
    super.key,
  });

  final AppGlyph glyph;

  /// Rendered edge length in logical pixels.
  final double size;

  final Color color;

  /// Stroke weight in view-box units, exactly as the mock's SVG expresses it;
  /// it is scaled with the glyph so a 19px icon keeps the mock's proportions.
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _GlyphPainter(
          glyph: glyph,
          color: color,
          strokeWidth: strokeWidth,
        ),
        size: Size.square(size),
      ),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter({
    required this.glyph,
    required this.color,
    required this.strokeWidth,
  });

  final AppGlyph glyph;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);

    if (glyph == AppGlyph.play) {
      final fill = Paint()
        ..color = color
        ..style = PaintingStyle.fill
        ..isAntiAlias = true;
      canvas.drawPath(
        Path()
          ..moveTo(6, 4)
          ..lineTo(20, 12)
          ..lineTo(6, 20)
          ..close(),
        fill,
      );
      canvas.restore();
      return;
    }

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    for (final path in _pathsFor(glyph)) {
      canvas.drawPath(path, stroke);
    }
    canvas.restore();
  }

  static List<Path> _pathsFor(AppGlyph glyph) {
    switch (glyph) {
      case AppGlyph.bluetooth:
        return <Path>[
          Path()
            ..moveTo(6.5, 6.5)
            ..lineTo(17.5, 17.5)
            ..lineTo(12, 23)
            ..lineTo(12, 1)
            ..lineTo(17.5, 6.5)
            ..lineTo(6.5, 17.5),
        ];
      case AppGlyph.mic:
        return <Path>[
          // Capsule: M12 2 a3 3 0 0 0 -3 3 v7 a3 3 0 0 0 6 0 V5 a3 3 0 0 0 -3 -3z
          Path()
            ..moveTo(12, 2)
            ..arcToPoint(const Offset(9, 5),
                radius: const Radius.circular(3), clockwise: false)
            ..lineTo(9, 12)
            ..arcToPoint(const Offset(15, 12),
                radius: const Radius.circular(3), clockwise: false)
            ..lineTo(15, 5)
            ..arcToPoint(const Offset(12, 2),
                radius: const Radius.circular(3), clockwise: false)
            ..close(),
          // Cradle: M19 11 v1 a7 7 0 0 1 -14 0 v-1
          Path()
            ..moveTo(19, 11)
            ..lineTo(19, 12)
            ..arcToPoint(const Offset(5, 12),
                radius: const Radius.circular(7), clockwise: true)
            ..lineTo(5, 11),
          // Stand.
          Path()
            ..moveTo(12, 19)
            ..lineTo(12, 22),
        ];
      case AppGlyph.chevronLeft:
        return <Path>[
          Path()
            ..moveTo(15, 18)
            ..lineTo(9, 12)
            ..lineTo(15, 6),
        ];
      case AppGlyph.chevronRight:
        return <Path>[
          Path()
            ..moveTo(9, 18)
            ..lineTo(15, 12)
            ..lineTo(9, 6),
        ];
      case AppGlyph.search:
        return <Path>[
          Path()
            ..addOval(Rect.fromCircle(center: const Offset(11, 11), radius: 7)),
          Path()
            ..moveTo(16.5, 16.5)
            ..lineTo(21, 21),
        ];
      case AppGlyph.more:
        return <Path>[
          Path()
            ..addOval(
                Rect.fromCircle(center: const Offset(12, 5), radius: 1.4))
            ..addOval(
                Rect.fromCircle(center: const Offset(12, 12), radius: 1.4))
            ..addOval(
                Rect.fromCircle(center: const Offset(12, 19), radius: 1.4)),
        ];
      case AppGlyph.skipBack:
        return <Path>[
          // M11 4 a8 8 0 1 1 -8 8
          Path()
            ..moveTo(11, 4)
            ..arcToPoint(
              const Offset(3, 12),
              radius: const Radius.circular(8),
              largeArc: true,
              clockwise: true,
            ),
          Path()
            ..moveTo(3, 4)
            ..lineTo(3, 9)
            ..lineTo(8, 9),
        ];
      case AppGlyph.skipForward:
        return <Path>[
          // M13 4 a8 8 0 1 0 8 8
          Path()
            ..moveTo(13, 4)
            ..arcToPoint(
              const Offset(21, 12),
              radius: const Radius.circular(8),
              largeArc: true,
              clockwise: false,
            ),
          Path()
            ..moveTo(21, 4)
            ..lineTo(21, 9)
            ..lineTo(16, 9),
        ];
      case AppGlyph.transcribe:
        return <Path>[
          Path()
            ..moveTo(4, 5)
            ..lineTo(20, 5),
          Path()
            ..moveTo(4, 12)
            ..lineTo(14, 12),
          Path()
            ..moveTo(4, 19)
            ..lineTo(17, 19),
        ];
      case AppGlyph.refresh:
        return <Path>[
          // M20.5 12 a8.5 8.5 0 1 1 -2.6 -6.1
          Path()
            ..moveTo(20.5, 12)
            ..arcToPoint(
              const Offset(17.9, 5.9),
              radius: const Radius.circular(8.5),
              largeArc: true,
              clockwise: true,
            ),
          Path()
            ..moveTo(20.5, 3.5)
            ..lineTo(20.5, 9)
            ..lineTo(15, 9),
        ];
      case AppGlyph.trash:
        return <Path>[
          // Lid, with the handle above it.
          Path()
            ..moveTo(3.5, 6.5)
            ..lineTo(20.5, 6.5),
          Path()
            ..moveTo(9.5, 6.5)
            ..lineTo(9.5, 4.5)
            ..lineTo(14.5, 4.5)
            ..lineTo(14.5, 6.5),
          // Tapered body.
          Path()
            ..moveTo(5.5, 6.5)
            ..lineTo(6.4, 19.5)
            ..lineTo(17.6, 19.5)
            ..lineTo(18.5, 6.5),
          // The two ribs.
          Path()
            ..moveTo(10.3, 10)
            ..lineTo(10.6, 16),
          Path()
            ..moveTo(13.7, 10)
            ..lineTo(13.4, 16),
        ];
      case AppGlyph.bluetoothOff:
        return <Path>[
          // M7 7l10 10-5 4V3l5 4L7 17
          Path()
            ..moveTo(7, 7)
            ..lineTo(17, 17)
            ..lineTo(12, 21)
            ..lineTo(12, 3)
            ..lineTo(17, 7)
            ..lineTo(7, 17),
          // The strike-through.
          Path()
            ..moveTo(3.5, 3.5)
            ..lineTo(20.5, 20.5),
        ];
      case AppGlyph.lock:
        return <Path>[
          Path()
            ..addRRect(
              RRect.fromRectAndRadius(
                const Rect.fromLTWH(4.5, 10.5, 15, 10.5),
                const Radius.circular(2.5),
              ),
            ),
          // Shackle: M8 10.5 V7 a4 4 0 0 1 8 0 v3.5
          Path()
            ..moveTo(8, 10.5)
            ..lineTo(8, 7)
            ..arcToPoint(
              const Offset(16, 7),
              radius: const Radius.circular(4),
              clockwise: true,
            )
            ..lineTo(16, 10.5),
        ];
      case AppGlyph.circleSlash:
        return <Path>[
          Path()
            ..addOval(
              Rect.fromCircle(center: const Offset(12, 12), radius: 8.75),
            ),
          Path()
            ..moveTo(6, 6)
            ..lineTo(18, 18),
        ];
      case AppGlyph.broadcast:
        return <Path>[
          Path()
            ..addOval(
              Rect.fromCircle(center: const Offset(12, 12), radius: 2.25),
            ),
          // M12 6.25 a5.75 5.75 0 0 1 5.75 5.75
          Path()
            ..moveTo(12, 6.25)
            ..arcToPoint(
              const Offset(17.75, 12),
              radius: const Radius.circular(5.75),
              clockwise: true,
            ),
          // M12 2.5 A9.5 9.5 0 0 1 21.5 12
          Path()
            ..moveTo(12, 2.5)
            ..arcToPoint(
              const Offset(21.5, 12),
              radius: const Radius.circular(9.5),
              clockwise: true,
            ),
        ];
      case AppGlyph.linkBroken:
        return <Path>[
          // M10.5 6.5 L8.75 4.75 a3.75 3.75 0 0 0 -5.3 5.3 L5.2 11.8
          Path()
            ..moveTo(10.5, 6.5)
            ..lineTo(8.75, 4.75)
            ..arcToPoint(
              const Offset(3.45, 10.05),
              radius: const Radius.circular(3.75),
              clockwise: false,
            )
            ..lineTo(5.2, 11.8),
          // M13.5 17.5 l1.75 1.75 a3.75 3.75 0 0 0 5.3 -5.3 L18.8 12.2
          Path()
            ..moveTo(13.5, 17.5)
            ..lineTo(15.25, 19.25)
            ..arcToPoint(
              const Offset(20.55, 13.95),
              radius: const Radius.circular(3.75),
              clockwise: false,
            )
            ..lineTo(18.8, 12.2),
          // The break itself.
          Path()
            ..moveTo(9.5, 14.5)
            ..lineTo(14.5, 9.5),
        ];
      case AppGlyph.signalLost:
        return <Path>[
          // M3 8.5 a14 14 0 0 1 18 0
          Path()
            ..moveTo(3, 8.5)
            ..arcToPoint(
              const Offset(21, 8.5),
              radius: const Radius.circular(14),
              clockwise: true,
            ),
          // M6.5 12.5 a9 9 0 0 1 5.5 -2
          Path()
            ..moveTo(6.5, 12.5)
            ..arcToPoint(
              const Offset(12, 10.5),
              radius: const Radius.circular(9),
              clockwise: true,
            ),
          Path()
            ..addOval(
              Rect.fromCircle(center: const Offset(12, 18), radius: 1.1),
            ),
          // The cross over the innermost arc.
          Path()
            ..moveTo(15.5, 12)
            ..lineTo(21, 17.5),
          Path()
            ..moveTo(21, 12)
            ..lineTo(15.5, 17.5),
        ];
      case AppGlyph.levels:
        return <Path>[
          Path()
            ..moveTo(4, 11)
            ..lineTo(4, 13),
          Path()
            ..moveTo(8, 8.5)
            ..lineTo(8, 15.5),
          Path()
            ..moveTo(12, 5)
            ..lineTo(12, 19),
          Path()
            ..moveTo(16, 9)
            ..lineTo(16, 15),
          Path()
            ..moveTo(20, 11.5)
            ..lineTo(20, 12.5),
        ];
      case AppGlyph.play:
        return const <Path>[];
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.glyph != glyph ||
      old.color != color ||
      old.strokeWidth != strokeWidth;
}

/// The battery glyph from the Home header: a stroked shell, a nub, and a solid
/// bar whose length tracks [level].
///
/// [level] is `0.0 .. 1.0`, or `null` when the charge is not known - there is
/// no battery service on the device yet, so `null` is the state the app is
/// actually in until one exists.
class BatteryIcon extends StatelessWidget {
  const BatteryIcon({
    required this.level,
    this.size = 18,
    this.color = AppColors.textTertiary,
    super.key,
  });

  final double? level;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _BatteryPainter(level: level, color: color),
        size: Size.square(size),
      ),
    );
  }
}

class _BatteryPainter extends CustomPainter {
  const _BatteryPainter({required this.level, required this.color});

  final double? level;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(1, 7, 17, 10),
        const Radius.circular(2.5),
      ),
      stroke,
    );
    canvas.drawLine(const Offset(21.5, 10.5), const Offset(21.5, 13.5), stroke);

    final charge = level;
    if (charge != null && charge > 0) {
      // Inner track runs 3.5 .. 15.5 in view-box units.
      final width = 12.0 * charge.clamp(0.0, 1.0);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(3.5, 9.5, width, 5),
          const Radius.circular(1),
        ),
        Paint()
          ..color = color
          ..style = PaintingStyle.fill
          ..isAntiAlias = true,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BatteryPainter old) =>
      old.level != level || old.color != color;
}
