import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/diarization.dart';
import 'package:voicenotetaker_app/model/transcription.dart';
import 'package:voicenotetaker_app/model/voice_match.dart';
import 'package:voicenotetaker_app/model/voice_turns.dart';

/// Which speech of a note is embedded. At 1000 Hz a sample is a millisecond,
/// so every number below reads as time.
void main() {
  const rate = 1000;
  SpeakerTurn t(int start, int end, [int speaker = 0]) =>
      SpeakerTurn(start: start, end: end, speaker: speaker);
  List<VoiceTurnPick> select(
    List<SpeakerTurn> raw,
    List<SpeakerTurn> cleaned,
  ) => VoiceTurns.select(raw: raw, cleaned: cleaned, sampleRateHz: rate);

  test('the constants are the documented defaults', () {
    expect(VoiceMatch.minPiece, const Duration(milliseconds: 1500));
    expect(VoiceMatch.maxPerTurn, const Duration(seconds: 8));
    expect(VoiceMatch.maxTurns, 64);
    expect(VoiceMatch.minPerLabel, 3);
  });

  test('one pick per cleaned turn, in order, carrying the turn', () {
    final cleaned = <SpeakerTurn>[t(0, 5000), t(5000, 9000, 1)];
    final picks = select(cleaned, cleaned);
    expect(picks.map((p) => p.turn), cleaned);
  });

  group('rule 1: raw speech of the turn\'s own speaker, inside the turn', () {
    test('silence the cleaning stretched over is left out', () {
      final picks = select(
        <SpeakerTurn>[t(1000, 4000), t(6000, 9000)],
        <SpeakerTurn>[t(0, 10000)],
      );
      expect(picks.single.pieces, const <SampleRange>[
        SampleRange(1000, 4000),
        SampleRange(6000, 9000),
      ]);
    });

    test('another speaker folded into the turn is left out', () {
      final picks = select(
        <SpeakerTurn>[t(0, 3000), t(3000, 3800, 1), t(3800, 7000)],
        <SpeakerTurn>[t(0, 7000)],
      );
      expect(picks.single.pieces, const <SampleRange>[
        SampleRange(0, 3000),
        SampleRange(3800, 7000),
      ]);
    });

    test('raw speech is clipped to the turn', () {
      final picks = select(
        <SpeakerTurn>[t(0, 6000), t(4000, 9000, 1)],
        <SpeakerTurn>[t(0, 5000), t(5000, 9000, 1)],
      );
      expect(picks[0].pieces, const <SampleRange>[SampleRange(0, 5000)]);
      expect(picks[1].pieces, const <SampleRange>[SampleRange(5000, 9000)]);
    });

    test('one speaker\'s overlapping or touching segments are joined', () {
      final picks = select(
        <SpeakerTurn>[t(0, 1000), t(1000, 2000), t(1500, 3000)],
        <SpeakerTurn>[t(0, 4000)],
      );
      expect(picks.single.pieces, const <SampleRange>[SampleRange(0, 3000)]);
    });
  });

  group('rule 2: short pieces', () {
    test('under minPiece is dropped, minPiece itself is kept', () {
      final picks = select(
        <SpeakerTurn>[t(0, 1499), t(3000, 4500)],
        <SpeakerTurn>[t(0, 5000)],
      );
      expect(picks.single.pieces, const <SampleRange>[SampleRange(3000, 4500)]);
    });

    test('a turn with only short pieces is not embedded', () {
      final picks = select(
        <SpeakerTurn>[t(0, 1000), t(2000, 3000)],
        <SpeakerTurn>[t(0, 4000)],
      );
      expect(picks.single.pieces, isEmpty);
      expect(picks.single.samples, 0);
    });
  });

  group('rule 3: the middle maxPerTurn of a long turn', () {
    test('one long piece keeps its middle 8 s', () {
      final picks = select(
        <SpeakerTurn>[t(0, 20000)],
        <SpeakerTurn>[t(0, 20000)],
      );
      expect(picks.single.pieces, const <SampleRange>[
        SampleRange(6000, 14000),
      ]);
    });

    test('the middle is of the speech, not of the clock', () {
      // 10 s + 10 s of speech with a 30 s pause between: the middle 8 s are
      // the last 4 s of the first piece and the first 4 s of the second.
      final picks = select(
        <SpeakerTurn>[t(0, 10000), t(40000, 50000)],
        <SpeakerTurn>[t(0, 50000)],
      );
      expect(picks.single.pieces, const <SampleRange>[
        SampleRange(6000, 10000),
        SampleRange(40000, 44000),
      ]);
      expect(picks.single.samples, 8000);
    });

    test('a piece wholly outside the middle is not reached', () {
      // 1.6 s + 10 s = 11.6 s of speech, middle [1.8 s, 9.8 s): all of it in
      // the second piece.
      final picks = select(
        <SpeakerTurn>[t(0, 1600), t(5000, 15000)],
        <SpeakerTurn>[t(0, 16000)],
      );
      expect(picks.single.pieces, const <SampleRange>[
        SampleRange(5200, 13200),
      ]);
    });

    test('a piece the cut leaves at minPiece stays', () {
      // 3 s + 8 s = 11 s, middle [1.5 s, 9.5 s): 1.5 s of the first piece and
      // 6.5 s of the second.
      final picks = select(
        <SpeakerTurn>[t(0, 3000), t(5000, 13000)],
        <SpeakerTurn>[t(0, 14000)],
      );
      expect(picks.single.pieces, const <SampleRange>[
        SampleRange(1500, 3000),
        SampleRange(5000, 11500),
      ]);
    });

    test('a sliver the cut leaves under minPiece goes', () {
      // 2.8 s + 8 s = 10.8 s, middle [1.4 s, 9.4 s): 1.4 s of the first piece
      // is too short and goes; 6.6 s of the second stays.
      final picks = select(
        <SpeakerTurn>[t(0, 2800), t(5000, 13000)],
        <SpeakerTurn>[t(0, 14000)],
      );
      expect(picks.single.pieces, const <SampleRange>[
        SampleRange(5000, 11600),
      ]);
    });
  });

  group('rule 4: how many turns', () {
    List<SpeakerTurn> turnsOf(List<(int length, int speaker)> spec) {
      final out = <SpeakerTurn>[];
      var at = 0;
      for (final (length, speaker) in spec) {
        out.add(t(at, at + length, speaker));
        at += length + 1000;
      }
      return out;
    }

    test('at most maxTurns, longest first', () {
      final turns = turnsOf(<(int, int)>[
        for (var i = 0; i < 70; i++) (2000 + i * 10, 0),
      ]);
      final picks = select(turns, turns);
      final picked = <int>[
        for (var i = 0; i < picks.length; i++)
          if (picks[i].pieces.isNotEmpty) i,
      ];
      expect(picked, hasLength(VoiceMatch.maxTurns));
      // The six shortest - the first six - are the ones left out.
      expect(picked.first, 6);
    });

    test('each label gets minPerLabel where it has them, even short ones', () {
      final turns = turnsOf(<(int, int)>[
        for (var i = 0; i < 66; i++) (5000, 0),
        for (var i = 0; i < 4; i++) (2000, 1),
      ]);
      final picks = select(turns, turns);
      final bySpeaker = <int, int>{};
      for (final pick in picks.where((p) => p.pieces.isNotEmpty)) {
        bySpeaker[pick.turn.speaker] = (bySpeaker[pick.turn.speaker] ?? 0) + 1;
      }
      expect(bySpeaker[1], VoiceMatch.minPerLabel);
      expect(bySpeaker[0], VoiceMatch.maxTurns - VoiceMatch.minPerLabel);
    });

    test('a label with fewer turns gives what it has', () {
      final turns = turnsOf(<(int, int)>[
        for (var i = 0; i < 70; i++) (5000, 0),
        (2000, 1),
      ]);
      final picks = select(turns, turns);
      expect(picks.last.pieces, isNotEmpty);
      expect(picks.where((p) => p.pieces.isNotEmpty), hasLength(64));
    });

    test('more labels than the cap allows: every label still gets turns, in '
        'rounds', () {
      // 30 labels x 3 turns = 90 > 64: two rounds of 30, then 4 more.
      final turns = turnsOf(<(int, int)>[
        for (var round = 0; round < 3; round++)
          for (var speaker = 0; speaker < 30; speaker++) (2000, speaker),
      ]);
      final picks = select(turns, turns);
      final bySpeaker = <int, int>{};
      for (final pick in picks.where((p) => p.pieces.isNotEmpty)) {
        bySpeaker[pick.turn.speaker] = (bySpeaker[pick.turn.speaker] ?? 0) + 1;
      }
      expect(bySpeaker.length, 30);
      expect(bySpeaker.values.every((n) => n >= 2), isTrue);
      expect(picks.where((p) => p.pieces.isNotEmpty), hasLength(64));
    });
  });

  test('a sample rate of zero is refused', () {
    expect(
      () => VoiceTurns.select(
        raw: const <SpeakerTurn>[],
        cleaned: const <SpeakerTurn>[],
        sampleRateHz: 0,
      ),
      throwsArgumentError,
    );
  });

  test('nothing in, nothing out', () {
    expect(select(const <SpeakerTurn>[], const <SpeakerTurn>[]), isEmpty);
    expect(
      select(const <SpeakerTurn>[], <SpeakerTurn>[t(0, 5000)]).single.pieces,
      isEmpty,
    );
  });
}
