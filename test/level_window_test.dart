import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/services/level_meter.dart';

/// [LevelWindow] answers a different question from [LevelMeter]: not "how loud
/// is this 20 ms block" but "how loud was the room over ten seconds".
///
/// The answer is NOT the average of the per-block dBFS figures, and the test
/// that matters most here is the one that proves it. dBFS is logarithmic, so
/// averaging it averages logarithms - and a single loud transient in an
/// otherwise silent window, which is precisely what a rattling enclosure
/// sounds like, would barely move the number.
void main() {
  /// A block of [samples] samples all at +[amplitude].
  Uint8List tone(int amplitude, int samples) {
    final bytes = Uint8List(samples * 2);
    final view = ByteData.sublistView(bytes);
    for (var i = 0; i < samples; i++) {
      view.setInt16(i * 2, amplitude, Endian.little);
    }
    return bytes;
  }

  double dbfs(double amplitude) =>
      20 * (math.log(amplitude / LevelMeter.fullScale) / math.ln10);

  test('before any audio there is no reading, not a floor', () {
    final window = LevelWindow();

    // Null, not -96 dBFS: "no audio arrived" and "the room was silent" are
    // different facts, and a test that confused them would report a dead
    // microphone as a very quiet one.
    expect(window.hasAudio, isFalse);
    expect(window.rmsDbfs, isNull);
    expect(window.peakDbfs, isNull);
    expect(window.sampleCount, 0);
  });

  test('a constant tone reads as its own level', () {
    final window = LevelWindow()..addPcmS16le(tone(3277, 800));

    expect(window.hasAudio, isTrue);
    expect(window.sampleCount, 800);
    // RMS of a constant is the constant, so both figures land on the same value.
    expect(window.rmsDbfs, closeTo(dbfs(3277), 0.01));
    expect(window.peakDbfs, closeTo(dbfs(3277), 0.01));
    expect(window.peakSample, 3277);
  });

  test('energy is summed, not dBFS averaged', () {
    // Ninety-nine blocks of near-silence and one at full scale - a rattle.
    final window = LevelWindow();
    for (var i = 0; i < 99; i++) {
      window.addPcmS16le(tone(1, 100));
    }
    window.addPcmS16le(tone(32767, 100));

    // Averaging the per-block dBFS figures would give roughly
    // (99 * -90.3 + 0) / 100 = -89.4 dBFS, which says "silent room". Summing
    // the energy gives 10 * log10(1/100) = -20 dBFS, which says "something
    // banged". The second is the true level of that window.
    expect(window.rmsDbfs, closeTo(-20.0, 0.1));
    expect(window.rmsDbfs, greaterThan(-30));
  });

  test('the peak is the loudest sample anywhere in the window', () {
    final window = LevelWindow()
      ..addPcmS16le(tone(100, 50))
      ..addPcmS16le(tone(9000, 50))
      ..addPcmS16le(tone(200, 50));

    expect(window.peakSample, 9000);
    expect(window.peakDbfs, closeTo(dbfs(9000), 0.01));
    // And the RMS is well below the peak, which is the whole reason both are
    // reported: a voice with headroom and a clipped one can share a peak.
    expect(window.rmsDbfs! < window.peakDbfs!, isTrue);
  });

  test('a negative sample counts by its magnitude', () {
    final window = LevelWindow()..addPcmS16le(tone(-9000, 50));

    expect(window.peakSample, 9000);
    expect(window.rmsDbfs, closeTo(dbfs(9000), 0.01));
  });

  test('an empty block is ignored rather than divided by', () {
    final window = LevelWindow()..addPcmS16le(Uint8List(0));

    expect(window.hasAudio, isFalse);
    expect(window.rmsDbfs, isNull);
  });

  test('an odd trailing byte does not shift every sample', () {
    // A truncated notification: 5 bytes is two whole samples and a spare.
    final window = LevelWindow()
      ..addPcmS16le(Uint8List.fromList(<int>[0, 0x10, 0, 0x10, 0x7F]));

    expect(window.sampleCount, 2);
    expect(window.peakSample, 0x1000);
  });

  test('digital silence reads as the floor, not as no audio', () {
    final window = LevelWindow()..addPcmS16le(tone(0, 100));

    expect(window.hasAudio, isTrue);
    expect(window.rmsDbfs, LevelMeter.defaultFloorDbfs);
  });

  test('reset forgets the window', () {
    final window = LevelWindow()
      ..addPcmS16le(tone(9000, 50))
      ..reset();

    expect(window.hasAudio, isFalse);
    expect(window.peakSample, 0);
    expect(window.rmsDbfs, isNull);
  });

  test('it borrows the meter it is given, so the floor cannot drift', () {
    final window = LevelWindow(meter: LevelMeter(floorDbfs: -60))
      ..addPcmS16le(tone(0, 100));

    expect(window.rmsDbfs, -60);
  });
}
