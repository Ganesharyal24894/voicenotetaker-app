/// How many bars to show for a reported percentage.
///
/// WHY BARS AND NOT THE NUMBER. The device's charge estimate comes from cell
/// voltage against an OCV curve, and in the middle of that curve roughly two
/// millivolts separate one percentage point from the next. With an
/// uncalibrated reference and untrimmed divider resistors, a mid-range
/// reading can be out by a wide margin -- so printing "47%" claims a
/// precision the measurement does not have. Four buckets claim only what is
/// actually known.
///
/// The error is NOT uniform, and that is what makes bars fit. Near full and
/// near empty the curve is 9 and 38 mV per point, so those readings are
/// sound; the mush is in the middle. The decisions a user makes -- "is it
/// full", "must I charge now" -- live at the ends, where the measurement is
/// good. The two middle bars both mean "you're fine", which is all the
/// plateau can honestly support.
library;

/// Bars, and whether the charge is confirmed full or critically low.
class BatteryBars {
  const BatteryBars({
    required this.bars,
    required this.isFull,
    required this.isCritical,
  });

  /// Nothing known - the outline renders empty rather than at zero.
  static const BatteryBars unknown =
      BatteryBars(bars: 0, isFull: false, isCritical: false);

  /// Bars to fill, `0 .. maxBars`. Zero also means "unknown"; [isCritical]
  /// is what distinguishes an empty battery from an unread one.
  final int bars;

  /// The charger reported termination. See [fullPercent].
  final bool isFull;

  /// At or below [criticalPercent] - the app's warning matches the device's
  /// own amber low-battery blink, so the two never disagree in front of the
  /// user.
  final bool isCritical;

  static const int maxBars = 4;

  /// The firmware caps the reported percentage at 99 WHILE CHARGING, so 100
  /// means exactly one thing: the charger terminated, which it only does on
  /// a full cell. That makes "full" a confirmed fact rather than a number
  /// the app rounded up.
  static const int fullPercent = 100;

  /// Matches `LED_BATTERY_LOW_PERCENT` in the firmware.
  static const int criticalPercent = 10;

  /// Lower bound of each bar, highest first.
  static const List<int> thresholds = <int>[75, 50, 25, 0];

  /// Dead-band applied to every boundary.
  ///
  /// Without it a reading sitting on a threshold flickers between two bars,
  /// and a flickering bar reads as BROKEN in a way a number twitching
  /// between 47 and 49 does not. A bar only rises once the reading clears
  /// the boundary by this much, and only falls once it drops below it by the
  /// same -- so the glyph is stable even though the input is not.
  static const int hysteresis = 3;

  /// Buckets [percent], holding [previous] where the reading is too close to
  /// a boundary to justify moving.
  ///
  /// Pure: same inputs, same answer, no clock and no stored state. The
  /// caller owns [previous].
  static BatteryBars forPercent(int? percent, {BatteryBars? previous}) {
    if (percent == null) return unknown;

    final clamped = percent.clamp(0, fullPercent);

    // A REAL ZERO IS ITS OWN STATE, AND HISTORY HAS NO SAY IN IT. There is no
    // boundary below zero for the dead-band to protect - a reading cannot dip
    // past it and come back - so letting the lowest bar hang on here would
    // only mean a flat cell looked different depending on whether the app
    // watched it drain or connected to it already empty. Zero bars WITH
    // [isCritical] is the empty battery; zero bars without it is [unknown].
    if (clamped == 0) {
      return const BatteryBars(bars: 0, isFull: false, isCritical: true);
    }

    final was = previous?.bars ?? 0;

    // Zero, not [maxBars]: a reading that clears no threshold has no bars to
    // show. Starting the search at the top would leave a cell too low to
    // reach even the first bar rendering as a FULL one.
    var bars = 0;
    for (var i = 0; i < thresholds.length; i++) {
      final floor = thresholds[i];
      final level = maxBars - i;
      // Rising into a bar needs the reading ABOVE the boundary by the
      // dead-band; staying in one it already holds needs only the boundary.
      final needed = level > was ? floor + hysteresis : floor - hysteresis;
      if (clamped >= needed) {
        bars = level;
        break;
      }
    }

    return BatteryBars(
      bars: bars,
      isFull: clamped >= fullPercent,
      isCritical: clamped <= criticalPercent,
    );
  }
}
