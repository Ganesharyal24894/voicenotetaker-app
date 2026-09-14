import 'package:flutter/material.dart';

/// The glyphs the two Home tabs and the Summarize sheets add, transcribed from
/// the SVGs in the approved canvas in the same 24x24 view box as `AppIcon`.
///
/// A SEPARATE ENUM rather than more `AppGlyph` cases so the home redesign and
/// other screens being built at the same time never edit the same lines.
enum HomeGlyph {
  /// Rounded square with a tick - the Today tab.
  todaySquare,

  /// Three ragged lines - the Notes tab and "Summarize with your AI".
  lines,

  /// Two overlapping rounded squares - copy / paste.
  copy,

  /// Arrow up out of a tray - share.
  share,

  /// Circle with a tick - "from your AI", "Copied".
  checkCircle,

  /// A bare tick - inside a ticked checkbox.
  check,
}

class HomeIcon extends StatelessWidget {
  const HomeIcon(
    this.glyph, {
    required this.size,
    required this.color,
    this.strokeWidth = 1.7,
    super.key,
  });

  final HomeGlyph glyph;
  final double size;
  final Color color;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _HomeGlyphPainter(glyph, color, strokeWidth),
        ),
      );
}

class _HomeGlyphPainter extends CustomPainter {
  const _HomeGlyphPainter(this.glyph, this.color, this.strokeWidth);

  final HomeGlyph glyph;
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
    for (final path in _paths(glyph)) {
      canvas.drawPath(path, stroke);
    }
    canvas.restore();
  }

  static Path _tick(double x1, double y1, double x2, double y2, double x3, double y3) =>
      Path()
        ..moveTo(x1, y1)
        ..lineTo(x2, y2)
        ..lineTo(x3, y3);

  static List<Path> _paths(HomeGlyph glyph) {
    switch (glyph) {
      case HomeGlyph.todaySquare:
        return <Path>[
          Path()
            ..addRRect(RRect.fromRectAndRadius(
              const Rect.fromLTWH(3.5, 3.5, 17, 17),
              const Radius.circular(4),
            )),
          _tick(8, 12.3, 11, 15.3, 16.3, 9.3),
        ];
      case HomeGlyph.lines:
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
      case HomeGlyph.copy:
        return <Path>[
          Path()
            ..addRRect(RRect.fromRectAndRadius(
              const Rect.fromLTWH(8.5, 8.5, 12, 12),
              const Radius.circular(2.5),
            )),
          // M15.5 8.5V6a2.5 2.5 0 0 0-2.5-2.5H6A2.5 2.5 0 0 0 3.5 6v7A2.5 2.5 0 0 0 6 15.5h2.5
          Path()
            ..moveTo(15.5, 8.5)
            ..lineTo(15.5, 6)
            ..arcToPoint(const Offset(13, 3.5), radius: const Radius.circular(2.5), clockwise: false)
            ..lineTo(6, 3.5)
            ..arcToPoint(const Offset(3.5, 6), radius: const Radius.circular(2.5), clockwise: false)
            ..lineTo(3.5, 13)
            ..arcToPoint(const Offset(6, 15.5), radius: const Radius.circular(2.5), clockwise: false)
            ..lineTo(8.5, 15.5),
        ];
      case HomeGlyph.share:
        return <Path>[
          Path()
            ..moveTo(12, 3.5)
            ..lineTo(12, 14.5),
          _tick(7.5, 8, 12, 3.5, 16.5, 8),
          // M5 12.5v5a3 3 0 0 0 3 3h8a3 3 0 0 0 3-3v-5
          Path()
            ..moveTo(5, 12.5)
            ..lineTo(5, 17.5)
            ..arcToPoint(const Offset(8, 20.5), radius: const Radius.circular(3), clockwise: false)
            ..lineTo(16, 20.5)
            ..arcToPoint(const Offset(19, 17.5), radius: const Radius.circular(3), clockwise: false)
            ..lineTo(19, 12.5),
        ];
      case HomeGlyph.checkCircle:
        return <Path>[
          Path()..addOval(Rect.fromCircle(center: const Offset(12, 12), radius: 8.75)),
          _tick(8, 12.3, 11, 15.3, 16.3, 9.3),
        ];
      case HomeGlyph.check:
        return <Path>[_tick(5, 12.5, 10, 17.5, 19, 7)];
    }
  }

  @override
  bool shouldRepaint(_HomeGlyphPainter old) =>
      old.glyph != glyph || old.color != color || old.strokeWidth != strokeWidth;
}
