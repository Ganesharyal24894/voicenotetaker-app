/// Turning what a diarizer heard into turns worth transcribing, and into the
/// windows the speech model decodes.
///
/// PURE: sample arithmetic in, sample arithmetic out. No I/O, no clock, no
/// package types - every rule below is a unit test in
/// `test/speaker_turns_test.dart`.
library;

import 'decode_window.dart';
import 'diarization.dart';
import 'transcription.dart';

abstract final class SpeakerTurns {
  /// Same speaker either side of a pause shorter than this: one turn.
  ///
  /// A person breathing, or looking for a word, has not stopped talking.
  static const Duration mergeGap = Duration(seconds: 1);

  /// A turn shorter than this is folded into a neighbour.
  ///
  /// Under a second is one word, and one word is not enough voice for the
  /// clustering to have been sure about. Labelling it separately is how a
  /// transcript ends up stuttering between two names mid-sentence.
  static const Duration minTurn = Duration(seconds: 1);

  /// A speaker heard for less than this in the whole note is not a speaker.
  static const Duration minSpeakerTotal = Duration(seconds: 2);

  /// A turn longer than a decode window is split no earlier than this.
  ///
  /// The split is hunted between here and the window's end, so every piece is
  /// at least this long and none is over the window.
  ///
  /// NOT DERIVED FROM THE WINDOW, ON PURPOSE. It was 6 s of an 8 s window and
  /// it is 6 s of [DecodeWindow.standard]'s 16 s, so the hunt now ranges over
  /// 10 s rather than 2 s. Two reasons. It is the shortest piece worth
  /// decoding on its own, which does not change when the window grows. And a
  /// wide hunt is what makes a long turn split WELL: a 24 s turn can be cut
  /// near its middle, in a real pause, instead of at 16 s leaving an 8 s tail.
  /// This is also exactly the range the 16 s figures were measured with
  /// (`diar16` in `notetaker-data/accuracy-20260918-205506/RESULTS.md`: 116
  /// decodes against 189 at 8 s, so the wider hunt is not producing
  /// needlessly short windows).
  static const Duration splitFrom = Duration(seconds: 6);

  /// How much audio the split point is chosen by: the quietest stretch this
  /// long in the search range is where the cut goes.
  static const Duration splitProbe = Duration(milliseconds: 200);

  static int _samples(Duration of, int sampleRateHz) =>
      of.inMicroseconds * sampleRateHz ~/ 1000000;

  /// The turns worth labelling, from what the diarizer said.
  ///
  /// THE RULES, in this order - each is a test:
  ///
  ///   1. clamp to `[0, totalSamples)`, drop the empty, sort by start;
  ///   2. where two turns OVERLAP, cut at the midpoint of the overlap (the
  ///      same speaker twice is simply merged) - the engine reports
  ///      overlapping speech as two turns, and a window can only be decoded
  ///      once;
  ///   3. the same speaker either side of a gap under [mergeGap] is one turn;
  ///   4. a turn under [minTurn] is folded into a neighbour - the closer one,
  ///      and on a tie the longer one - and is then merged into it;
  ///   5. a speaker with under [minSpeakerTotal] in the whole note is folded
  ///      away the same way, turn by turn;
  ///   6. boundaries are STRETCHED so no audio is dropped: the first turn
  ///      starts at 0, the last ends at [totalSamples], and every gap between
  ///      two turns is split at its midpoint. Silence transcribes to nothing,
  ///      but a quiet word that the segmentation missed is worth keeping, and
  ///      the timeline then has no holes for the note screen to explain;
  ///   7. anything that became the same speaker back to back is merged.
  ///
  /// Empty in, empty out - and empty out means "no speakers here": the caller
  /// transcribes the recording the way it always did.
  static List<SpeakerTurn> clean({
    required List<SpeakerTurn> turns,
    required int totalSamples,
    required int sampleRateHz,
  }) {
    if (totalSamples < 0) {
      throw ArgumentError.value(totalSamples, 'totalSamples', 'must be >= 0');
    }
    if (sampleRateHz <= 0) {
      throw ArgumentError.value(sampleRateHz, 'sampleRateHz', 'must be > 0');
    }
    final gap = _samples(mergeGap, sampleRateHz);
    final shortest = _samples(minTurn, sampleRateHz);
    final quietest = _samples(minSpeakerTotal, sampleRateHz);

    // 1. Clamp, drop the empty, sort.
    var result = <SpeakerTurn>[
      for (final turn in turns)
        if (turn.start < totalSamples && turn.end > turn.start)
          turn.copyWith(
            end: turn.end > totalSamples ? totalSamples : turn.end,
          ),
    ]..sort((a, b) {
        final byStart = a.start.compareTo(b.start);
        return byStart != 0 ? byStart : a.end.compareTo(b.end);
      });
    if (result.isEmpty) return const <SpeakerTurn>[];

    // 2. Cut overlaps at their midpoint.
    result = _splitOverlaps(result);

    // 3. Same speaker across a short pause.
    result = _mergeSameSpeaker(result, gap);

    // 4. Turns too short to be anyone's.
    result = _foldShortTurns(result, shortest, gap);

    // 5. Speakers heard for too little of the note.
    result = _foldQuietSpeakers(result, quietest, gap);

    // 6. Stretch over the gaps, and over the ends.
    result = _stretch(result, totalSamples);

    // 7. And merge whatever that made adjacent.
    return List<SpeakerTurn>.unmodifiable(_mergeSameSpeaker(result, gap));
  }

