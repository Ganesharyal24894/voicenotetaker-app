/// Whether the owner's guided recording is good enough to be their voice.
///
/// PURE: the diarizer's turns and the embeddings of the recording in, a
/// verdict out. Every rule is a test in `test/model/enrolment_check_test.dart`.
///
/// WHY IT IS STRICT. Everything the voice filter hides, it hides by comparing
/// with this one recording. A minute of the owner alone is what the
/// measurement found steady (60 s of speech gives 0.95 to the full centroid,
/// 30 s only 0.90); a second voice in it would teach the filter that voice
/// is the owner's.
library;

import 'dart:typed_data';

import 'diarization.dart';
import 'transcription.dart';
import 'voice_match.dart';
import 'voice_vector.dart';

/// Why a recording was not taken.
enum EnrolmentProblem {
  /// Less than [EnrolmentCheck.minSpeech] of talking.
  tooShort,

  /// More than one voice: another speaker, or chunks that disagree.
  notAlone,

  /// The recorder dropped the link part way.
  linkLost,

  /// The recording could not be checked at all - unreadable, or an engine
  /// failed. Never a verdict of [EnrolmentCheck]; the service that runs the
  /// engines says it.
  couldNotCheck,
}

/// The answer about one recording.
class EnrolmentVerdict {
  const EnrolmentVerdict.retry(this.problem, {this.speech = Duration.zero})
    : embedding = null;

  EnrolmentVerdict.ok({required List<double> embedding, required this.speech})
    : problem = null,
      embedding = VoiceVector.normalise(embedding);

  /// Null when the recording is good.
  final EnrolmentProblem? problem;

  /// The owner's voice: the chunks' seconds-weighted mean. Null unless ok.
  final Float32List? embedding;

  /// Speech heard in the recording - for "we heard 20 seconds of talking",
  /// and, when ok, the enrolment sample's weight.
  final Duration speech;

  bool get ok => problem == null;

  @override
  String toString() => 'EnrolmentVerdict(${problem?.name ?? 'ok'}, $speech)';
}

abstract final class EnrolmentCheck {
  /// What the screen asks for: about a minute.
  static const Duration target = Duration(seconds: 60);

  /// Less talking than this is [EnrolmentProblem.tooShort]; Done is offered
  /// from here.
  static const Duration minSpeech = Duration(seconds: 45);

  /// The main voice must be at least this share of the speech.
  static const double minShare = 0.9;

  /// The main voice is embedded this much at a time...
  static const Duration chunk = Duration(seconds: 6);

  /// ...a last piece shorter than this is left out...
  static const Duration minChunk = Duration(seconds: 3);

  /// ...and every chunk must be at least this close to the chunks' mean: a
  /// second person the diarizer folded into the first shows up here.
  static const double minChunkSimilarity = 0.5;

  static int _samples(Duration of, int rate) =>
      of.inMicroseconds * rate ~/ 1000000;

  /// Samples of speech per diarizer speaker, overlaps counted once.
  static Map<int, int> speechOf(List<SpeakerTurn> raw) => <int, int>{
    for (final entry in _bySpeaker(raw).entries)
      entry.key: entry.value.fold<int>(0, (sum, r) => sum + r.length),
  };

  /// What can be said before anything is embedded, in the order the user
  /// should hear it: the link, then too little, then someone else talking.
  static EnrolmentProblem? screen({
    required List<SpeakerTurn> raw,
    required int sampleRateHz,
    bool linkLost = false,
  }) {
    if (linkLost) return EnrolmentProblem.linkLost;
    final speech = speechOf(raw);
    final total = speech.values.fold<int>(0, (sum, s) => sum + s);
    if (total < _samples(minSpeech, sampleRateHz)) {
      return EnrolmentProblem.tooShort;
    }
    final main = speech.values.reduce((a, b) => a > b ? a : b);
    if (main < total * minShare) return EnrolmentProblem.notAlone;
    return null;
  }

  /// The main voice's speech, [chunk] at a time, counted in speech time so
  /// the pauses do not count; a piece under [VoiceMatch.minPiece] is noise.
  static List<List<SampleRange>> chunks({
    required List<SpeakerTurn> raw,
    required int sampleRateHz,
  }) {
    final bySpeaker = _bySpeaker(raw);
    if (bySpeaker.isEmpty) return const <List<SampleRange>>[];
    final speech = speechOf(raw);
    final main = speech.keys.reduce((a, b) => speech[a]! >= speech[b]! ? a : b);
    final shortest = _samples(VoiceMatch.minPiece, sampleRateHz);
    final size = _samples(chunk, sampleRateHz);
    final out = <List<SampleRange>>[];
    var current = <SampleRange>[];
    var filled = 0;
    for (final piece in bySpeaker[main]!) {
      if (piece.length < shortest) continue;
      var at = piece.start;
      while (at < piece.end) {
        final take = piece.end - at < size - filled
            ? piece.end - at
            : size - filled;
        current.add(SampleRange(at, at + take));
        at += take;
        filled += take;
        if (filled == size) {
          out.add(current);
          current = <SampleRange>[];
          filled = 0;
        }
      }
    }
    if (filled >= _samples(minChunk, sampleRateHz)) out.add(current);
    return out;
  }

  /// The verdict, once the [embedded] chunks - embedding and seconds each -
  /// are back.
  static EnrolmentVerdict verdict({
    required List<SpeakerTurn> raw,
    required int sampleRateHz,
    required List<(List<double>, double)> embedded,
    bool linkLost = false,
  }) {
    final total = speechOf(raw).values.fold<int>(0, (sum, s) => sum + s);
    final speech = Duration(microseconds: total * 1000000 ~/ sampleRateHz);
    final early = screen(
      raw: raw,
      sampleRateHz: sampleRateHz,
      linkLost: linkLost,
    );
    if (early != null) return EnrolmentVerdict.retry(early, speech: speech);
    if (embedded.isEmpty) {
      return EnrolmentVerdict.retry(EnrolmentProblem.tooShort, speech: speech);
    }
    final dim = embedded.first.$1.length;
    final mean = VoiceVector.weightedMean(embedded, dim);
    for (final (vector, _) in embedded) {
      if (VoiceVector.cosine(vector, mean) < minChunkSimilarity) {
        return EnrolmentVerdict.retry(
          EnrolmentProblem.notAlone,
          speech: speech,
        );
      }
    }
    return EnrolmentVerdict.ok(embedding: mean, speech: speech);
  }

  /// Each speaker's segments in time order, overlaps joined.
  static Map<int, List<SampleRange>> _bySpeaker(List<SpeakerTurn> raw) {
    final sorted = <SpeakerTurn>[...raw]
      ..sort((a, b) => a.start.compareTo(b.start));
    final out = <int, List<SampleRange>>{};
    for (final turn in sorted) {
      if (turn.end <= turn.start) continue;
      final ranges = out[turn.speaker] ??= <SampleRange>[];
      if (ranges.isNotEmpty && turn.start <= ranges.last.end) {
        final last = ranges.removeLast();
        ranges.add(
          SampleRange(last.start, turn.end > last.end ? turn.end : last.end),
        );
      } else {
        ranges.add(SampleRange(turn.start, turn.end));
      }
    }
    return out;
  }
}
