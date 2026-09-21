import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/speech_presence.dart';

/// The check that decides a decode window holds nothing but the note's own
/// noise floor.
///
/// Every case here is one of the awkward ones: digital silence, quiet speech,
/// low-frequency rumble, a note that is loud from end to end, and the short
/// window a note finishes on. The rule they all measure is the same - a window
/// is skipped ONLY when it is certainly nothing but floor, and everything
/// unknown or arguable is decoded.
void main() {
  const rate = 16000;
  final block = SpeechPresence.frameSamples(rate);

  /// [seconds] of sound shaped by [value] and scaled to exactly [dbfs] RMS, so
  /// every level in this file can be reasoned about in decibels.
  Float32List at(double seconds, double Function(int i) value, double dbfs) {
    final count = (seconds * rate).round();
    final raw = List<double>.generate(count, value);
    var sum = 0.0;
    for (final sample in raw) {
      sum += sample * sample;
    }
    final rms = math.sqrt(sum / count);
    final want = math.pow(10, dbfs / 20).toDouble();
    final scale = rms == 0 ? 0.0 : want / rms;
    return Float32List.fromList(<double>[for (final s in raw) s * scale]);
  }

  /// Deterministic white noise: the stand-in for a room.
  Float32List noise(double seconds, double dbfs, {int seed = 7}) {
    final random = math.Random(seed);
    return at(seconds, (_) => random.nextDouble() * 2 - 1, dbfs);
  }

  /// Voice-shaped sound: energy where formants are, opened and closed at 5 Hz
  /// the way syllables are. Not speech, but it has the two properties this
  /// check reads - energy above 300 Hz, and a level that rises clear of the
  /// room it is in.
  Float32List speech(double seconds, double dbfs) => at(seconds, (i) {
        final t = i / rate;
        var value = 0.0;
        for (final formant in <double>[420, 900, 1800, 2600]) {
          value += math.sin(2 * math.pi * formant * t);
        }
        return value * (0.55 + 0.45 * math.sin(2 * math.pi * 5 * t));
      }, dbfs);

  /// A desk thump, a fan, a shirt over the microphone: loud, all of it at
  /// 40 Hz.
  Float32List rumble(double seconds, double dbfs) => at(
        seconds,
        (i) => math.sin(2 * math.pi * 40 * i / rate),
        dbfs,
      );

  Float32List silence(double seconds) => Float32List((seconds * rate).round());

  Float32List join(List<Float32List> parts) {
    final out = Float32List(parts.fold(0, (sum, part) => sum + part.length));
    var at = 0;
    for (final part in parts) {
      out.setAll(at, part);
      at += part.length;
    }
    return out;
  }

  double? floorOf(Float32List note) =>
      (NoiseFloor(sampleRateHz: rate)..add(note)).dbfs;

  bool decodes(Float32List window, double? floor) =>
      SpeechPresence.canContainSpeech(
        samples: window,
        sampleRateHz: rate,
        noiseFloorDbfs: floor,
      );

  group('a window that cannot hold speech is skipped', () {
    test('digital silence, in a note that is nothing but digital silence', () {
      final note = silence(30);
      expect(floorOf(note), SpeechPresence.silenceDbfs);
      expect(decodes(silence(16), floorOf(note)), isFalse);
    });

    test('digital silence, in a note that is otherwise a live room', () {
      // The dead second is a fortieth of the note, so the floor is the room's
      // and the silence is judged against a real level, not against itself.
      final note = join(<Float32List>[
        noise(20, -60),
        speech(20, -35),
        silence(1),
      ]);
      expect(floorOf(note)!, greaterThan(-70));
      expect(decodes(silence(1), floorOf(note)), isFalse);
    });

    test('low-frequency rumble only - loud, and none of it speech', () {
      // A thump against the microphone in the middle of a real note. It is
      // 30 dB louder than the room on a level meter and still skipped,
      // because a 40 Hz sine carries no speech: below 300 Hz there is nothing
      // a word is made of, and the high-pass every level here is measured
      // through reads it 35 dB quieter than the room it interrupted.
      final note = join(<Float32List>[
        noise(60, -60),
        speech(20, -35),
        rumble(2, -30),
      ]);
      // 30 dB louder than the room, measured the way a level meter would.
      expect(
        SpeechPresence.dbfs(_rms(rumble(1, -30))) -
            SpeechPresence.dbfs(_rms(noise(1, -60))),
        closeTo(30, 0.5),
      );
      expect(decodes(rumble(2, -30), floorOf(note)), isFalse);
    });

    test('a window quieter than the material the note is floored on', () {
      final note = join(<Float32List>[noise(40, -50), speech(10, -30)]);
      expect(decodes(noise(16, -58, seed: 5), floorOf(note)), isFalse);
    });
  });

  group('a window that might hold speech is always decoded', () {
    test('quiet speech, 10 dB over a quiet room', () {
      final note = join(<Float32List>[noise(20, -70), speech(16, -60)]);
      expect(decodes(speech(16, -60), floorOf(note)), isTrue);
    });

    test('quiet speech in a note whose floor is high from end to end', () {
      // A fan two feet away: the whole note is loud, so the floor is loud, and
      // a window may not be skipped for failing to stand out from it.
      final note = join(<Float32List>[
        noise(30, -30),
        speech(16, -15),
        noise(30, -30, seed: 5),
      ]);
      final floor = floorOf(note)!;
      expect(floor, greaterThan(-40), reason: 'the floor really is high');
      expect(decodes(speech(16, -15), floor), isTrue);
    });

    test('one second of speech in fifteen seconds of quiet', () {
      final note = join(<Float32List>[noise(30, -60), speech(1, -40)]);
      final window = join(<Float32List>[
        noise(7.5, -60, seed: 2),
        speech(1, -40),
        noise(7.5, -60, seed: 4),
      ]);
      expect(decodes(window, floorOf(note)), isTrue);
    });

    test('room noise the recognizer will make nothing of is still decoded', () {
      // This is the honest limit of the check, and why 44.6 % of the app's
      // segments being empty cannot be turned into 44.6 % fewer decodes: a
      // window of audible room, far speech or handling noise decodes to "" and
      // is nowhere near the floor. Measured on the owner's notes, such windows
      // sit a median 9.6 dB above it.
      final note = join(<Float32List>[noise(20, -60), noise(16, -45, seed: 9)]);
      expect(decodes(noise(16, -45, seed: 9), floorOf(note)), isTrue);
    });

    test('a window shorter than one 20 ms block is never skipped', () {
      expect(decodes(Float32List(block - 1), floorOf(silence(30))), isTrue);
    });

    test('a floor that could not be measured decodes everything', () {
      expect(decodes(silence(16), null), isTrue);
      expect(floorOf(Float32List(block - 1)), isNull);
    });
  });

  group('the short last window of a note', () {
    test('a dead tail is skipped', () {
      final note = join(<Float32List>[
        noise(20, -60),
        speech(6, -35),
        silence(0.3),
      ]);
      expect(decodes(silence(0.3), floorOf(note)), isFalse);
    });

    test('a tail with speech in it is decoded', () {
      final tail = speech(0.3, -45);
      final note = join(<Float32List>[noise(20, -65), tail]);
      expect(decodes(tail, floorOf(note)), isTrue);
    });

    test('a tail of half a block decodes - too little to judge', () {
      final note = join(<Float32List>[noise(20, -60), silence(0.01)]);
      expect(decodes(silence(0.01), floorOf(note)), isTrue);
    });
  });

  group('the floor is the note, however the note arrives', () {
    test('chunked and whole read the same', () {
      final note = join(<Float32List>[
        noise(5, -58),
        speech(3, -30),
        noise(5, -58, seed: 13),
      ]);
      final whole = floorOf(note);
      for (final size in <int>[1, 7, block, block * 3 + 1, rate, 40000]) {
        final chunked = NoiseFloor(sampleRateHz: rate);
        for (var start = 0; start < note.length; start += size) {
          chunked.add(
            Float32List.sublistView(
              note,
              start,
              math.min(start + size, note.length),
            ),
          );
        }
        expect(chunked.dbfs, whole, reason: 'chunks of $size samples');
        expect(chunked.blocks, note.length ~/ block);
      }
    });

    test('the floor is the quiet of the note, not its loudest part', () {
      final note = join(<Float32List>[noise(20, -60), speech(20, -20)]);
      expect(floorOf(note)!, lessThan(-50));
    });

    test('a note that is almost all speech still decodes its speech', () {
      final note = join(<Float32List>[noise(2, -60), speech(38, -30)]);
      expect(decodes(speech(16, -30), floorOf(note)), isTrue);
    });

    test('the trailing part-block is not measured', () {
      expect((NoiseFloor(sampleRateHz: rate)
            ..add(Float32List(block * 4 + 5)))
          .blocks, 4);
    });
  });

  group('the threshold', () {
    test('stays under half the smallest measured speech margin', () {
      // 2.23 dB is the smallest margin over its own note's floor measured on a
      // window that produced text, across 949 such windows from the owner's
      // recordings. Raising this past half of that needs a new measurement,
      // not an opinion.
      expect(SpeechPresence.skipWithinDb, lessThanOrEqualTo(2.23 / 2));
    });

    test('a block is the 20 ms the firmware speech gate judges', () {
      expect(SpeechPresence.frame, const Duration(milliseconds: 20));
      expect(SpeechPresence.frameSamples(16000), 320);
    });
  });
}

double _rms(Float32List samples) {
  var sum = 0.0;
  for (final sample in samples) {
    sum += sample * sample;
  }
  return math.sqrt(sum / samples.length);
}
