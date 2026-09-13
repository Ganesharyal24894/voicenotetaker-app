import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/link_health.dart';
import 'package:voicenotetaker_app/model/recording_metadata.dart';

/// What the live link view renders, as pure data.
///
/// This type exists because a stepped range walk and a three-minute soak were
/// replaced by something you watch. The two properties worth protecting are the
/// two that used to be saved rows: the signal is nullable and never zero, and a
/// loss rate is nullable and never 0.00% before anything has arrived.
void main() {
  LinkHealth watching({
    int? rssiDbm,
    int received = 0,
    int lost = 0,
  }) =>
      LinkHealth(
        rssiDbm: rssiDbm,
        stats: CaptureStats(framesReceived: received, framesLost: lost),
        watching: true,
      );

  group('the signal', () {
    test('no reading is null, not zero - 0 dBm is a real reading', () {
      final health = watching();
      expect(health.rssiDbm, isNull);
      expect(health.rssiFraction, isNull);
    });

    test('the meter runs from the floor to the ceiling, both ends pinned', () {
      expect(watching(rssiDbm: LinkHealth.rssiFloorDbm).rssiFraction, 0.0);
      expect(watching(rssiDbm: LinkHealth.rssiCeilingDbm).rssiFraction, 1.0);
      // Beyond either end the meter pins rather than going out of range: the
      // difference between -45 and -35 dBm is not one anybody needs to see, and
      // a bar wider than its track is a layout bug.
      expect(watching(rssiDbm: -120).rssiFraction, 0.0);
      expect(watching(rssiDbm: -10).rssiFraction, 1.0);
    });

    test('a reading in between lands proportionally', () {
      // Halfway between -95 and -45 is -70.
      expect(watching(rssiDbm: -70).rssiFraction, closeTo(0.5, 1e-9));
    });

    test('the floor is where a 1 Mbit link stops working, not a round number',
        () {
      expect(LinkHealth.rssiFloorDbm, -95);
      expect(LinkHealth.rssiCeilingDbm, -45);
    });
  });

  group('the loss rate', () {
    test('is null before anything has arrived, never 0.00%', () {
      // A perfect link and a link that has not started look identical in a
      // percentage, and they are not the same fact.
      final health = watching();
      expect(health.framesExpected, 0);
      expect(health.lossPercent, isNull);
    });

    test('is counted against what the device sent, not what arrived', () {
      final health = watching(received: 90, lost: 10);
      expect(health.framesExpected, 100);
      expect(health.lossPercent, closeTo(10.0, 1e-9));
    });

    test('a clean stream that has delivered something is a real zero', () {
      final health = watching(received: 100);
      expect(health.lossPercent, 0.0);
      expect(health.lossPercent, isNotNull);
    });
  });

  group('watching', () {
    test('the idle value is not watching, and has no reading', () {
      expect(LinkHealth.idle.watching, isFalse);
      expect(LinkHealth.idle.rssiDbm, isNull);
      expect(LinkHealth.idle.lossPercent, isNull);
    });

    test('separates "nothing lost" from "nothing is counting"', () {
      // Both have zero frames. Only one of them is a measurement.
      final counting = watching();
      const idle = LinkHealth.idle;
      expect(counting.framesLost, idle.framesLost);
      expect(counting.watching, isNot(idle.watching));
    });
  });

  group('value semantics', () {
    test('two identical readings are equal', () {
      expect(watching(rssiDbm: -58, received: 10), watching(rssiDbm: -58, received: 10));
      expect(
        watching(rssiDbm: -58, received: 10).hashCode,
        watching(rssiDbm: -58, received: 10).hashCode,
      );
    });

    test('a different signal is a different reading', () {
      expect(watching(rssiDbm: -58), isNot(watching(rssiDbm: -59)));
    });

    test('it names both halves, because either alone misleads', () {
      expect(
        watching(rssiDbm: -58, received: 10, lost: 1).toString(),
        allOf(contains('-58 dBm'), contains('10 received'), contains('1 lost')),
      );
    });
  });
}