  /// Where two speakers overlap, the first half of the overlap goes to
  /// whoever was already talking and the second half to whoever joined. A
  /// turn sitting wholly inside another leaves the rest of that other turn
  /// behind it, so nobody loses the part of their turn they had to
  /// themselves.
  static List<SpeakerTurn> _splitOverlaps(List<SpeakerTurn> turns) {
    final out = <SpeakerTurn>[];
    final queue = <SpeakerTurn>[...turns];
    while (queue.isNotEmpty) {
      final next = queue.removeAt(0);
      if (out.isEmpty || out.last.end <= next.start) {
        out.add(next);
        continue;
      }
      final previous = out.removeLast();
      if (previous.speaker == next.speaker) {
        // One voice, twice over: one turn, checked again against what is now
        // last - it may reach back over that too.
        queue.insert(
          0,
          previous.copyWith(
            end: next.end > previous.end ? next.end : previous.end,
          ),
        );
        continue;
      }
      final overlapEnd =
          previous.end < next.end ? previous.end : next.end;
      final middle = (next.start + overlapEnd) ~/ 2;
      if (previous.start < middle) out.add(previous.copyWith(end: middle));
      final start = middle > next.start ? middle : next.start;
      final kept = next.end > start;
      if (kept) queue.insert(0, next.copyWith(start: start));
      if (previous.end > next.end) {
        queue.insert(
          kept ? 1 : 0,
          previous.copyWith(start: next.end),
        );
      }
    }
    return out;
  }

  static List<SpeakerTurn> _mergeSameSpeaker(List<SpeakerTurn> turns, int gap) {
    final out = <SpeakerTurn>[];
    for (final turn in turns) {
      if (out.isNotEmpty &&
          out.last.speaker == turn.speaker &&
          turn.start - out.last.end < gap) {
        final previous = out.removeLast();
        out.add(
          previous.copyWith(
            end: turn.end > previous.end ? turn.end : previous.end,
          ),
        );
      } else {
        out.add(turn);
      }
    }
    return out;
  }

  /// The neighbour a turn at [index] belongs to: the closer of the two, and
  /// on a tie the longer one. Null when it has none.
  static int? _neighbourOf(List<SpeakerTurn> turns, int index) {
    final before = index > 0 ? index - 1 : null;
    final after = index + 1 < turns.length ? index + 1 : null;
    if (before == null) return after;
    if (after == null) return before;
    final gapBefore = turns[index].start - turns[before].end;
    final gapAfter = turns[after].start - turns[index].end;
    if (gapBefore != gapAfter) return gapBefore < gapAfter ? before : after;
    return turns[before].length >= turns[after].length ? before : after;
  }

  static List<SpeakerTurn> _foldShortTurns(
    List<SpeakerTurn> turns,
    int shortest,
    int gap,
  ) {
    var current = turns;
    // One fold can make its neighbour long enough, or make two shorts
    // adjacent, so this runs until nothing changes. Every pass removes at
    // least one turn, so it ends.
    while (current.length > 1) {
      var index = -1;
      for (var i = 0; i < current.length; i++) {
        if (current[i].length >= shortest) continue;
        if (index < 0 || current[i].length < current[index].length) index = i;
      }
      if (index < 0) break;
      final neighbour = _neighbourOf(current, index);
      if (neighbour == null) break;
      final next = <SpeakerTurn>[...current];
      next[index] = next[index].copyWith(speaker: current[neighbour].speaker);
      current = _mergeSameSpeaker(next, gap);
      // The fold left them a pause apart: still one speaker's, still not worth
      // its own label, so they join anyway.
      if (current.length == next.length) current = _joinAt(next, index);
    }
    return current;
  }

  /// Joins the turn at [index] to whichever side now shares its speaker.
  static List<SpeakerTurn> _joinAt(List<SpeakerTurn> turns, int index) {
    final out = <SpeakerTurn>[...turns];
    final turn = out[index];
    if (index > 0 && out[index - 1].speaker == turn.speaker) {
      out[index - 1] = out[index - 1].copyWith(
        end: turn.end > out[index - 1].end ? turn.end : out[index - 1].end,
      );
      out.removeAt(index);
      return out;
    }
    if (index + 1 < out.length && out[index + 1].speaker == turn.speaker) {
      out[index + 1] = out[index + 1].copyWith(start: turn.start);
      out.removeAt(index);
      return out;
    }
    return out;
  }

