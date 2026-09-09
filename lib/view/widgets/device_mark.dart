import 'package:flutter/widgets.dart';

import '../theme.dart';

/// The recorder board, drawn as a vector.
///
/// This is the `#board` symbol from `design/DeviceMotion.dc.html`, ported by
/// hand into a [CustomPainter] in the same `0 0 100 122` view box. It is not
/// an SVG asset and no SVG package is involved: the artwork is a couple of
/// dozen rectangles, and hand-writing them keeps the app's dependency list
/// where it is.
///
/// It is the app's device logo. It sits in the Home header's 38x46 leading
/// slot for as long as a recorder is paired, and it is the [Hero] that flies
/// there from the scan screen when you connect - which is why the mark is a
/// single reusable widget rather than something each screen draws itself.
class DeviceMark extends StatelessWidget {
  const DeviceMark({
    this.width = slotWidth,
    this.dimmed = false,
    this.semanticLabel,
    super.key,
  });

  /// The Home header slot, from `design/DeviceMotion.dc.html`: 38x46.
  static const double slotWidth = 38;
  static const double slotHeight = 46;

  /// The size the mark is drawn at on the scan screen, before it docks.
  ///
  /// The design's dock animation shows the board flying in and SHRINKING to
  /// 38 px, so it has to start larger than the slot; it cannot start at 38 and
  /// shrink to 38. The mock's stage width (100 px) is a canvas illustration
  /// rather than a phone, and would dwarf the card it sits in - this is the
  /// same proportions at a size the device card can hold.
  static const double foundWidth = 60;

  /// The symbol's view box, and therefore the mark's aspect ratio.
  static const double viewBoxWidth = 100;
  static const double viewBoxHeight = 122;

  /// Opacity of the disconnected treatment. The mark stays in the layout at
  /// the same size so nothing jumps between states; it just recedes.
  static const double dimmedOpacity = 0.4;

  /// Rendered width. The height follows from the slot's proportions, so the
  /// mark is the same shape wherever it is drawn.
  final double width;

  /// Draw the disconnected treatment - the same mark, at [dimmedOpacity].
  final bool dimmed;

  final String? semanticLabel;

  /// The design states the slot as 38x46 while the symbol's view box is
  /// 100x122 - a 0.8% difference, which the design's own SVG resolves by
  /// setting width and height directly. This does the same.
  double get height => width * slotHeight / slotWidth;

  @override
  Widget build(BuildContext context) {
    Widget mark = SizedBox(
      width: width,
      height: height,
      child: CustomPaint(
        painter: const _BoardPainter(),
        size: Size(width, height),
      ),
    );
    if (dimmed) {
      mark = Opacity(opacity: dimmedOpacity, child: mark);
    }
    if (semanticLabel != null) {
      mark = Semantics(
        label: semanticLabel,
        image: true,
        container: true,
        child: mark,
      );
    }
    return mark;
  }
}

/// Every shape in the `#board` symbol, in view-box units.
class _BoardPainter extends CustomPainter {
  const _BoardPainter();

  /// The six castellated pad positions down each edge.
  static const List<double> _padTops = <double>[24, 38, 52, 66, 80, 94];

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(
      size.width / DeviceMark.viewBoxWidth,
      size.height / DeviceMark.viewBoxHeight,
    );

    // The PCB itself: a diagonal gradient, `url(#pcb)`.
    const boardRect = Rect.fromLTWH(4, 4, 92, 114);
    canvas.drawRRect(
      RRect.fromRectAndRadius(boardRect, const Radius.circular(9)),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[AppColors.boardTop, AppColors.boardBottom],
        ).createShader(boardRect)
        ..isAntiAlias = true,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(boardRect, const Radius.circular(9)),
      Paint()
        ..color = AppColors.boardEdge
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..isAntiAlias = true,
    );

    // The USB receptacle overhanging the top edge.
    _fillRRect(canvas, 36, 1, 28, 9, 4, AppColors.boardMetal);
    _fillRRect(canvas, 39, 3.4, 22, 4, 2, AppColors.boardSlot);

    // Gold castellations down both edges.
    final gold = Paint()
      ..color = AppColors.boardGold
      ..isAntiAlias = true;
    for (final top in _padTops) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(1.5, top, 7, 7),
          const Radius.circular(1.6),
        ),
        gold,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(91.5, top, 7, 7),
          const Radius.circular(1.6),
        ),
        gold,
      );
    }

    // The RF shield can, `url(#shield)` - a vertical gradient.
    const shieldRect = Rect.fromLTWH(24, 30, 52, 46);
    canvas.drawRRect(
      RRect.fromRectAndRadius(shieldRect, const Radius.circular(4)),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            AppColors.boardShieldTop,
            AppColors.boardShieldBottom,
          ],
        ).createShader(shieldRect)
        ..isAntiAlias = true,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(shieldRect, const Radius.circular(4)),
      Paint()
        ..color = AppColors.boardShieldEdge
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..isAntiAlias = true,
    );

    // Two etched lines on the can.
    _fillRRect(
      canvas, 30, 36, 40, 3, 1.5,
      AppColors.boardMetal.withValues(alpha: 0.5),
    );
    _fillRRect(
      canvas, 30, 43, 26, 3, 1.5,
      AppColors.boardMetal.withValues(alpha: 0.35),
    );

    // The antenna trace, ending at the purple feed point.
    canvas.drawPath(
      Path()
        ..moveTo(28, 86)
        ..lineTo(72, 86)
        ..lineTo(72, 96)
        ..lineTo(62, 96),
      Paint()
        ..color = AppColors.boardGold
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true,
    );
    canvas.drawCircle(
      const Offset(72, 86),
      6.5,
      Paint()
        ..color = AppColors.purple500.withValues(alpha: 0.22)
        ..isAntiAlias = true,
    );
    canvas.drawCircle(
      const Offset(72, 86),
      3.6,
      Paint()
        ..color = AppColors.purple500
        ..isAntiAlias = true,
    );

    // The button on the lower left.
    _fillRRect(canvas, 18, 100, 9, 7, 2, AppColors.boardEdge);

    canvas.restore();
  }

  static void _fillRRect(
    Canvas canvas,
    double left,
    double top,
    double width,
    double height,
    double radius,
    Color color,
  ) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(left, top, width, height),
        Radius.circular(radius),
      ),
      Paint()
        ..color = color
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(_BoardPainter oldDelegate) => false;
}
