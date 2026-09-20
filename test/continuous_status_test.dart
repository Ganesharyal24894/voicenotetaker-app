import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/capture_flags.dart';
import 'package:voicenotetaker_app/model/continuous_status.dart';
import 'package:voicenotetaker_app/model/reconnect_backoff.dart';

/// The one status Home and the notification share, and the reconnect waits.
void main() {
  const quiet =
      CaptureFlags(muted: false, speechOpen: false, gateEnabled: true);
  const speaking =
      CaptureFlags(muted: false, speechOpen: true, gateEnabled: true);
  const muted = CaptureFlags(muted: true, speechOpen: true, gateEnabled: true);

  ContinuousStatus resolve({
    bool enabled = true,
    bool connected = true,
    bool? supported = true,
    CaptureFlags? flags = quiet,
  }) =>
      ContinuousStatus.resolve(
        enabled: enabled,
        connected: connected,
        captureSupported: supported,
        flags: flags,
      );

  group('ContinuousStatus.resolve', () {
    test('off wins over everything', () {
      expect(resolve(enabled: false, connected: false), ContinuousStatus.off);
      expect(resolve(enabled: false, flags: muted), ContinuousStatus.off);
    });

    test('no link is "not connected", whatever was last reported', () {
      expect(resolve(connected: false, flags: speaking),
          ContinuousStatus.notConnected);
    });

    test('firmware without fe08 needs an update', () {
      expect(resolve(supported: false), ContinuousStatus.needsFirmwareUpdate);
    });

    test('not yet checked reads as listening, not as a firmware problem', () {
      expect(resolve(supported: null, flags: null), ContinuousStatus.listening);
    });

    test('muted outranks hearing speech', () {
      expect(resolve(flags: muted), ContinuousStatus.muted);
    });

    test('the mic off to save battery is its own state; mute outranks it', () {
      const micOff = CaptureFlags(
        muted: false,
        speechOpen: false,
        gateEnabled: true,
        micOff: true,
      );
      expect(resolve(flags: micOff), ContinuousStatus.micOff);
      expect(
        resolve(
          flags: const CaptureFlags(
            muted: true,
            speechOpen: false,
            gateEnabled: true,
            micOff: true,
          ),
        ),
        ContinuousStatus.muted,
      );
      expect(resolve(enabled: false, flags: micOff), ContinuousStatus.off);
    });

    test('an open gate is hearing speech, a closed one is listening', () {
      expect(resolve(flags: speaking), ContinuousStatus.hearingSpeech);
      expect(resolve(flags: quiet), ContinuousStatus.listening);
    });

    test('audio flowing with the gate disabled is not "hearing speech"', () {
      // What the device reports for a moment after every reconnect, before
      // speech-only has been written again.
      expect(
        resolve(
          flags: const CaptureFlags(
            muted: false,
            speechOpen: true,
            gateEnabled: false,
          ),
        ),
        ContinuousStatus.listening,
      );
    });
  });

  group('asleep', () {
    ContinuousStatus resolveAsleep({
      bool enabled = true,
      bool connected = false,
      ContinuousStatus? refused,
    }) =>
        ContinuousStatus.resolve(
          enabled: enabled,
          connected: connected,
          captureSupported: null,
          flags: null,
          refused: refused,
          asleep: true,
        );

    test('a sleeping recorder is its own status, not "not connected"', () {
      expect(resolveAsleep(), ContinuousStatus.asleep);
    });

    test('it outranks a refusal: a recorder that answered is not asleep', () {
      expect(
        resolveAsleep(refused: ContinuousStatus.pairedToAnother),
        ContinuousStatus.asleep,
      );
    });

    test('always listening off still wins, and so does a live link', () {
      expect(resolveAsleep(enabled: false), ContinuousStatus.off);
      expect(
        ContinuousStatus.resolve(
          enabled: true,
          connected: true,
          captureSupported: true,
          flags: null,
          asleep: true,
        ),
        ContinuousStatus.listening,
      );
    });
  });

  test('the copy is short and plain', () {
    expect(ContinuousStatus.listening.label, 'Always listening');
    expect(ContinuousStatus.muted.label, 'Privacy mode');
    expect(ContinuousStatus.hearingSpeech.label, 'Hearing speech');
    expect(ContinuousStatus.notConnected.label, 'Device not connected');
    expect(ContinuousStatus.needsFirmwareUpdate.label, 'Needs firmware update');
    expect(ContinuousStatus.pairedToAnother.label, 'Paired to another phone');
    expect(ContinuousStatus.oldPairing.label, 'Pairing needs a reset');
    expect(ContinuousStatus.asleep.label, 'Recorder asleep');
    for (final status in ContinuousStatus.values) {
      expect(status.label.length, lessThanOrEqualTo(24), reason: status.name);
    }
  });

  test('a refusal shows only while there is no link', () {
    expect(
      ContinuousStatus.resolve(
        enabled: true,
        connected: false,
        captureSupported: null,
        flags: null,
        refused: ContinuousStatus.pairedToAnother,
      ),
      ContinuousStatus.pairedToAnother,
    );
    expect(
      ContinuousStatus.resolve(
        enabled: true,
        connected: true,
        captureSupported: true,
        flags: null,
        refused: ContinuousStatus.pairedToAnother,
      ),
      ContinuousStatus.listening,
    );
    expect(
      ContinuousStatus.resolve(
        enabled: false,
        connected: false,
        captureSupported: null,
        flags: null,
        refused: ContinuousStatus.oldPairing,
      ),
      ContinuousStatus.off,
    );
  });

  group('ReconnectBackoff', () {
    test('keeps its minute after one refusal, then waits ten minutes', () {
      expect(ReconnectBackoff.delayFor(0, refusals: 1), Duration.zero);
      expect(ReconnectBackoff.delayFor(9, refusals: 1),
          const Duration(minutes: 1));
      expect(ReconnectBackoff.delayFor(0, refusals: 2),
          const Duration(minutes: 10));
      expect(ReconnectBackoff.delayFor(40, refusals: 7),
          ReconnectBackoff.refusedDelay);
    });

    test('the first attempt is immediate', () {
      expect(ReconnectBackoff.delayFor(0), Duration.zero);
    });

    test('a sleeping recorder is waited for, not hunted', () {
      expect(
        ReconnectBackoff.delayFor(0, asleep: true),
        ReconnectBackoff.asleepDelay,
      );
      expect(
        ReconnectBackoff.delayFor(40, asleep: true),
        ReconnectBackoff.asleepDelay,
        reason: 'the ladder does not apply to a device in System OFF',
      );
      expect(
        ReconnectBackoff.delayFor(3, refusals: 5, asleep: true),
        ReconnectBackoff.asleepDelay,
      );
      expect(
        ReconnectBackoff.asleepAttemptTimeout,
        greaterThan(ReconnectBackoff.attemptTimeout),
        reason: 'the standing wait is armed for far longer than a hard try',
      );
    });

    test('waits grow and then hold at a minute', () {
      var previous = Duration.zero;
      for (var attempt = 1; attempt < 20; attempt++) {
        final delay = ReconnectBackoff.delayFor(attempt);
        expect(delay, greaterThanOrEqualTo(previous));
        expect(delay, lessThanOrEqualTo(const Duration(minutes: 1)));
        previous = delay;
      }
      expect(ReconnectBackoff.delayFor(1000), const Duration(minutes: 1));
    });

    test('a negative attempt is treated as the first', () {
      expect(ReconnectBackoff.delayFor(-3), Duration.zero);
    });

    test('an attempt gives up well inside the minute it waits', () {
      expect(ReconnectBackoff.attemptTimeout,
          lessThan(ReconnectBackoff.schedule.last));
    });
  });
}
