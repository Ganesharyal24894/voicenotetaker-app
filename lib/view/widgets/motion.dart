/// The animations from `design/Motion.dc.html` and
/// `design/DeviceMotion.dc.html`.
///
/// ---------------------------------------------------------------------------
/// TWO RULES THIS FILE EXISTS TO ENFORCE
///
/// 1. REDUCE MOTION IS NOT OPTIONAL. Every widget here reads
///    [AppMotion.isReduced] in `didChangeDependencies` and, when it is set,
///    never starts its controller at all: one-shot animations become instant
///    state changes and the two loops become static. Motion sensitivity is a
///    real accessibility need, not a preference.
///
/// 2. NOTHING LOOPS THAT IS NOT REPORTING A LIVE CONDITION. Only the scan
///    ripple (see `scan_control.dart`) and [BreathingDot] repeat, because each
///    says something is happening right now. Everything in this file fires
///    once, on a state change.
///
/// Every controller is disposed in [State.dispose]. A leaked one shows up as a
/// pending timer at the end of a widget test, which this project has already
/// been bitten by.
/// ---------------------------------------------------------------------------
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../theme.dart';

/// The connected status dot: breathes 1 -> 0.4 -> 1 over two seconds, for as
/// long as the link is up.
///
/// One of the two things in the app permitted to loop forever. It is
/// deliberately slow and shallow: it runs for hours.
class BreathingDot extends StatefulWidget {
  const BreathingDot({
    required this.color,
    this.size = 6,
    this.breathing = true,
    super.key,
  });

  final Color color;
  final double size;

  /// False for the disconnected dot, which is grey and still.
  final bool breathing;

  @override
  State<BreathingDot> createState() => _BreathingDotState();
}

class _BreathingDotState extends State<BreathingDot>
    with SingleTickerProviderStateMixin {
  // Half a cycle: the controller runs out and back, so 1 s each way is the
  // design's 2 s breath.
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.breathe ~/ 2,
    value: 1,
  );

  late final Animation<double> _opacity = _controller.drive(
    Tween<double>(begin: AppMotion.breatheMinOpacity, end: 1)
        .chain(CurveTween(curve: Curves.easeInOut)),
  );

  bool _reduced = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = AppMotion.isReduced(context);
    _sync();
  }

  @override
  void didUpdateWidget(BreathingDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final shouldRun = widget.breathing && !_reduced;
    if (shouldRun == _controller.isAnimating) return;
    if (shouldRun) {
      _controller.repeat(reverse: true);
    } else {
      _controller
        ..stop()
        ..value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
    );
    if (!widget.breathing || _reduced) return dot;
    return FadeTransition(opacity: _opacity, child: dot);
  }
}

/// A discovered device row arriving: slides in from the right over 450 ms.
///
/// [index] staggers rows that land together by 40 ms each, so a list that
/// fills up reads as filling up rather than blinking into existence. The
/// stagger is an [Interval] on one controller rather than a delayed timer -
/// a pending `Future.delayed` outliving the widget is exactly the leak this
/// project has been bitten by before.
class SlideInFromRight extends StatefulWidget {
  const SlideInFromRight({
    required this.child,
    this.index = 0,
    super.key,
  });

  final Widget child;
  final int index;

  @override
  State<SlideInFromRight> createState() => _SlideInFromRightState();
}

class _SlideInFromRightState extends State<SlideInFromRight>
    with SingleTickerProviderStateMixin {
  /// Rows past this position start together; a long list should not take a
  /// second and a half to finish arriving.
  static const int maxStaggered = 6;

  late final Duration _delay =
      AppMotion.rowStagger * math.min(widget.index, maxStaggered);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _delay + AppMotion.rowSlideIn,
  );

  late final Animation<double> _progress = CurvedAnimation(
    parent: _controller,
    curve: Interval(
      _controller.duration!.inMicroseconds == 0
          ? 0
          : _delay.inMicroseconds / _controller.duration!.inMicroseconds,
      1,
      curve: AppMotion.rowSlideInCurve,
    ),
  );

  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (AppMotion.isReduced(context)) {
      // Instant state change: the row is simply there.
      _controller.value = 1;
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _progress,
      child: widget.child,
      builder: (context, child) {
        final t = _progress.value;
        if (t == 1) return child!;
        return Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(AppMotion.rowSlideInOffset * (1 - t), 0),
            child: child,
          ),
        );
      },
    );
  }
}

