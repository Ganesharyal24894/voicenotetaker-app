import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/recorder_sleep.dart';

/// Asleep, or gone? The pure rules, with the words each platform actually
/// uses - see [LinkDropReason.fromPlatform] for where they come from.
void main() {
  final t0 = DateTime.utc(2026, 9, 20, 23, 30);
  DateTime at(int seconds) => t0.add(Duration(seconds: seconds));

  group('LinkDropReason.fromPlatform', () {
    test('Android passes the HCI name through', () {
      expect(
        LinkDropReason.fromPlatform('Remote User Terminated Connection'),
        LinkDropReason.remoteTerminated,
      );
      expect(
        LinkDropReason.fromPlatform('Connection Timeout'),
        LinkDropReason.supervisionTimeout,
      );
      expect(
        LinkDropReason.fromPlatform(
          'Remote Device Terminated Connection due to Power Off',
        ),
        LinkDropReason.remoteTerminated,
      );
    });

    test('iOS passes the localised description', () {
      expect(
        LinkDropReason.fromPlatform(
          'The specified device has disconnected from us.',
        ),
        LinkDropReason.remoteTerminated,
      );
      expect(
        LinkDropReason.fromPlatform(
          'The connection has timed out unexpectedly.',
        ),
        LinkDropReason.supervisionTimeout,
      );
    });

    test('no reason at all is unknown, never a guess', () {
      expect(LinkDropReason.fromPlatform(null), LinkDropReason.unknown);
      expect(LinkDropReason.fromPlatform(''), LinkDropReason.unknown);
      expect(LinkDropReason.fromPlatform('   '), LinkDropReason.unknown);
      expect(
        LinkDropReason.fromPlatform('Authentication Failure'),
        LinkDropReason.unknown,
      );
    });
  });

  group('a clean drop the platform explained (0x13)', () {
    test('settles, then reads as asleep once the quiet window passes', () {
      final watch = RecorderSleepWatch()..linked(t0);
      expect(watch.presence, RecorderPresence.linked);

      watch.dropped(reason: LinkDropReason.remoteTerminated, now: at(10));
      expect(watch.presence, RecorderPresence.settling);
      expect(watch.nextCheck(), at(20));

      expect(watch.update(at(19)), RecorderPresence.settling);
      expect(watch.update(at(20)), RecorderPresence.asleep);
      expect(watch.isAsleep, isTrue);
      expect(watch.asleepSince, at(20));
      expect(watch.nextCheck(), isNull, reason: 'nothing left to decide');
    });

    test('an attempt that finds nothing confirms it at once', () {
      final watch = RecorderSleepWatch()
        ..linked(t0)
        ..dropped(reason: LinkDropReason.remoteTerminated, now: at(10))
        ..foundNothing(at(12));
      expect(watch.presence, RecorderPresence.asleep);
      expect(watch.asleepSince, at(12));
    });

    test('a recorder that is heard from is awake, not asleep', () {
      final watch = RecorderSleepWatch()
        ..linked(t0)
        ..dropped(reason: LinkDropReason.remoteTerminated, now: at(10))
        ..heard(at(12));
      expect(watch.presence, RecorderPresence.lost);
      expect(watch.update(at(600)), RecorderPresence.lost);
    });

    test('connecting again ends the sleep', () {
      final watch = RecorderSleepWatch()
        ..linked(t0)
        ..dropped(reason: LinkDropReason.remoteTerminated, now: at(10))
        ..foundNothing(at(12));
      expect(watch.isAsleep, isTrue);

      watch.linked(at(4000));
      expect(watch.presence, RecorderPresence.linked);
      expect(watch.asleepSince, isNull);
      expect(watch.update(at(9000)), RecorderPresence.linked);
    });
  });

  group('a supervision timeout (0x08)', () {
    test('is a real drop, immediately, and never becomes a sleep', () {
      final watch = RecorderSleepWatch()
        ..linked(t0)
        ..dropped(reason: LinkDropReason.supervisionTimeout, now: at(10));
      expect(watch.presence, RecorderPresence.lost);
      expect(watch.nextCheck(), isNull);

      watch.foundNothing(at(30));
      expect(watch.update(at(10000)), RecorderPresence.lost,
          reason: 'out of range and flat batteries stay worth telling about');
    });
  });

  group('a drop the platform did not explain', () {
    test('waits the longer window: nothing answering is not proof', () {
      final watch = RecorderSleepWatch()
        ..linked(t0)
        ..dropped(reason: LinkDropReason.unknown, now: at(10));
      expect(watch.presence, RecorderPresence.settling);
      expect(watch.nextCheck(), at(100));

      watch.foundNothing(at(15));
      expect(watch.presence, RecorderPresence.settling,
          reason: 'out of range sounds exactly like this');

      expect(watch.update(at(99)), RecorderPresence.settling);
      expect(watch.update(at(100)), RecorderPresence.asleep);
    });

    test('hearing it inside the window settles it as lost', () {
      final watch = RecorderSleepWatch()
        ..linked(t0)
        ..dropped(reason: LinkDropReason.unknown, now: at(10))
        ..heard(at(30));
      expect(watch.update(at(600)), RecorderPresence.lost);
    });
  });

  test('reset: always-listening off is not a sleep belief to keep', () {
    final watch = RecorderSleepWatch()
      ..linked(t0)
      ..dropped(reason: LinkDropReason.remoteTerminated, now: at(10))
      ..foundNothing(at(12));
    expect(watch.isAsleep, isTrue);

    watch.reset();
    expect(watch.presence, RecorderPresence.lost);
    expect(watch.asleepSince, isNull);
    expect(watch.nextCheck(), isNull);
  });

  test('only sleeping states are restful; a lost recorder is not', () {
    expect(RecorderPresence.asleep.isRestful, isTrue);
    expect(RecorderPresence.settling.isRestful, isTrue);
    expect(RecorderPresence.lost.isRestful, isFalse);
    expect(RecorderPresence.linked.isRestful, isFalse);
  });
}
