import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/view/format.dart';

void main() {
  test('timer pads minutes so tabular figures do not reflow', () {
    expect(Fmt.timer(const Duration(seconds: 0)), '00:00');
    expect(Fmt.timer(const Duration(minutes: 2, seconds: 47)), '02:47');
    expect(Fmt.timer(const Duration(hours: 1, minutes: 2, seconds: 3)),
        '1:02:03');
  });

  test('durations read the way the lists show them', () {
    expect(Fmt.duration(const Duration(minutes: 4, seconds: 12)), '4:12');
    expect(Fmt.duration(const Duration(minutes: 27, seconds: 55)), '27:55');
  });

  test('time of day is zero-padded', () {
    expect(Fmt.timeOfDay(DateTime(2026, 9, 10, 9, 14)), '09:14');
  });

  test('day labels are relative for a week, then dated', () {
    final now = DateTime(2026, 9, 10, 18);
    expect(Fmt.day(DateTime(2026, 9, 10, 9), now: now), 'Today');
    expect(Fmt.day(DateTime(2026, 9, 9, 16), now: now), 'Yesterday');
    expect(Fmt.day(DateTime(2026, 9, 7, 11), now: now), 'Mon');
    expect(Fmt.day(DateTime(2026, 3, 12, 11), now: now), '12 Mar');
  });

  test('sizes and signal strengths match the mock', () {
    expect(Fmt.bytes(7900000), '7.9 MB');
    expect(Fmt.bytes(53600000), '53.6 MB');
    expect(Fmt.bytes(812000), '812 kB');
    expect(Fmt.rssi(-54), '−54 dBm');
    expect(Fmt.rssi(null), '— dBm');
  });

  test('stream summary', () {
    expect(Fmt.streamSummary(16000, 1), '16 kHz mono');
    expect(Fmt.streamSummary(48000, 2), '48 kHz stereo');
  });
}
