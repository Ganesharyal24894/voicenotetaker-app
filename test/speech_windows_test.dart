import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/speech_windows.dart';
import 'package:voicenotetaker_app/model/transcription.dart';

/// Windows cut in the pauses a voice-activity detector found.
void main() {
  const rate = 16000;
  const max = 8 * rate;
  SampleRange s(double from, double to) =>
      SampleRange((from * rate).round(), (to * rate).round());

  List<SampleRange> plan(
    List<SampleRange> speech, {
    double total = 60,
    double pad = 0,
  }) =>
      SpeechWindows.plan(
        speech: speech,
        totalSamples: (total * rate).round(),
        maxWindowSamples: max,
        padSamples: (pad * rate).round(),
      );

  /// The invariants every plan must keep, whatever the input.
  void expectSound(List<SampleRange> windows, List<SampleRange> speech) {
    for (var i = 0; i < windows.length; i++) {
      expect(windows[i].length, lessThanOrEqualTo(max));
      expect(windows[i].length, greaterThan(0));
      if (i > 0) expect(windows[i].start, greaterThanOrEqualTo(windows[i - 1].end));
    }
    for (final range in speech) {
      for (var sample = range.start; sample < range.end; sample += 97) {
        expect(
          windows.where((w) => w.start <= sample && sample < w.end),
          hasLength(1),
          reason: 'speech sample $sample must be in exactly one window',
        );
      }
    }
  }

  test('no speech, no windows', () {
    expect(plan(const <SampleRange>[]), isEmpty);
  });

  test('silence is left out: two utterances far apart are two windows', () {
    final speech = <SampleRange>[s(2, 4), s(30, 33)];
    final windows = plan(speech);
    expect(windows, <SampleRange>[s(2, 4), s(30, 33)]);
    expectSound(windows, speech);
  });

  test('utterances close together are packed into one window, pause and all',
      () {
    final speech = <SampleRange>[s(1, 3), s(3.3, 5), s(5.4, 8.5)];
    final windows = plan(speech);
    expect(windows, <SampleRange>[s(1, 8.5)]);
  });

  test('a window closes before it would pass 8 s, in the pause', () {
    final speech = <SampleRange>[s(0, 3), s(3.5, 7), s(7.5, 10)];
    final windows = plan(speech);
    expect(windows, <SampleRange>[s(0, 7), s(7.5, 10)]);
    expectSound(windows, speech);
  });

  test('speech longer than a window is split on the grid as a backstop', () {
    final speech = <SampleRange>[s(10, 30)];
    final windows = plan(speech);
    expect(windows, <SampleRange>[s(10, 18), s(18, 26), s(26, 30)]);
    expectSound(windows, speech);
  });

  test('padding goes into the silence, never past half the gap', () {
    final speech = <SampleRange>[s(1, 2), s(10.2, 11)];
    final windows = plan(speech, pad: 0.2);
    expect(windows, <SampleRange>[s(0.8, 2.2), s(10.0, 11.2)]);

    // A 0.2 s gap is shared: 0.1 s each side, and they may then pack.
    final close = plan(<SampleRange>[s(20, 27), s(27.2, 30)], pad: 0.2);
    expectSound(close, <SampleRange>[s(20, 27), s(27.2, 30)]);
    expect(close.first.end, lessThanOrEqualTo(s(27.1, 27.1).start));
  });

  test('padding is clamped at the start and end of the audio', () {
    final windows = plan(<SampleRange>[s(0.05, 1), s(59, 60)], pad: 0.2);
    expect(windows.first.start, 0);
    expect(windows.last.end, 60 * rate);
  });

  test('padding never makes a window longer than 8 s', () {
    final windows = plan(<SampleRange>[s(10, 17.9)], pad: 0.2);
    expect(windows.single.length, max);
  });

  test('unsorted, overlapping and out-of-range segments are tidied', () {
    final speech = <SampleRange>[s(5, 7), s(1, 3), s(2, 4), s(58, 70), s(90, 95)];
    final windows = plan(speech);
    expect(windows, <SampleRange>[s(1, 7), s(58, 60)]);
  });

  test('arguments are checked', () {
    expect(
      () => SpeechWindows.plan(
          speech: const [], totalSamples: -1, maxWindowSamples: max),
      throwsArgumentError,
    );
    expect(
      () => SpeechWindows.plan(
          speech: const [], totalSamples: 1, maxWindowSamples: 0),
      throwsArgumentError,
    );
    expect(
      () => SpeechWindows.plan(
          speech: const [],
          totalSamples: 1,
          maxWindowSamples: 1,
          padSamples: -1),
      throwsArgumentError,
    );
  });
}
