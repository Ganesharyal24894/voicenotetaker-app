import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/recording_info.dart';
import 'package:voicenotetaker_app/model/summary/note_time.dart';
import 'package:voicenotetaker_app/model/summary/note_time_matcher.dart';
import 'package:voicenotetaker_app/model/summary/summary_range.dart';

RecordingInfo _rec(DateTime at, {int minutes = 10}) => RecordingInfo(
      path: '/r/${at.toIso8601String()}.wav',
      name: 'n',
      recordedAt: at,
      sizeBytes: 1,
      duration: Duration(minutes: minutes),
    );

void main() {
  final now = DateTime(2026, 9, 15, 18);
  final today = SummaryRange.today.windowAt(now);
  final week = SummaryRange.last7Days.windowAt(now);

  RecordingInfo? match(NoteTime time, DayWindow window, List<RecordingInfo> recordings) =>
      NoteTimeMatcher.match(time: time, window: window, recordings: recordings);

  test('the note that starts at the time', () {
    final a = _rec(DateTime(2026, 9, 15, 9, 14));
    final b = _rec(DateTime(2026, 9, 15, 10, 21));
    expect(match(const NoteTime(hour: 10, minute: 21), today, <RecordingInfo>[a, b]), b);
  });

  test('a time inside a note opens that note', () {
    final a = _rec(DateTime(2026, 9, 15, 9, 14), minutes: 12);
    final b = _rec(DateTime(2026, 9, 15, 9, 30));
    expect(match(const NoteTime(hour: 9, minute: 20), today, <RecordingInfo>[a, b]), a);
  });

  test('a start a few seconds after the quoted minute still counts as inside', () {
    final a = _rec(DateTime(2026, 9, 15, 9, 14, 40));
    expect(match(const NoteTime(hour: 9, minute: 14), today, <RecordingInfo>[a]), a);
  });

  test('otherwise the nearest note, before or after', () {
    final a = _rec(DateTime(2026, 9, 15, 9, 0), minutes: 5); // ends 9:05(+1)
    final b = _rec(DateTime(2026, 9, 15, 9, 40));
    expect(match(const NoteTime(hour: 9, minute: 15), today, <RecordingInfo>[a, b]), a);
    expect(match(const NoteTime(hour: 9, minute: 35), today, <RecordingInfo>[a, b]), b);
  });

  test('a tie goes to the more recent note', () {
    final a = _rec(DateTime(2026, 9, 15, 9, 0), minutes: 0); // ends 9:01
    final b = _rec(DateTime(2026, 9, 15, 9, 11));
    expect(match(const NoteTime(hour: 9, minute: 6), today, <RecordingInfo>[a, b]), b);
  });

  test('notes outside the summary window are never opened', () {
    final yesterday = _rec(DateTime(2026, 9, 14, 9, 14));
    expect(match(const NoteTime(hour: 9, minute: 14), today, <RecordingInfo>[yesterday]), isNull);
  });

  test('too far from any note is no match', () {
    final a = _rec(DateTime(2026, 9, 15, 8, 0));
    expect(match(const NoteTime(hour: 17, minute: 0), today, <RecordingInfo>[a]), isNull);
    expect(match(const NoteTime(hour: 9, minute: 0), today, const <RecordingInfo>[]), isNull);
  });

  test('a weekday picks that day inside a week', () {
    final mon = _rec(DateTime(2026, 9, 14, 9, 14));
    final tue = _rec(DateTime(2026, 9, 15, 9, 14));
    expect(match(const NoteTime(hour: 9, minute: 14, weekday: 1), week, <RecordingInfo>[mon, tue]), mon);
    expect(match(const NoteTime(hour: 9, minute: 14, weekday: 2), week, <RecordingInfo>[mon, tue]), tue);
  });

  test('a date picks that date', () {
    final a = _rec(DateTime(2026, 9, 10, 9, 14));
    final b = _rec(DateTime(2026, 9, 12, 9, 14));
    expect(match(const NoteTime(hour: 9, minute: 14, day: 10, month: 9), week, <RecordingInfo>[a, b]), a);
  });

  test('no day in a week: the closest time of day on any day, most recent on a tie', () {
    final a = _rec(DateTime(2026, 9, 10, 9, 14));
    final b = _rec(DateTime(2026, 9, 12, 9, 14));
    final c = _rec(DateTime(2026, 9, 13, 15, 0));
    expect(match(const NoteTime(hour: 9, minute: 14), week, <RecordingInfo>[a, b, c]), b);
    expect(match(const NoteTime(hour: 15, minute: 2), week, <RecordingInfo>[a, b, c]), c);
  });
}
