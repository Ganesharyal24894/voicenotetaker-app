/// When a recording's audio may be removed automatically, keeping its
/// transcript.
///
/// PURE: no clock, no I/O. `services/audio_retention_service.dart` gathers the
/// facts about each file and asks; every rule is a unit test.
library;

/// Where a recording's transcription stands, as far as retention cares.
enum RetentionTranscript {
  /// No saved transcript.
  none,

  /// A transcription was tried and its failure saved - whether or not a
  /// transcript file also exists.
  failed,

  /// A saved transcript in which nothing was recognised.
  empty,

  /// A saved transcript with words in it.
  done,
}

/// Everything [AudioRetention.decide] needs to know about one recording.
class RetentionFacts {
  const RetentionFacts({
    required this.hasAudio,
    required this.keep,
    required this.transcript,
    this.startedAt,
    this.modifiedAt,
    this.inUse = false,
  });

  /// Whether the WAV is still on disk.
  final bool hasAudio;

  /// The user asked for this recording's audio to be kept.
  final bool keep;

  final RetentionTranscript transcript;

  /// When the recording started, from its file name. The name is written in
  /// the phone's LOCAL wall-clock time, so this is a local [DateTime]; the
  /// policy converts it to UTC with the time-zone rules for that date.
  final DateTime? startedAt;

  /// The WAV's modification time.
  final DateTime? modifiedAt;

  /// Being written, played or transcribed right now.
  final bool inUse;
}

/// What happens to one recording's audio, and why.
enum RetentionVerdict {
  /// Old enough, transcribed, not kept, not in use: remove the WAV.
  delete,

  /// Already gone.
  noAudio,

  /// Being written, played or transcribed.
  inUse,

  /// The user asked to keep it.
  kept,

  /// Never transcribed yet - the audio is all there is.
  noTranscript,

  /// Transcription failed - the audio is all there is.
  transcriptFailed,

  /// Nothing was recognised - the transcript is no substitute for the audio.
  transcriptEmpty,

  /// Younger than [AudioRetention.maxAge].
  tooRecent,

  /// Its time is ahead of the phone's clock - the clock was moved back since.
  /// Kept until real time catches up.
  timeInFuture,

  /// Neither a name time nor a modification time. Kept.
  unknownAge,
}

/// The retention rules.
///
///   1. Only the WAV is ever removed; the transcript, and the recording's
///      entry in the library, stay.
///   2. Never while the file is being written, played or transcribed.
///   3. Never when the user marked it kept.
///   4. Never without a finished transcript with words in it: no transcript,
///      a saved failure, or an empty transcript all keep the audio.
///   5. Only [maxAge] after the recording STARTED. The age is measured from
///      the LATER of the file-name time and the file's modification time, both
///      in UTC. The name time is the start; the modification time can only
///      postpone deletion - it guards against a name time that reads too old
///      because the phone changed time zone since, or an hour lost to DST.
///   6. A time more than [clockTolerance] in the future means the clock was
///      moved back: the audio is kept until real time passes it.
abstract final class AudioRetention {
  static const Duration maxAge = Duration(hours: 24);

  /// Ordinary clock correction (NTP, a few seconds; a manual nudge) is not a
  /// clock change.
  static const Duration clockTolerance = Duration(minutes: 5);

  static RetentionVerdict decide(RetentionFacts facts, {required DateTime now}) {
    if (!facts.hasAudio) return RetentionVerdict.noAudio;
    if (facts.inUse) return RetentionVerdict.inUse;
    if (facts.keep) return RetentionVerdict.kept;
    switch (facts.transcript) {
      case RetentionTranscript.none:
        return RetentionVerdict.noTranscript;
      case RetentionTranscript.failed:
        return RetentionVerdict.transcriptFailed;
      case RetentionTranscript.empty:
        return RetentionVerdict.transcriptEmpty;
      case RetentionTranscript.done:
        break;
    }
    return ageVerdict(
      startedAt: facts.startedAt,
      modifiedAt: facts.modifiedAt,
      now: now,
    );
  }

  /// Rules 5 and 6 alone: [RetentionVerdict.delete] when old enough.
  static RetentionVerdict ageVerdict({
    required DateTime? startedAt,
    required DateTime? modifiedAt,
    required DateTime now,
  }) {
    final reference = referenceTime(startedAt: startedAt, modifiedAt: modifiedAt);
    if (reference == null) return RetentionVerdict.unknownAge;
    final nowUtc = now.toUtc();
    if (reference.isAfter(nowUtc.add(clockTolerance))) {
      return RetentionVerdict.timeInFuture;
    }
    if (nowUtc.difference(reference) < maxAge) return RetentionVerdict.tooRecent;
    return RetentionVerdict.delete;
  }

  /// The later of the two times, in UTC; null when neither is known.
  static DateTime? referenceTime({DateTime? startedAt, DateTime? modifiedAt}) {
    final a = startedAt?.toUtc();
    final b = modifiedAt?.toUtc();
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }
}