  static List<SpeakerTurn> _foldQuietSpeakers(
    List<SpeakerTurn> turns,
    int quietest,
    int gap,
  ) {
    var current = turns;
    while (true) {
      final totals = <int, int>{};
      for (final turn in current) {
        totals[turn.speaker] = (totals[turn.speaker] ?? 0) + turn.length;
      }
      if (totals.length <= 1) return current;
      // The quietest first: folding it away may be what makes the next one
      // loud enough to keep.
      int? victim;
      for (final entry in totals.entries) {
        if (entry.value >= quietest) continue;
        if (victim == null || entry.value < totals[victim]!) victim = entry.key;
      }
      if (victim == null) return current;
      final index = current.indexWhere((turn) => turn.speaker == victim);
      final neighbour = _neighbourOf(current, index);
      if (neighbour == null) return current;
      final next = <SpeakerTurn>[...current];
      next[index] = next[index].copyWith(speaker: current[neighbour].speaker);
      final merged = _mergeSameSpeaker(next, gap);
      current = merged.length == next.length ? _joinAt(next, index) : merged;
    }
  }

  static List<SpeakerTurn> _stretch(List<SpeakerTurn> turns, int totalSamples) {
    if (turns.isEmpty) return turns;
    final out = <SpeakerTurn>[...turns];
    out[0] = out[0].copyWith(start: 0);
    for (var i = 0; i + 1 < out.length; i++) {
      if (out[i].end >= out[i + 1].start) continue;
      final middle = (out[i].end + out[i + 1].start) ~/ 2;
      out[i] = out[i].copyWith(end: middle);
      out[i + 1] = out[i + 1].copyWith(start: middle);
    }
    final last = out.length - 1;
    if (out[last].end < totalSamples) {
      out[last] = out[last].copyWith(end: totalSamples);
    }
    return out;
  }

  /// A display label per speaker, `S1`, `S2`, ... in the order they first
  /// speak.
  ///
  /// STABLE WITHIN A NOTE: the order comes from the turns, not from the
  /// clustering's own numbering, so the person who speaks first is always S1.
  static Map<int, String> labels(List<SpeakerTurn> turns) {
    final out = <int, String>{};
    for (final turn in turns) {
      out[turn.speaker] ??= 'S${out.length + 1}';
    }
    return Map<int, String>.unmodifiable(out);
  }

  /// The windows to decode, in order: one per turn, and a long turn cut up.
  ///
  /// A turn longer than [maxWindowSamples] is cut at the quietest moment
  /// between [splitFromSamples] and [maxWindowSamples] from its start -
  /// [quietestSplit] is asked where that is, and gets the search range in
  /// sample indices - so the cut falls in a pause rather than through a word.
  /// Without [quietestSplit], or when it answers outside the range, the cut is
  /// at [maxWindowSamples], which is the fixed grid's behaviour.
  ///
  /// Windows never overlap, never span two speakers, and together cover every
  /// sample of every turn.
  static List<SpeakerWindow> plan({
    required List<SpeakerTurn> turns,
    required int maxWindowSamples,
    required int splitFromSamples,
    int? Function(int start, int end)? quietestSplit,
  }) {
    if (maxWindowSamples <= 0) {
      throw ArgumentError.value(
        maxWindowSamples,
        'maxWindowSamples',
        'must be > 0',
      );
    }
    final from = splitFromSamples <= 0 || splitFromSamples > maxWindowSamples
        ? maxWindowSamples
        : splitFromSamples;
    final out = <SpeakerWindow>[];
    for (final turn in turns) {
      var start = turn.start;
      while (turn.end - start > maxWindowSamples) {
        final searchStart = start + from;
        final searchEnd = start + maxWindowSamples;
        var cut = quietestSplit?.call(searchStart, searchEnd) ?? searchEnd;
        if (cut <= searchStart || cut > searchEnd) cut = searchEnd;
        out.add(
          SpeakerWindow(
            range: SampleRange(start, cut),
            speaker: turn.speaker,
          ),
        );
        start = cut;
      }
      if (turn.end > start) {
        out.add(
          SpeakerWindow(
            range: SampleRange(start, turn.end),
            speaker: turn.speaker,
          ),
        );
      }
    }
    return List<SpeakerWindow>.unmodifiable(out);
  }

  /// [plan], sized from the speech model's window and the diarizer's rules.
  ///
  /// [window] overrides [SpeechModel.maxWindow] for one job: how the
  /// low-memory fallback of [DecodeWindow] reaches the splitter.
  static List<SpeakerWindow> planForModel({
    required List<SpeakerTurn> turns,
    required SpeechModel model,
    Duration? window,
    int? Function(int start, int end)? quietestSplit,
  }) =>
      plan(
        turns: turns,
        maxWindowSamples:
            _samples(window ?? model.maxWindow, model.sampleRateHz),
        splitFromSamples: _samples(splitFrom, model.sampleRateHz),
        quietestSplit: quietestSplit,
      );
}
