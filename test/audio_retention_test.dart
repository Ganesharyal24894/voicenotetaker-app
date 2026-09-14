import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/audio_retention.dart';

/// When a recording's audio may be removed, keeping its transcript.
void main() {
  final now = DateTime.utc(2026, 9, 15, 12);

  RetentionFacts facts({
    bool hasAudio = true,
    bool keep = false,
    RetentionTranscript transcript = RetentionTranscript.done,
    DateTime? startedAt,
    DateTime? modifiedAt,
    bool inUse = false,
  }) =>
      RetentionFacts(
        hasAudio: hasAudio,
        keep: keep,
        transcript: transcript,
        startedAt: startedAt,
        modifiedAt: modifiedAt,
        inUse: inUse,
      );

  RetentionVerdict decide(RetentionFacts f, {DateTime? at}) =>
      AudioRetention.decide(f, now: at ?? now);

  final oldUtc = now.subtract(const Duration(hours: 30));

  test('old, transcribed, not kept, not in use: delete', () {
    expect(decide(facts(startedAt: oldUtc)), RetentionVerdict.delete);
  });

  test('every blocker keeps the audio', () {
    expect(decide(facts(startedAt: oldUtc, keep: true)), RetentionVerdict.kept);
    expect(decide(facts(startedAt: oldUtc, inUse: true)), RetentionVerdict.inUse);
    expect(decide(facts(startedAt: oldUtc, hasAudio: false)),
        RetentionVerdict.noAudio);
    expect(
        decide(facts(startedAt: oldUtc, transcript: RetentionTranscript.none)),
        RetentionVerdict.noTranscript);
    expect(
        decide(
            facts(startedAt: oldUtc, transcript: RetentionTranscript.failed)),
        RetentionVerdict.transcriptFailed);
    expect(
        decide(facts(startedAt: oldUtc, transcript: RetentionTranscript.empty)),
        RetentionVerdict.transcriptEmpty);
  });

  test('exactly 24 h is old enough; a second less is not', () {
    final day = now.subtract(AudioRetention.maxAge);
    expect(decide(facts(startedAt: day)), RetentionVerdict.delete);
    expect(decide(facts(startedAt: day.add(const Duration(seconds: 1)))),
        RetentionVerdict.tooRecent);
  });

  test('the file name time is local wall-clock time, compared in UTC', () {
    // A local DateTime 25 h before `now` in whatever zone the test runs in.
    final local = now.subtract(const Duration(hours: 25)).toLocal();
    final wallClock = DateTime(local.year, local.month, local.day, local.hour,
        local.minute, local.second);
    expect(wallClock.isUtc, isFalse);
    expect(decide(facts(startedAt: wallClock)), RetentionVerdict.delete);
  });

  test('a later modification time postpones, never hastens', () {
    // Name says 30 h ago, but the file was still written 2 h ago - a time
    // zone change since, or a long note: keep for now.
    expect(
      decide(facts(
          startedAt: oldUtc,
          modifiedAt: now.subtract(const Duration(hours: 2)))),
      RetentionVerdict.tooRecent,
    );
    // An OLDER modification time does not make a young name old.
    expect(
      decide(facts(
          startedAt: now.subtract(const Duration(hours: 2)),
          modifiedAt: oldUtc)),
      RetentionVerdict.tooRecent,
    );
  });

  test('no name time: the modification time decides', () {
    expect(decide(facts(modifiedAt: oldUtc)), RetentionVerdict.delete);
    expect(decide(facts(modifiedAt: now)), RetentionVerdict.tooRecent);
  });

  test('no time at all: kept', () {
    expect(decide(facts()), RetentionVerdict.unknownAge);
  });

  test('a time in the future means the clock went back: kept until real '
      'time passes it', () {
    final ahead = now.add(const Duration(days: 3));
    expect(decide(facts(startedAt: ahead)), RetentionVerdict.timeInFuture);
    expect(decide(facts(startedAt: oldUtc, modifiedAt: ahead)),
        RetentionVerdict.timeInFuture);
    // A few minutes ahead is clock jitter, and simply young.
    expect(decide(facts(startedAt: now.add(const Duration(minutes: 2)))),
        RetentionVerdict.tooRecent);
    // ...and once the clock is past it by a day, it goes.
    expect(decide(facts(startedAt: ahead), at: ahead.add(const Duration(days: 1))),
        RetentionVerdict.delete);
  });

  test('the same instant written in different zones gives the same answer',
      () {
    final instant = DateTime.utc(2026, 3, 29, 1, 30); // EU DST switch night
    final later = instant.add(const Duration(hours: 24));
    expect(
      AudioRetention.decide(facts(startedAt: instant), now: later),
      AudioRetention.decide(facts(startedAt: instant.toLocal()), now: later.toLocal()),
    );
  });

  test('referenceTime is the later of the two, in UTC', () {
    final a = DateTime.utc(2026, 1, 1);
    final b = DateTime.utc(2026, 1, 2);
    expect(AudioRetention.referenceTime(startedAt: a, modifiedAt: b), b);
    expect(AudioRetention.referenceTime(startedAt: b, modifiedAt: a), b);
    expect(AudioRetention.referenceTime(startedAt: a), a);
    expect(AudioRetention.referenceTime(), isNull);
    expect(AudioRetention.referenceTime(startedAt: a.toLocal())!.isUtc, isTrue);
  });
}
