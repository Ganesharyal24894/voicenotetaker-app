import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/continuous_status.dart';
import 'package:voicenotetaker_app/model/home_status.dart';
import 'package:voicenotetaker_app/model/notes_saving.dart';

void main() {
  HomeStatus resolve(ContinuousStatus s, {bool connected = true, bool charging = false}) =>
      HomeStatus.resolve(continuous: s, connected: connected, charging: charging);

  test('always listening, listening or hearing speech: saving notes', () {
    expect(resolve(ContinuousStatus.listening), const HomeStatus('Saving notes', HomeStatusTone.good));
    expect(resolve(ContinuousStatus.hearingSpeech), const HomeStatus('Saving notes', HomeStatusTone.good));
    expect(resolve(ContinuousStatus.listening, charging: true).label, 'Saving notes',
        reason: 'whether notes are saved outranks the charger');
  });

  test('on but not saving is amber, and says why in plain words', () {
    expect(resolve(ContinuousStatus.notConnected, connected: false),
        const HomeStatus('Not saving — recorder disconnected', HomeStatusTone.warning));
    expect(resolve(ContinuousStatus.privacyMode), const HomeStatus('Privacy mode on', HomeStatusTone.privacy));
    expect(resolve(ContinuousStatus.needsFirmwareUpdate).label, 'Not saving — recorder needs an update');
    expect(resolve(ContinuousStatus.micOff),
        const HomeStatus('Not saving — mic off to save battery', HomeStatusTone.warning));
  });

  test('an SD-card recorder away from the phone is neutral, not amber', () {
    expect(
      HomeStatus.resolve(
        continuous: ContinuousStatus.notConnected,
        connected: false,
        charging: false,
        storage: RecorderStorage.card,
      ),
      const HomeStatus('Saving on recorder · syncs when back', HomeStatusTone.idle),
    );
  });

  test('a sleeping recorder is not an error: plain words, no amber', () {
    expect(
      resolve(ContinuousStatus.asleep, connected: false),
      const HomeStatus(
        'Recorder asleep — pick it up to wake it',
        HomeStatusTone.idle,
      ),
    );
  });

  test('privacy mode is called privacy mode', () {
    expect(resolve(ContinuousStatus.privacyMode).label, 'Privacy mode on');
  });

  test('always listening off: the link, or nothing', () {
    expect(resolve(ContinuousStatus.off), const HomeStatus('Connected', HomeStatusTone.good));
    expect(resolve(ContinuousStatus.off, charging: true).label, 'Charging');
    expect(resolve(ContinuousStatus.off, connected: false), const HomeStatus('Not connected', HomeStatusTone.idle));
  });
}
