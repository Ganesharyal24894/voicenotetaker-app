import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/diarization.dart';
import 'package:voicenotetaker_app/model/enrolment_check.dart';
import 'package:voicenotetaker_app/model/transcription.dart';

const int rate = 16000;
int s(double seconds) => (seconds * rate).round();

SpeakerTurn turn(double from, double to, [int speaker = 0]) =>
    SpeakerTurn(start: s(from), end: s(to), speaker: speaker);

List<double> along(int axis) =>
    List<double>.generate(192, (i) => i == axis ? 1.0 : 0.0);

/// The owner's guided recording: when it is taken, and why it is not.
void main() {
  final aMinute = <SpeakerTurn>[turn(0, 30), turn(31, 61)];

  group('screen', () {
    test('a lost link decides it before anything else', () {
      expect(
        EnrolmentCheck.screen(raw: aMinute, sampleRateHz: rate, linkLost: true),
        EnrolmentProblem.linkLost,
      );
    });

    test('under 45 s of talking is too short, however long the recording',
        () {
      expect(
        EnrolmentCheck.screen(
          raw: <SpeakerTurn>[turn(0, 20), turn(40, 64)],
          sampleRateHz: rate,
        ),
        EnrolmentProblem.tooShort,
      );
    });

    test('nobody heard at all is too short, not a crash', () {
      expect(
        EnrolmentCheck.screen(raw: const <SpeakerTurn>[], sampleRateHz: rate),
        EnrolmentProblem.tooShort,
      );
    });

    test('a second voice over a tenth of the talking is not alone', () {
      expect(
        EnrolmentCheck.screen(
          raw: <SpeakerTurn>[turn(0, 50), turn(50, 60, 1)],
          sampleRateHz: rate,
        ),
        EnrolmentProblem.notAlone,
      );
      expect(
        EnrolmentCheck.screen(
          raw: <SpeakerTurn>[turn(0, 57), turn(57, 60, 1)],
          sampleRateHz: rate,
        ),
        isNull,
        reason: 'a cough from someone else is 5 %',
      );
    });

    test('overlapping segments of one speaker are counted once', () {
      expect(EnrolmentCheck.speechOf(<SpeakerTurn>[turn(0, 30), turn(20, 50)]),
          <int, int>{0: s(50)});
    });
  });

  group('chunks', () {
    test('the main voice, six seconds of speech at a time, across pauses',
        () {
      final chunks = EnrolmentCheck.chunks(
        raw: <SpeakerTurn>[turn(0, 4), turn(10, 18), turn(4, 5, 1)],
        sampleRateHz: rate,
      );

      expect(chunks, hasLength(2));
      expect(chunks.first, <SampleRange>[
        SampleRange(0, s(4)),
        SampleRange(s(10), s(12)),
      ]);
      expect(chunks.last, <SampleRange>[SampleRange(s(12), s(18))]);
    });

    test('a last piece under three seconds and slivers are left out', () {
      final chunks = EnrolmentCheck.chunks(
        raw: <SpeakerTurn>[turn(0, 8), turn(9, 10)],
        sampleRateHz: rate,
      );

      expect(chunks, hasLength(1));
    });
  });

  group('verdict', () {
    test('one steady voice for a minute is taken, as the chunks\' mean', () {
      final verdict = EnrolmentCheck.verdict(
        raw: aMinute,
        sampleRateHz: rate,
        embedded: <(List<double>, double)>[
          for (var i = 0; i < 10; i++) (along(0), 6),
        ],
      );

      expect(verdict.ok, isTrue);
      expect(verdict.embedding![0], closeTo(1, 1e-6));
      expect(verdict.speech, const Duration(seconds: 60));
    });

    test('a chunk far from the rest means someone else was folded in', () {
      final verdict = EnrolmentCheck.verdict(
        raw: aMinute,
        sampleRateHz: rate,
        embedded: <(List<double>, double)>[
          for (var i = 0; i < 9; i++) (along(0), 6),
          (along(1), 6),
        ],
      );

      expect(verdict.problem, EnrolmentProblem.notAlone);
      expect(verdict.embedding, isNull);
    });

    test('too short says how much was heard', () {
      final verdict = EnrolmentCheck.verdict(
        raw: <SpeakerTurn>[turn(0, 20)],
        sampleRateHz: rate,
        embedded: const <(List<double>, double)>[],
      );

      expect(verdict.problem, EnrolmentProblem.tooShort);
      expect(verdict.speech, const Duration(seconds: 20));
    });

    test('a lost link wins over a good recording', () {
      final verdict = EnrolmentCheck.verdict(
        raw: aMinute,
        sampleRateHz: rate,
        embedded: <(List<double>, double)>[(along(0), 60)],
        linkLost: true,
      );

      expect(verdict.problem, EnrolmentProblem.linkLost);
    });
  });
}
