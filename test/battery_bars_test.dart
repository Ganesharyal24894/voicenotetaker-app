import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/battery_bars.dart';

/// Bucketing a reported percentage into four bars.
///
/// WHY THIS IS BUCKETED AT ALL. The device derives its percentage from cell
/// voltage against an OCV curve, and across the middle of that curve about two
/// millivolts separate one point from the next - well inside what an
/// uncalibrated reference and untrimmed divider can be out by. The error is
/// not uniform: near full it is about 9 mV per point and near empty about 38,
/// so the ENDS of the scale are sound and the middle is mush. The decisions a
/// user makes - "is it full", "must I charge now" - live at the ends. Four
/// buckets claim exactly that much and no more.
///
/// The firmware is unchanged and still reports the percentage over `fe05`:
/// nothing is discarded at the protocol layer, because that could not be
/// undone. These tests describe the APP's arithmetic.
void main() {
  group('the buckets', () {
    // Walked from no previous reading, which is the state the app is in when
    // it connects: rising into a bar has to clear the dead-band, so these are
    // the answers a user sees on the first reading of a session.
    const Map<int, int> fromCold = <int, int>{
      100: 4,
      99: 4,
      90: 4,
      78: 4,
      77: 3,
      60: 3,
      53: 3,
      52: 2,
      40: 2,
      28: 2,
      27: 1,
      11: 1,
      3: 1,
      2: 0,
      1: 0,
      0: 0,
    };

    for (final MapEntry<int, int> expected in fromCold.entries) {
      test('${expected.key}% is ${expected.value} bars on a first reading', () {
        expect(BatteryBars.forPercent(expected.key).bars, expected.value);
      });
    }

    test('the thresholds are the quarters, highest first', () {
      expect(BatteryBars.thresholds, <int>[75, 50, 25, 0]);
      expect(BatteryBars.maxBars, 4);
    });

    test('the bars never exceed the scale, whatever arrives', () {
      for (var percent = 0; percent <= 100; percent++) {
        final bars = BatteryBars.forPercent(percent).bars;
        expect(bars, inInclusiveRange(0, BatteryBars.maxBars),
            reason: '$percent% produced $bars bars');
      }
    });

    test('a reading out of contract range is clamped, not believed', () {
      // `BatteryStatus` rejects these on the wire; the model still refuses to
      // hand back a fifth bar or a negative one if it ever sees them.
      expect(BatteryBars.forPercent(120).bars, BatteryBars.maxBars);
      expect(BatteryBars.forPercent(120).isFull, isTrue);
      expect(BatteryBars.forPercent(-5).bars, 0);
      expect(BatteryBars.forPercent(-5).isCritical, isTrue);
    });
  });

  group('falling boundaries', () {
    // Descending, each from the bar the previous reading established. The
    // dead-band sits below the threshold on the way down, exactly as far as
    // it sits above it on the way up.
    test('four bars hold to 72% and drop at 71%', () {
      final four = BatteryBars.forPercent(80);
      expect(four.bars, 4);
      expect(BatteryBars.forPercent(72, previous: four).bars, 4);
      expect(BatteryBars.forPercent(71, previous: four).bars, 3);
    });

    test('three bars hold to 47% and drop at 46%', () {
      final three = BatteryBars.forPercent(60);
      expect(three.bars, 3);
      expect(BatteryBars.forPercent(47, previous: three).bars, 3);
      expect(BatteryBars.forPercent(46, previous: three).bars, 2);
    });

    test('two bars hold to 22% and drop at 21%', () {
      final two = BatteryBars.forPercent(40);
      expect(two.bars, 2);
      expect(BatteryBars.forPercent(22, previous: two).bars, 2);
      expect(BatteryBars.forPercent(21, previous: two).bars, 1);
    });

    test('the last bar holds down to 1% and is gone at 0%', () {
      final one = BatteryBars.forPercent(20);
      expect(one.bars, 1);
      expect(BatteryBars.forPercent(1, previous: one).bars, 1);
      expect(BatteryBars.forPercent(0, previous: one).bars, 0);
    });
  });

  group('the dead-band', () {
    test('a reading wobbling across a boundary does not move the bars', () {
      // A cell sitting on 75% really does report 74, 76, 73, 77 as the load
      // changes. A bar that twitched with it would read as BROKEN, in a way a
      // number twitching between 74 and 76 does not.
      var bars = BatteryBars.forPercent(80);
      expect(bars.bars, 4);

      for (final int percent in <int>[76, 74, 77, 73, 75, 76, 74]) {
        bars = BatteryBars.forPercent(percent, previous: bars);
        expect(bars.bars, 4, reason: '$percent% is inside the dead-band');
      }
    });

    test('it is a dead-band, not a latch', () {
      var bars = BatteryBars.forPercent(80);
      // Clear of the band below, the bar does drop...
      bars = BatteryBars.forPercent(71, previous: bars);
      expect(bars.bars, 3);
      // ...and coming back up it does not return until it clears the band
      // above, so one wobble cannot produce two transitions.
      bars = BatteryBars.forPercent(76, previous: bars);
      expect(bars.bars, 3);
      bars = BatteryBars.forPercent(78, previous: bars);
      expect(bars.bars, 4);
    });

    test('the band is the documented three points, on every boundary', () {
      expect(BatteryBars.hysteresis, 3);
      for (final int floor in BatteryBars.thresholds) {
        if (floor == 0) continue; // No boundary below the bottom of the scale.
        final above = BatteryBars.forPercent(floor + BatteryBars.hysteresis);
        final justBelow =
            BatteryBars.forPercent(floor + BatteryBars.hysteresis - 1);
        expect(above.bars, greaterThan(justBelow.bars),
            reason: 'rising into a bar at $floor% takes the full band');
      }
    });

    test('no previous reading means no band to hold', () {
      // 74% is four bars when the last answer was four, and three when there
      // was no last answer. That is what makes it the reading to test a
      // caller's state-keeping with.
      expect(BatteryBars.forPercent(74).bars, 3);
      expect(
        BatteryBars.forPercent(74, previous: BatteryBars.forPercent(80)).bars,
        4,
      );
    });

    test('it reads the previous answer without changing it', () {
      final previous = BatteryBars.forPercent(80);
      BatteryBars.forPercent(10, previous: previous);
      expect(previous.bars, 4, reason: 'pure: the caller owns `previous`');
      // Same inputs, same answer, no clock and no stored state.
      expect(
        BatteryBars.forPercent(64, previous: previous).bars,
        BatteryBars.forPercent(64, previous: previous).bars,
      );
    });
  });

  group('unknown is not empty', () {
    test('no reading is the unknown instance, and claims nothing', () {
      final unknown = BatteryBars.forPercent(null);
      expect(unknown, same(BatteryBars.unknown));
      expect(unknown.bars, 0);
      expect(unknown.isFull, isFalse);
      expect(unknown.isCritical, isFalse);
    });

    test('a measured 0% is zero bars AND critical', () {
      // This is the pair that must never collapse: both draw no bars, and
      // `isCritical` is what tells a flat cell from an unanswered question.
      final empty = BatteryBars.forPercent(0);
      final unknown = BatteryBars.forPercent(null);

      expect(empty.bars, unknown.bars);
      expect(empty.isCritical, isTrue);
      expect(unknown.isCritical, isFalse);
    });

    test('a flat cell is never rendered as a full one', () {
      // THE REGRESSION. The bucketing loop used to start its search at
      // `maxBars` and fall through with it when a reading cleared no
      // threshold at all - so 0%, 1% and 2% came back as FOUR bars: a dead
      // battery drawn as a full one, which is the worst lie this readout
      // could tell.
      for (final int percent in <int>[0, 1, 2]) {
        final bars = BatteryBars.forPercent(percent);
        expect(bars.bars, 0, reason: '$percent% must not fill a bar');
        expect(bars.isFull, isFalse);
      }
    });

    test('zero is zero whether the app watched it get there or not', () {
      // No boundary exists below zero for the dead-band to protect, so a flat
      // cell must not look different depending on history.
      expect(BatteryBars.forPercent(0).bars, 0);
      expect(
        BatteryBars.forPercent(0, previous: BatteryBars.forPercent(80)).bars,
        0,
      );
      expect(
        BatteryBars.forPercent(0, previous: BatteryBars.forPercent(20)).bars,
        0,
      );
    });

    test('unknown after a reading forgets the reading', () {
      final four = BatteryBars.forPercent(80);
      expect(BatteryBars.forPercent(null, previous: four),
          same(BatteryBars.unknown));
    });
  });

  group('full', () {
    test('100% is full, and fills the scale', () {
      final full = BatteryBars.forPercent(100);
      expect(full.isFull, isTrue);
      expect(full.bars, BatteryBars.maxBars);
      expect(full.isCritical, isFalse);
      expect(BatteryBars.fullPercent, 100);
    });

    test('99% fills the scale without claiming to be full', () {
      // The firmware caps the reported percentage at 99 WHILE CHARGING, so
      // 100 means exactly one thing: the charger terminated, which it only
      // does on a full cell. Full is a confirmed fact, not a rounded number -
      // and 99 is the top of the charging ramp, which is not the same fact.
      final nearly = BatteryBars.forPercent(99);
      expect(nearly.bars, BatteryBars.maxBars);
      expect(nearly.isFull, isFalse);
    });

    test('full is not reached by hysteresis from below', () {
      // The dead-band moves bars, never the full flag: 98 with a full
      // previous reading is still not full.
      final full = BatteryBars.forPercent(100);
      expect(BatteryBars.forPercent(98, previous: full).isFull, isFalse);
    });
  });

  group('critical', () {
    test('the threshold matches the firmware\'s own warning', () {
      // LED_BATTERY_LOW_PERCENT in the firmware. The app's warning and the
      // device's amber blink have to agree, or they disagree in front of a
      // user holding both.
      expect(BatteryBars.criticalPercent, 10);
    });

    test('10% is critical and 11% is not', () {
      expect(BatteryBars.forPercent(10).isCritical, isTrue);
      expect(BatteryBars.forPercent(11).isCritical, isFalse);
    });

    test('critical is about the reading, not about the bars', () {
      // 10% still lights the first bar; the warning is carried separately so
      // "one bar" and "nearly dead" do not have to mean the same thing.
      final low = BatteryBars.forPercent(10);
      expect(low.bars, 1);
      expect(low.isCritical, isTrue);
    });

    test('hysteresis does not soften the warning', () {
      // Coming down from a fuller reading the bars may lag, but the critical
      // flag follows the measurement exactly.
      final four = BatteryBars.forPercent(80);
      expect(BatteryBars.forPercent(9, previous: four).isCritical, isTrue);
    });

    test('full and critical are never both true', () {
      for (var percent = 0; percent <= 100; percent++) {
        final bars = BatteryBars.forPercent(percent);
        expect(bars.isFull && bars.isCritical, isFalse,
            reason: '$percent% claimed both');
      }
    });
  });
}
