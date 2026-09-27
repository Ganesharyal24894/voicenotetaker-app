import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/diarization.dart';
import 'package:voicenotetaker_app/model/transcription.dart';

/// `SpeakerTurn.fromSeconds` and `DiarizationProgress.fraction`: the two places
/// in `model/diarization.dart` that make a decision rather than hold a value.
///
/// Both sit directly behind the engine. `speaker_diarizer_sherpa.dart` hands
/// `fromSeconds` whatever sherpa-onnx said - floating-point seconds it has no
/// say over - and every window the transcript is later cut into comes out of
/// the sample indices it returns. `speaker_turns_test.dart` covers what happens
/// to the turns AFTER this, with turns written by hand; nothing covers the
/// conversion itself.
void main() {
  const rate = 16000;

  group('seconds from the engine, samples for the file', () {
    test('a whole number of seconds is the sample the file seeks to', () {
      final turn = SpeakerTurn.fromSeconds(
        start: 1.5,
        end: 3.25,
        speaker: 1,
        sampleRateHz: rate,
      );

      expect(turn.start, 24000);
      expect(turn.end, 52000);
      expect(turn.speaker, 1);
      expect(turn.length, 28000);
      expect(turn.range, const SampleRange(24000, 52000));
    });

    test('a fraction of a sample is rounded, not thrown away', () {
      // Truncating would bias every boundary earlier, and the bias accumulates
      // across a long recording: the windows would drift away from the speech
      // they were cut for.
      expect(
        SpeakerTurn.fromSeconds(
          start: 0.00006,
          end: 1.00006,
          speaker: 0,
          sampleRateHz: rate,
        ),
        // 0.96 and 16000.96 samples.
        const SpeakerTurn(start: 1, end: 16001, speaker: 0),
      );
      expect(
        SpeakerTurn.fromSeconds(
          start: 0.00003,
          end: 1.0,
          speaker: 0,
          sampleRateHz: rate,
        ).start,
        // 0.48 samples.
        0,
      );
    });

    test('a turn that ends before it starts becomes an empty one', () {
      // The factory exists to sanitise what the engine said. A turn with
      // end < start would fail SampleRange's own assertion the moment the
      // planner touched it, and in release it would read a negative number of
      // bytes out of the recording.
      final turn = SpeakerTurn.fromSeconds(
        start: 0.4,
        end: 0.3,
        speaker: 2,
        sampleRateHz: rate,
      );

      expect(turn.start, 6400);
      expect(turn.end, 6400);
      expect(turn.length, 0);
    });

    test('a start a shade before zero is pulled up to zero', () {
      final turn = SpeakerTurn.fromSeconds(
        start: -0.001,
        end: 1.0,
        speaker: 0,
        sampleRateHz: rate,
      );

      expect(turn.start, 0);
      expect(turn.end, rate);
    });

    test('a turn wholly before zero is clamped rather than thrown', () {
      // FAILS TODAY, and it is the code that is wrong, not the test. See the
      // report: `end` is compared against the UNCLAMPED start, so a wholly
      // negative range keeps a negative end while the start is pulled up to
      // zero, and the constructor's `assert(end >= start)` fires. The factory
      // whose entire purpose is to sanitise engine output is the one thing that
      // crashes on bad engine output.
      final turn = SpeakerTurn.fromSeconds(
        start: -1.0,
        end: -0.5,
        speaker: 0,
        sampleRateHz: rate,
      );

      expect(turn.start, 0);
      expect(turn.end, 0);
    });

    test('the sample rate is the recording\'s, not an assumption', () {
      // Every model in the catalogue is 16 kHz today, so a hardcoded rate would
      // pass every other test in the repo and break the day one is not.
      expect(
        SpeakerTurn.fromSeconds(
          start: 1,
          end: 2,
          speaker: 0,
          sampleRateHz: 8000,
        ),
        const SpeakerTurn(start: 8000, end: 16000, speaker: 0),
      );
    });
  });

  group('a turn on its own', () {
    const turn = SpeakerTurn(start: 100, end: 500, speaker: 1);

    test('copying it replaces only what is named', () {
      expect(turn.copyWith(speaker: 2),
          const SpeakerTurn(start: 100, end: 500, speaker: 2));
      expect(turn.copyWith(end: 600),
          const SpeakerTurn(start: 100, end: 600, speaker: 1));
      expect(turn.copyWith(), turn);
    });

    test('two turns with the same numbers are the same turn', () {
      // The cleaner merges and drops turns by comparing them, so this is what
      // makes `SpeakerTurns.clean` able to tell that it changed nothing.
      expect(turn, const SpeakerTurn(start: 100, end: 500, speaker: 1));
      expect(turn.hashCode,
          const SpeakerTurn(start: 100, end: 500, speaker: 1).hashCode);
      expect(turn, isNot(const SpeakerTurn(start: 100, end: 500, speaker: 2)));
      expect(turn.toString(), 'SpeakerTurn(100-500, speaker 1)');
    });

    test('an empty turn is allowed but a backwards one is not', () {
      expect(const SpeakerTurn(start: 5, end: 5, speaker: 0).length, 0);
      expect(() => SpeakerTurn(start: 5, end: 4, speaker: 0),
          throwsA(isA<AssertionError>()));
      expect(() => SpeakerTurn(start: -1, end: 4, speaker: 0),
          throwsA(isA<AssertionError>()));
    });
  });

  group('how far through the engine says it is', () {
    test('it is a fraction between zero and one', () {
      expect(const DiarizationProgress(done: 0, total: 4).fraction, 0);
      expect(const DiarizationProgress(done: 1, total: 4).fraction, 0.25);
      expect(const DiarizationProgress(done: 4, total: 4).fraction, 1);
    });

    test('a total the engine has not worked out yet reads as nothing done', () {
      // Not null: the bar shows empty rather than disappearing.
      expect(const DiarizationProgress(done: 0, total: 0).fraction, 0);
      expect(const DiarizationProgress(done: 3, total: 0).fraction, 0);
      expect(const DiarizationProgress(done: 3, total: -1).fraction, 0);
    });

    test('a count past the total does not push the bar off the end', () {
      // sherpa-onnx counts its own windows and has over-run its estimate
      // before; a fraction above one is a progress bar wider than its box.
      expect(const DiarizationProgress(done: 9, total: 4).fraction, 1);
      expect(const DiarizationProgress(done: -1, total: 4).fraction, 0);
    });
  });

  test('the diarization model is two files and their sum', () {
    const model = DiarizationModels.pyannoteCamPlus;

    expect(model.files,
        <SpeechModelFile>[model.segmentationFile, model.embeddingFile]);
    expect(model.totalBytes,
        model.segmentationFile.sizeBytes + model.embeddingFile.sizeBytes);
    expect(model.toString(), 'DiarizationModel(${model.id})');
  });

  test('a speaker window is compared by its range and its cluster', () {
    const window = SpeakerWindow(range: SampleRange(0, 80), speaker: 0);

    expect(window, const SpeakerWindow(range: SampleRange(0, 80), speaker: 0));
    expect(window,
        isNot(const SpeakerWindow(range: SampleRange(0, 80), speaker: 1)));
    expect(window,
        isNot(const SpeakerWindow(range: SampleRange(0, 81), speaker: 0)));
    expect(window.toString(), 'SpeakerWindow(SampleRange(0, 80), speaker 0)');
  });
}