/// Scales its child to 0.93 while it is held, and back on release.
///
/// 120 ms down, 180 ms up - the difference between a button that feels
/// connected to your finger and one that does not.
class PressScale extends StatefulWidget {
  const PressScale({
    required this.child,
    this.onTap,
    super.key,
  });

  final Widget child;

  /// Null disables both the gesture and the scale.
  final VoidCallback? onTap;

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.pressDown,
    reverseDuration: AppMotion.pressRelease,
  );

  late final Animation<double> _scale = _controller.drive(
    Tween<double>(begin: 1, end: AppMotion.pressScale)
        .chain(CurveTween(curve: Curves.easeOut)),
  );

  bool _reduced = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = AppMotion.isReduced(context);
    if (_reduced) _controller.value = 0;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _down() {
    if (_reduced || widget.onTap == null) return;
    _controller.forward();
  }

  void _up() {
    if (_reduced) return;
    _controller.reverse();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _down(),
      onTapUp: (_) => _up(),
      onTapCancel: _up,
      onTap: widget.onTap,
      child: _reduced
          ? widget.child
          : ScaleTransition(scale: _scale, child: widget.child),
    );
  }
}

/// The board arriving when a recorder is found.
///
/// NO TILT: one full `rotateY`, fading up from `scale(.7)`, overshooting to
/// 1.06 and settling. ~2.1 s on `cubic-bezier(.18,.85,.3,1)`, from
/// `design/DeviceMotion.dc.html`.
///
/// It fires once, when the mark first appears. Under reduce motion the mark is
/// simply there, at full size and opacity, on the first frame.
class DeviceFoundEntrance extends StatefulWidget {
  const DeviceFoundEntrance({required this.child, super.key});

  final Widget child;

  @override
  State<DeviceFoundEntrance> createState() => _DeviceFoundEntranceState();
}

class _DeviceFoundEntranceState extends State<DeviceFoundEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.deviceFound,
  );

  late final Animation<double> _progress = CurvedAnimation(
    parent: _controller,
    curve: AppMotion.deviceFoundCurve,
  );

  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (AppMotion.isReduced(context)) {
      _controller.value = 1;
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// `.7` up to [AppMotion.deviceFoundOvershoot] at the peak, then back to 1.
  static double scaleAt(double t) {
    const peak = AppMotion.deviceFoundPeak;
    if (t >= 1) return 1;
    if (t <= peak) {
      return 0.7 + (AppMotion.deviceFoundOvershoot - 0.7) * (t / peak);
    }
    final settle = (t - peak) / (1 - peak);
    return AppMotion.deviceFoundOvershoot -
        (AppMotion.deviceFoundOvershoot - 1) * settle;
  }

  /// The CSS fades in over the first 12% of a 62% turn.
  static double opacityAt(double t) => (t / 0.19).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _progress,
      child: widget.child,
      builder: (context, child) {
        final t = _progress.value;
        if (t >= 1) return child!;
        final matrix = Matrix4.identity()
          // A shallow perspective, so the turn reads as a turn and not as a
          // horizontal squash.
          ..setEntry(3, 2, 0.0012)
          ..rotateY(t * 2 * math.pi)
          ..scaleByDouble(scaleAt(t), scaleAt(t), 1, 1);
        return Opacity(
          opacity: opacityAt(t),
          child: Transform(
            alignment: Alignment.center,
            transform: matrix,
            child: child,
          ),
        );
      },
    );
  }
}
