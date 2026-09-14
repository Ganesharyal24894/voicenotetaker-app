import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/continuous_status.dart';
import 'package:voicenotetaker_app/model/home_status.dart';

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
    expect(resolve(ContinuousStatus.muted).tone, HomeStatusTone.warning);
    expect(resolve(ContinuousStatus.needsFirmwareUpdate).label, 'Not saving — recorder needs an update');
  });

  test('always listening off: the link, or nothing', () {
    expect(resolve(ContinuousStatus.off), const HomeStatus('Connected', HomeStatusTone.good));
    expect(resolve(ContinuousStatus.off, charging: true).label, 'Charging');
    expect(resolve(ContinuousStatus.off, connected: false), const HomeStatus('Not connected', HomeStatusTone.idle));
  });
}
