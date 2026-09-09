import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/level_reading.dart';
import 'package:voicenotetaker_app/services/level_meter.dart';

/// Builds one block of s16le PCM from [samples], the way the ADPCM decoder
/// hands its output to the meter.
Uint8List pcm(List<int> samples) {
  final bytes = Uint8List(samples.length * 2);
  final view = ByteData.sublistView(bytes);
  for (var i = 0; i < samples.length; i++) {
    view.setInt16(i * 2, samples[i], Endian.little);
  }
  return bytes;
}

/// `count` samples of a sine at [amplitude], a whole number of periods long so
/// its RMS is exactly `amplitude / sqrt(2)`.
List<int> sine({required int amplitude, int periods = 8, int perPeriod = 40}) {
  final total = periods * perPeriod;
  return <int>[
    for (var i = 0; i < total; i++)
      (amplitude * math.sin(2 * math.pi * i / perPeriod)).round(),
  ];
}

void main() {
  group('silence', () {
    test('a block of zeroes reads the floor, not negative infinity', () {
      final meter = LevelMeter();
      final reading = meter.addPcmS16le(pcm(List<int>.filled(320, 0)))!;

      expect(reading.peakDbfs, LevelMeter.defaultFloorDbfs);
      expect(reading.rmsDbfs, LevelMeter.defaultFloorDbfs);
      expect(reading.peakSample, 0);
      expect(reading.peakDbfs.isFinite, isTrue);
      expect(reading.rmsDbfs.isFinite, isTrue);
    });

    test('the floor is configurable', () {
      final meter = LevelMeter(floorDbfs: -60);
      final reading = meter.addPcmS16le(pcm(List<int>.filled(64, 0)))!;
      expect(reading.peakDbfs, -60);
    });
  });

  group('full scale', () {
    test('a square wave at +/-32767 is 0 dBFS peak and 0 dBFS RMS', () {
      final meter = LevelMeter();
      final reading = meter.addPcmS16le(
        pcm(<int>[for (var i = 0; i < 320; i++) i.isEven ? 32767 : -32767]),
      )!;

      expect(reading.peakDbfs, closeTo(0, 0.001));
      expect(reading.rmsDbfs, closeTo(0, 0.001));
      expect(reading.peakSample, 32767);
    });

    test('-32768 is clamped to 0 dBFS rather than reported above full scale',
        () {
      // The negative end of int16 is one step louder than the positive end;
      // a meter that does not clamp reports a positive dBFS, which cannot be
      // drawn on a 0-referenced scale.
      final meter = LevelMeter();
      final reading = meter.addPcmS16le(pcm(<int>[-32768, 0, 0, 0]))!;

      expect(reading.peakDbfs, 0);
      expect(reading.peakSample, 32768);
    });
  });

  group('a sine of known amplitude', () {
    test('half scale is -6.02 dBFS peak and -9.03 dBFS RMS', () {
      final meter = LevelMeter();
      final samples = sine(amplitude: 16384); // 32768 / 2, i.e. -6.02 dBFS.
      final reading = meter.addPcmS16le(pcm(samples))!;

      // 20*log10(16384/32767) = -6.0197 dB; the rounding to whole samples
      // moves it by well under a hundredth of a dB.
      expect(reading.peakDbfs, closeTo(-6.02, 0.05));
      // RMS of a sine is its amplitude / sqrt(2), i.e. 3.01 dB below the peak.
      expect(reading.rmsDbfs, closeTo(-9.03, 0.05));
      expect(reading.rmsDbfs, lessThan(reading.peakDbfs));
    });

    test('a tenth of full scale is -20 dBFS peak', () {
      final meter = LevelMeter();
      final reading =
          meter.addPcmS16le(pcm(sine(amplitude: (32767 / 10).round())))!;

      expect(reading.peakDbfs, closeTo(-20, 0.05));
      expect(reading.rmsDbfs, closeTo(-23.01, 0.05));
    });

    test('quieter audio reads lower than louder audio', () {
      final meter = LevelMeter();
      final loud = meter.addPcmS16le(pcm(sine(amplitude: 30000)))!;
      final quiet = meter.addPcmS16le(pcm(sine(amplitude: 300)))!;

      expect(quiet.peakDbfs, lessThan(loud.peakDbfs));
      expect(quiet.rmsDbfs, lessThan(loud.rmsDbfs));
    });
  });

  group('empty blocks', () {
    // A divide-by-zero on an empty accumulator is a bug this project has
    // already been bitten by once, in the firmware. It must be impossible here.
    test('an empty PCM block yields null instead of dividing by zero', () {
      final meter = LevelMeter();
      expect(meter.addPcmS16le(Uint8List(0)), isNull);
      expect(meter.level, isNull);
    });

    test('an empty sample list yields null', () {
      final meter = LevelMeter();
      expect(meter.addSamples(const <int>[]), isNull);
      expect(meter.level, isNull);
    });

    test('a single stray byte is not half a sample', () {
      final meter = LevelMeter();
      expect(meter.addPcmS16le(Uint8List(1)), isNull);
    });

    test('an empty block publishes nothing', () async {
      final meter = LevelMeter();
      final seen = <LevelReading>[];
      final subscription = meter.levels.listen(seen.add);

      meter.addPcmS16le(Uint8List(0));
      await Future<void>.delayed(Duration.zero);
      expect(seen, isEmpty);

      meter.addPcmS16le(pcm(<int>[1000, -1000]));
      await Future<void>.delayed(Duration.zero);
      expect(seen, hasLength(1));

      await subscription.cancel();
      await meter.dispose();
    });

    test('an empty block leaves the previous reading alone', () {
      final meter = LevelMeter();
      final first = meter.addPcmS16le(pcm(sine(amplitude: 8000)))!;
      expect(meter.addPcmS16le(Uint8List(0)), isNull);
      expect(meter.level, same(first));
    });
  });

  group('the meter as the recorder uses it', () {
    test('both entry points agree', () {
      final samples = sine(amplitude: 12345);
      final fromBytes = LevelMeter().addPcmS16le(pcm(samples))!;
      final fromSamples = LevelMeter().addSamples(samples)!;

      expect(fromBytes, equals(fromSamples));
      expect(fromBytes.sampleCount, samples.length);
    });

    test('every block is published in order', () async {
      final meter = LevelMeter();
      final seen = <double>[];
      final subscription = meter.levels.listen((r) => seen.add(r.peakDbfs));

      for (final amplitude in <int>[100, 1000, 10000]) {
        meter.addPcmS16le(pcm(sine(amplitude: amplitude)));
      }
      await Future<void>.delayed(Duration.zero);

      expect(seen, hasLength(3));
      expect(seen[0], lessThan(seen[1]));
      expect(seen[1], lessThan(seen[2]));

      await subscription.cancel();
      await meter.dispose();
    });

    test('reset forgets the last reading, as a new capture requires', () {
      final meter = LevelMeter();
      meter.addPcmS16le(pcm(sine(amplitude: 5000)));
      expect(meter.level, isNotNull);
      meter.reset();
      expect(meter.level, isNull);
    });

    test('a disposed meter publishes nothing further', () async {
      final meter = LevelMeter();
      await meter.dispose();
      expect(meter.addPcmS16le(pcm(<int>[1, 2])), isNotNull);
      expect(meter.level, isNotNull);
    });
  });
}
