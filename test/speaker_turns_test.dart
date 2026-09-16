import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/diarization.dart';
import 'package:voicenotetaker_app/model/loudness_profile.dart';
import 'package:voicenotetaker_app/model/speaker_turns.dart';
import 'package:voicenotetaker_app/model/transcription.dart';

/// The rules that turn what a diarizer heard into turns and windows.
///
/// One group per bullet of [SpeakerTurns.clean], because each of them is a
/// decision someone could reasonably have made differently.
void main() {
  const rate = 16000;
  int s(double seconds) => (seconds * rate).round();

  SpeakerTurn turn(double start, double end, int speaker) =>
      SpeakerTurn(start: s(start), end: s(end), speaker: speaker);

  List<SpeakerTurn> clean(List<SpeakerTurn> turns, double total) =>
      SpeakerTurns.clean(
        turns: turns,
        totalSamples: s(total),
        sampleRateHz: rate,
      );

  group('clean: overlaps', () {
    test('two speakers overlapping are cut at the middle of the overlap', () {
      final result = clean(
        <SpeakerTurn>[turn(0, 6, 0), turn(5, 12, 1)],
        12,
      );

      expect(result, hasLength(2));
      expect(result[0].speaker, 0);
      expect(result[1].speaker, 1);
      // The overlap is 5 s - 6 s, so the cut is at 5.5 s.
      expect(result[0].end, s(5.5));
      expect(result[1].start, s(5.5));
    });

    test('the same speaker twice over is one turn, not a cut', () {
      final result = clean(
        <SpeakerTurn>[turn(0, 6, 0), turn(5, 12, 0)],
        12,
      );

      expect(result, hasLength(1));
      expect(result.single.start, 0);
      expect(result.single.end, s(12));
    });

    test('a turn swallowed whole by another speaker keeps only the tail', () {
      final result = clean(
        <SpeakerTurn>[turn(0, 12, 0), turn(4, 5, 1)],
        12,
      );

      // The short one is folded away (under a second, and under two seconds in
      // the whole note), so one speaker is left with all of it.
      expect(result, hasLength(1));
      expect(result.single.speaker, 0);
      expect(result.single.end, s(12));
    });
  });

  group('clean: same speaker across a pause', () {
    test('a gap under a second joins two turns of one speaker', () {
      final result = clean(
        <SpeakerTurn>[turn(0, 4, 0), turn(4.5, 10, 0)],
        10,
      );

      expect(result, hasLength(1));
      expect(result.single.end, s(10));
    });

    test('another speaker in between keeps them apart', () {
      final result = clean(
        <SpeakerTurn>[turn(0, 5, 0), turn(5, 10, 1), turn(10, 16, 0)],
        16,
      );

      expect(
        result.map((t) => t.speaker).toList(),
        <int>[0, 1, 0],
      );
    });
  });

  group('clean: turns too short to be anyone\'s', () {
    test('a turn under a second joins the longer neighbour', () {
      final result = clean(
        <SpeakerTurn>[turn(0, 5, 0), turn(5, 5.6, 2), turn(5.6, 14, 1)],
        14,
      );

      expect(result, hasLength(2));
      expect(result[0].speaker, 0);
      expect(result[1].speaker, 1);
      // The short turn's audio went to the neighbour it joined, not away.
      expect(result[1].start, s(5));
      expect(result[1].end, s(14));
    });

    test('the closer neighbour wins over the longer one', () {
      final result = clean(
        <SpeakerTurn>[
          turn(0, 9, 0),
          // 2 s after the first, touching the third.
          turn(11, 11.5, 2),
          turn(11.5, 17, 1),
        ],
        17,
      );

      expect(result.map((t) => t.speaker).toList(), <int>[0, 1]);
      expect(result[1].end, s(17));
    });

    test('one short turn on its own is left alone', () {
      final result = clean(<SpeakerTurn>[turn(0, 0.5, 0)], 0.5);

      expect(result, hasLength(1));
      expect(result.single.speaker, 0);
    });
  });

  group('clean: speakers heard for too little', () {
    test('under two seconds in the whole note is not a speaker', () {
      final result = clean(
        <SpeakerTurn>[turn(0, 10, 0), turn(10, 11.5, 1), turn(11.5, 21, 2)],
        21,
      );

      // S1 spoke for 1.5 s: long enough to be a turn, too little to be a
      // person. It joins the longer neighbour, which is the first.
      expect(result.map((t) => t.speaker).toList(), <int>[0, 2]);
      expect(result[0].end, s(11.5));
    });

    test('two seconds or more is kept', () {
      final result = clean(
        <SpeakerTurn>[turn(0, 10, 0), turn(10, 12, 1), turn(12, 22, 2)],
        22,
      );

      expect(result.map((t) => t.speaker).toList(), <int>[0, 1, 2]);
    });

    test('the only speaker is never folded away', () {
      final result = clean(<SpeakerTurn>[turn(0, 1.2, 0)], 1.2);

      expect(result, hasLength(1));
    });
  });

  group('clean: no audio is dropped', () {
    test('the turns cover the recording end to end, with no holes', () {
      final result = clean(
        <SpeakerTurn>[turn(1, 3, 0), turn(5, 11, 1)],
        14,
      );

      expect(result.first.start, 0);
      expect(result.last.end, s(14));
      for (var i = 0; i + 1 < result.length; i++) {
        expect(result[i].end, result[i + 1].start);
      }
      // The gap between them is split down the middle: 3 s to 5 s.
      expect(result[0].end, s(4));
    });

    test('nothing in, nothing out', () {
      expect(clean(const <SpeakerTurn>[], 10), isEmpty);
    });

    test('turns past the end of the audio are clamped away', () {
      final result = clean(
        <SpeakerTurn>[turn(0, 5, 0), turn(20, 30, 1)],
        5,
      );

      expect(result, hasLength(1));
      expect(result.single.end, s(5));
    });
  });

  group('labels', () {
    test('S1 is whoever speaks first, whatever the engine numbered them', () {
      final labels = SpeakerTurns.labels(<SpeakerTurn>[
        turn(0, 5, 7),
        turn(5, 10, 3),
        turn(10, 15, 7),
        turn(15, 20, 1),
      ]);

      expect(labels, <int, String>{7: 'S1', 3: 'S2', 1: 'S3'});
    });

    test('the same turns always label the same way', () {
      final turns = <SpeakerTurn>[turn(0, 5, 2), turn(5, 10, 0)];

      expect(SpeakerTurns.labels(turns), SpeakerTurns.labels(turns));
    });

    test('no turns, no labels', () {
      expect(SpeakerTurns.labels(const <SpeakerTurn>[]), isEmpty);
    });
  });

  group('plan', () {
    const model = SpeechModels.indicConformerHindiInt8;

    test('a turn inside the window is one window', () {
      final windows = SpeakerTurns.planForModel(
        turns: <SpeakerTurn>[turn(0, 8, 0)],
        model: model,
      );

      expect(windows, <SpeakerWindow>[
        SpeakerWindow(range: SampleRange(0, s(8)), speaker: 0),
      ]);
    });

    test('a long turn is cut on the window without a quiet point', () {
      final windows = SpeakerTurns.planForModel(
        turns: <SpeakerTurn>[turn(0, 20, 0)],
        model: model,
      );

      expect(
        windows.map((w) => w.range).toList(),
        <SampleRange>[
          SampleRange(0, s(8)),
          SampleRange(s(8), s(16)),
          SampleRange(s(16), s(20)),
        ],
      );
    });

    test('a long turn is cut at the quietest moment between 6 s and 8 s', () {
      final asked = <List<int>>[];
      final windows = SpeakerTurns.planForModel(
        turns: <SpeakerTurn>[turn(0, 12, 4)],
        model: model,
        quietestSplit: (start, end) {
          asked.add(<int>[start, end]);
          return s(6.5);
        },
      );

      expect(asked, <List<int>>[
        <int>[s(6), s(8)],
      ]);
      expect(
        windows.map((w) => w.range).toList(),
        <SampleRange>[
          SampleRange(0, s(6.5)),
          SampleRange(s(6.5), s(12)),
        ],
      );
      expect(windows.every((w) => w.speaker == 4), isTrue);
    });

    test('a split point outside the range is ignored', () {
      final windows = SpeakerTurns.planForModel(
        turns: <SpeakerTurn>[turn(0, 12, 0)],
        model: model,
        quietestSplit: (start, end) => s(2),
      );

      expect(windows.first.range, SampleRange(0, s(8)));
    });

    test('every window has one speaker and the turns are covered whole', () {
      final turns = <SpeakerTurn>[turn(0, 19, 0), turn(19, 25, 1)];
      final windows = SpeakerTurns.planForModel(turns: turns, model: model);

      expect(windows.first.range.start, 0);
      expect(windows.last.range.end, s(25));
      for (var i = 0; i + 1 < windows.length; i++) {
        expect(windows[i].range.end, windows[i + 1].range.start);
      }
      expect(
        windows.where((w) => w.speaker == 1).map((w) => w.range).toList(),
        <SampleRange>[SampleRange(s(19), s(25))],
      );
    });

    test('nothing to plan', () {
      expect(
        SpeakerTurns.planForModel(turns: const <SpeakerTurn>[], model: model),
        isEmpty,
      );
    });
  });

  group('LoudnessProfile', () {
    test('finds the middle of the quietest stretch', () {
      // Ten frames of 100 samples: loud, with a dip at frames 4 and 5.
      final profile = LoudnessProfile(
        frameSamples: 100,
        frames: <int>[900, 900, 900, 900, 10, 10, 900, 900, 900, 900],
      );

      // A 200-sample probe over the whole profile lands on frames 4-5, whose
      // middle is sample 400 + 100.
      expect(profile.quietestSplit(0, 1000, 200), 500);
    });

    test('only looks inside the range it is given', () {
      final profile = LoudnessProfile(
        frameSamples: 100,
        frames: <int>[10, 10, 900, 900, 900, 500, 500, 900, 900, 900],
      );

      expect(profile.quietestSplit(400, 1000, 200), 600);
    });

    test('nothing measured, nothing to say', () {
      expect(LoudnessProfile.empty.quietestSplit(0, 1000, 200), isNull);
    });

    test('a range too small for the probe answers nothing', () {
      final profile = LoudnessProfile(
        frameSamples: 100,
        frames: <int>[10, 20, 30, 40],
      );

      expect(profile.quietestSplit(0, 150, 200), isNull);
    });
  });
}
