import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../theme.dart';
import 'app_icons.dart';

/// The dead-centre scan control on screen 1.
///
/// It replaces the ~13 px spinner and its small "Tap to scan" label, which
/// were too small to hit: this is a 96 px purple disc inside a 116 px ripple
/// area, and the whole 116 px is the hit target - well past the 44 px floor,
/// and past the 96 px the design asks for.
///
/// THE CONTRAST RULE: the glyph on the #6D28D9 fill is LIGHT
/// ([AppColors.onPrimaryFill]). A dark glyph here measures 2.78:1 and fails.
///
/// While a scan is running the glyph turns once every 1.6 s and two rings
/// ripple outward on a 2.4 s cycle, the second half a cycle behind the first.
/// That loop is one of only two in the app, and it is here because it reports
/// a live condition: the radio is listening right now. Idle, everything is
/// still.
///
/// REDUCE MOTION: with [AppMotion.isReduced] set, neither controller is ever
/// started - the glyph does not turn and the rings are drawn at rest.
class ScanControl extends StatefulWidget {
  const ScanControl({
    required this.scanning,
    required this.onTap,
    super.key,
  });

  /// True while the radio is scanning.
  final bool scanning;

  final VoidCallback? onTap;

  /// The purple disc.
  static const double discSize = 96;

  /// The ripple area, and the control's hit target.
  static const double rippleSize = 116;

  /// The refresh glyph on the disc.
  static const double glyphSize = 34;

  @override
  State<ScanControl> createState() => _ScanControlState();
}

class _ScanControlState extends State<ScanControl>
    with TickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: AppMotion.scanSpin,
  );

  late final AnimationController _ripple = AnimationController(
    vsync: this,
    duration: AppMotion.scanRipple,
  );

  bool _reduced = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = AppMotion.isReduced(context);
    _sync();
  }

  @override
  void didUpdateWidget(ScanControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final shouldRun = widget.scanning && !_reduced;
    if (shouldRun == _spin.isAnimating) return;
    if (shouldRun) {
      _spin.repeat();
      _ripple.repeat();
    } else {
      _spin
        ..stop()
        ..value = 0;
      _ripple
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    _ripple.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: widget.onTap != null,
      label: widget.scanning ? 'Stop scanning' : 'Scan for devices',
      container: true,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: SizedBox(
          width: ScanControl.rippleSize,
          height: ScanControl.rippleSize,
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              // The rings travel outside the 116px box; CustomPaint does not
              // clip, so they are not cut off, and the hit target stays 116.
              Positioned.fill(
                child: RepaintBoundary(
                  child: AnimatedBuilder(
                    animation: _ripple,
                    builder: (context, _) => CustomPaint(
                      painter: _RipplePainter(
                        phase: widget.scanning ? _ripple.value : null,
                      ),
                    ),
                  ),
                ),
              ),
              Container(
                width: ScanControl.discSize,
                height: ScanControl.discSize,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.primaryFill,
                ),
                alignment: Alignment.center,
                child: RotationTransition(
                  turns: _spin,
                  child: const AppIcon(
                    AppGlyph.refresh,
                    size: ScanControl.glyphSize,
                    color: AppColors.onPrimaryFill,
                    strokeWidth: 1.8,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Two rings travelling out from the control on a 2.4 s cycle, the second
/// half a cycle behind the first.
class _RipplePainter extends CustomPainter {
  const _RipplePainter({required this.phase});

  /// Position in the cycle, `0.0 .. 1.0`, or null when the control is idle
  /// and nothing should be drawn at all.
  final double? phase;

  @override
  void paint(Canvas canvas, Size size) {
    final at = phase;
    if (at == null) return;
    final centre = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2;

    for (final offset in const <double>[0, 0.5]) {
      final t = (at + offset) % 1.0;
      final scale = 1 + (AppMotion.scanRippleScale - 1) * Curves.easeOut.transform(t);
      final opacity = AppMotion.scanRippleOpacity * (1 - t);
      canvas.drawCircle(
        centre,
        radius * scale,
        Paint()
          ..color = AppColors.scanRipple.withValues(alpha: opacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..isAntiAlias = true,
      );
    }
  }

  @override
  bool shouldRepaint(_RipplePainter oldDelegate) => oldDelegate.phase != phase;
}
