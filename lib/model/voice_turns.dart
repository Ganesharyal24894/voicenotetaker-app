/// Which audio of a note is turned into voice embeddings.
///
/// PURE: sample arithmetic in, sample arithmetic out, like `speaker_turns.dart`
/// beside it. Every rule is a test in `test/model/voice_turns_test.dart`.
///
/// WHY NOT THE CLEANED TURNS THEMSELVES. Cleaning stretches every turn over
/// the silence around it so the transcript has no holes; an embedding of that
/// silence describes the room, not the person. What gets embedded is the
/// diarizer's RAW speech for the turn's own speaker, inside the turn.
library;

import 'diarization.dart';
import 'transcription.dart';
import 'voice_match.dart';

/// One cleaned turn and the speech of it that is embedded.
class VoiceTurnPick {
  VoiceTurnPick({required this.turn, required List<SampleRange> pieces})
    : pieces = List<SampleRange>.unmodifiable(pieces);

  /// The cleaned turn, as the transcript shows it.
  final SpeakerTurn turn;

  /// In time order, none shorter than [VoiceMatch.minPiece]; empty when the
  /// turn is not embedded at all.
  final List<SampleRange> pieces;

  int get samples => pieces.fold<int>(0, (sum, p) => sum + p.length);

  @override
  String toString() => 'VoiceTurnPick($turn, $pieces)';
}

abstract final class VoiceTurns {
  static int _samples(Duration of, int sampleRateHz) =>
      of.inMicroseconds * sampleRateHz ~/ 1000000;

  /// One pick per turn of [cleaned], in the same order.
  ///
  /// THE RULES, in this order - each is a test:
  ///
  ///   1. a turn's pieces are the [raw] segments of ITS OWN speaker, clipped
  ///      to the turn and joined where they touch or overlap - the other
  ///      speakers' audio folded into it by cleaning is left out;
  ///   2. a piece under [VoiceMatch.minPiece] is dropped: too little voice
  ///      for the network to say anything steady;
  ///   3. over [VoiceMatch.maxPerTurn] of speech, the MIDDLE of it is kept -
  ///      a turn's edges sit next to a change of speaker, where the diarizer
  ///      is least sure - and a piece the cut leaves under the minimum goes
  ///      too;
  ///   4. at most [VoiceMatch.maxTurns] turns of the note, longest first,
  ///      except that each label first gets up to [VoiceMatch.minPerLabel]
  ///      of its own longest turns, taken in rounds - every label's longest,
  ///      then every label's second - so a note with more labels than the cap
  ///      allows still embeds every label it can.
  ///
  /// Turns not picked have no pieces: they keep their label in the note but
  /// add nothing to its score.
  static List<VoiceTurnPick> select({
    required List<SpeakerTurn> raw,
    required List<SpeakerTurn> cleaned,
    required int sampleRateHz,
  }) {
    if (sampleRateHz <= 0) {
      throw ArgumentError.value(sampleRateHz, 'sampleRateHz', 'must be > 0');
    }
    final shortest = _samples(VoiceMatch.minPiece, sampleRateHz);
    final cap = _samples(VoiceMatch.maxPerTurn, sampleRateHz);

    final candidates = <List<SampleRange>>[
      for (final turn in cleaned)
        _middle(_speechOf(turn, raw, shortest), cap, shortest),
    ];
    final chosen = _choose(cleaned, candidates);
    return List<VoiceTurnPick>.unmodifiable(<VoiceTurnPick>[
      for (var i = 0; i < cleaned.length; i++)
        VoiceTurnPick(
          turn: cleaned[i],
          pieces: chosen.contains(i) ? candidates[i] : const <SampleRange>[],
        ),
    ]);
  }

  /// Rules 1 and 2.
  static List<SampleRange> _speechOf(
    SpeakerTurn turn,
    List<SpeakerTurn> raw,
    int shortest,
  ) {
    final clipped = <SampleRange>[
      for (final segment in raw)
        if (segment.speaker == turn.speaker &&
            segment.end > turn.start &&
            segment.start < turn.end)
          SampleRange(
            segment.start > turn.start ? segment.start : turn.start,
            segment.end < turn.end ? segment.end : turn.end,
          ),
    ]..sort((a, b) => a.start.compareTo(b.start));
    final joined = <SampleRange>[];
    for (final piece in clipped) {
      if (joined.isNotEmpty && piece.start <= joined.last.end) {
        final last = joined.removeLast();
        joined.add(
          SampleRange(last.start, piece.end > last.end ? piece.end : last.end),
        );
      } else {
        joined.add(piece);
      }
    }
    return <SampleRange>[
      for (final piece in joined)
        if (piece.length >= shortest) piece,
    ];
  }

  /// Rule 3: the middle [cap] samples of the speech, counted in speech time
  /// so pauses between pieces do not pull the middle about.
  static List<SampleRange> _middle(
    List<SampleRange> pieces,
    int cap,
    int shortest,
  ) {
    final total = pieces.fold<int>(0, (sum, p) => sum + p.length);
    if (total <= cap) return pieces;
    final from = (total - cap) ~/ 2;
    final to = from + cap;
    final out = <SampleRange>[];
    var at = 0;
    for (final piece in pieces) {
      final start = from > at ? from - at : 0;
      final end = to - at < piece.length ? to - at : piece.length;
      if (end - start >= shortest) {
        out.add(SampleRange(piece.start + start, piece.start + end));
      }
      at += piece.length;
    }
    return out;
  }

  /// Rule 4: the indices of the turns that are embedded.
  static Set<int> _choose(
    List<SpeakerTurn> cleaned,
    List<List<SampleRange>> candidates,
  ) {
    int length(int i) => candidates[i].fold<int>(0, (s, p) => s + p.length);
    int longestFirst(int a, int b) {
      final byLength = length(b).compareTo(length(a));
      return byLength != 0
          ? byLength
          : cleaned[a].start.compareTo(cleaned[b].start);
    }

    final bySpeaker = <int, List<int>>{};
    for (var i = 0; i < cleaned.length; i++) {
      if (candidates[i].isEmpty) continue;
      (bySpeaker[cleaned[i].speaker] ??= <int>[]).add(i);
    }
    for (final turns in bySpeaker.values) {
      turns.sort(longestFirst);
    }

    final chosen = <int>{};
    for (var round = 0; round < VoiceMatch.minPerLabel; round++) {
      final inRound = <int>[
        for (final turns in bySpeaker.values)
          if (round < turns.length) turns[round],
      ]..sort(longestFirst);
      for (final i in inRound) {
        if (chosen.length >= VoiceMatch.maxTurns) return chosen;
        chosen.add(i);
      }
    }
    final rest = <int>[
      for (final turns in bySpeaker.values)
        for (final i in turns)
          if (!chosen.contains(i)) i,
    ]..sort(longestFirst);
    for (final i in rest) {
      if (chosen.length >= VoiceMatch.maxTurns) break;
      chosen.add(i);
    }
    return chosen;
  }
}
