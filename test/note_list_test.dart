import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/note_search.dart';
import 'package:voicenotetaker_app/model/recording_info.dart';
import 'package:voicenotetaker_app/model/transcript.dart';
import 'package:voicenotetaker_app/model/transcription.dart';
import 'package:voicenotetaker_app/view/note_list.dart';

final DateTime _now = DateTime(2026, 9, 15, 18); // a Tuesday

RecordingInfo _info(
  DateTime at, {
  Duration length = const Duration(minutes: 12),
  bool hasAudio = true,
  bool keepAudio = false,
}) =>
    RecordingInfo(
      path: '/rec/${at.toIso8601String()}.wav',
      name: 'n',
      recordedAt: at,
      sizeBytes: 1,
      duration: length,
      hasAudio: hasAudio,
      keepAudio: keepAudio,
    );

Transcript _said(List<(String, String?)> lines) => Transcript(
      languageCode: 'hi',
      modelId: 'm',
      createdAt: DateTime.utc(2026, 9, 15),
      audioDuration: Duration(seconds: 8 * lines.length),
      segments: <TranscriptSegment>[
        for (var i = 0; i < lines.length; i++)
          TranscriptSegment(
            start: Duration(seconds: 8 * i),
            end: Duration(seconds: 8 * i + 1),
            text: lines[i].$1,
            speaker: lines[i].$2,
          ),
      ],
    );

void main() {
  group('labels', () {
    test('title is time and whole minutes, never 0 min', () {
      expect(NoteLabels.title(_info(DateTime(2026, 9, 15, 9, 14))),
          '09:14 · 12 min');
      expect(NoteLabels.minutes(const Duration(seconds: 10)), '1 min');
      expect(NoteLabels.minutes(const Duration(seconds: 150)), '3 min');
    });

    test('note meta leaves out what is not known', () {
      expect(
        NoteLabels.noteMeta(
          recordedAt: DateTime(2026, 9, 15, 9),
          now: _now,
          speakerCount: 2,
          words: 1450,
        ),
        'Today · 2 speakers · 1,450 words',
      );
      expect(
        NoteLabels.noteMeta(
          recordedAt: DateTime(2026, 9, 14, 9),
          now: _now,
          speakerCount: 1,
        ),
        'Yesterday',
      );
      expect(
        NoteLabels.noteMeta(recordedAt: _now, now: _now, words: 1),
        'Today · 1 word',
      );
    });

    test('audio deletes, counted from the start of the note', () {
      final at = DateTime(2026, 9, 15, 0);
      String left(DateTime now) =>
          NoteLabels.audioDeletes(recordedAt: at, now: now);
      expect(left(DateTime(2026, 9, 15, 6)), 'Audio deletes in 18 h');
      expect(left(DateTime(2026, 9, 15, 23, 20)), 'Audio deletes in 40 min');
      expect(left(DateTime(2026, 9, 16, 1)), 'Audio deletes soon');
    });

    test('counts group their thousands', () {
      expect(NoteLabels.count(7), '7');
      expect(NoteLabels.count(1450), '1,450');
      expect(NoteLabels.count(1234567), '1,234,567');
    });
  });

  group('grouping', () {
    test('Today, Yesterday, a weekday within the week, then a date', () {
      expect(NoteLabels.group(DateTime(2026, 9, 15, 1), now: _now), 'Today');
      expect(NoteLabels.group(DateTime(2026, 9, 14, 23), now: _now),
          'Yesterday');
      expect(NoteLabels.group(DateTime(2026, 9, 12), now: _now), 'Saturday');
      expect(NoteLabels.group(DateTime(2026, 9, 1), now: _now), '1 Sep');
      expect(NoteLabels.group(DateTime(2025, 12, 30), now: _now),
          '30 Dec 2025');
    });

    test('rows keep their order under consecutive headings', () {
      final items = <NoteListItem>[
        for (final at in <DateTime>[
          DateTime(2026, 9, 15, 11),
          DateTime(2026, 9, 15, 9),
          DateTime(2026, 9, 14, 18),
          DateTime(2026, 9, 10, 8),
        ])
          NoteListItem.from(_info(at), status: TranscriptStatus.none),
      ];

      final groups = NoteList.group(items, now: _now);

      expect(groups.map((g) => g.label),
          <String>['Today', 'Yesterday', 'Thursday']);
      expect(groups.map((g) => g.items.length), <int>[2, 1, 1]);
    });
  });

  group('search', () {
    test('case-insensitive for Latin script', () {
      expect(NoteSearch.matches('HR', <String>['salary baat with hr']), isTrue);
    });

    test('Devanagari matches as typed, without being mangled', () {
      const said = 'कल की मीटिंग में क्लाइंट ने डेडलाइन बढ़ा दी';
      expect(NoteSearch.matches('क्लाइंट', <String>[said]), isTrue);
      expect(NoteSearch.matches('मीटिंग  में', <String>[said]), isTrue);
      expect(NoteSearch.matches('क्लाइंटो', <String>[said]), isFalse);
    });

    test('a nukta letter typed as one code point matches two, and back', () {
      const composed = 'ज़रूर'; // ज़रूर, one code point
      const decomposed = 'ज़रूर'; // ज + ़ + रूर
      expect(NoteSearch.matches(composed, <String>['हाँ $decomposed']), isTrue);
      expect(NoteSearch.matches(decomposed, <String>[composed]), isTrue);
    });

    test('filters by transcript and by time, newest first; blank is all', () {
      final morning = NoteListItem.from(
        _info(DateTime(2026, 9, 15, 9, 14)),
        status: TranscriptStatus.done,
        transcript: _said(<(String, String?)>[('प्रिया, फाइलें भेजना', null)]),
      );
      final evening = NoteListItem.from(
        _info(DateTime(2026, 9, 15, 18, 5)),
        status: TranscriptStatus.done,
        transcript: _said(<(String, String?)>[('HR से बात', null)]),
      );
      final all = <NoteListItem>[morning, evening];

      expect(NoteList.filter(all, ''), <NoteListItem>[evening, morning]);
      expect(NoteList.filter(all, 'प्रिया'), <NoteListItem>[morning]);
      expect(NoteList.filter(all, 'hr'), <NoteListItem>[evening]);
      expect(NoteList.filter(all, '18:05'), <NoteListItem>[evening]);
      expect(NoteList.filter(all, 'nothing like it'), isEmpty);
    });
  });

  group('picked days', () {
    NoteListItem said(DateTime at, String text) => NoteListItem.from(
          _info(at),
          status: TranscriptStatus.done,
          transcript: _said(<(String, String?)>[(text, null)]),
        );

    final today = said(DateTime(2026, 9, 15, 9, 14), 'HR से बात');
    final todayLater = said(DateTime(2026, 9, 15, 18, 5), 'शाम की मीटिंग');
    final friday = said(DateTime(2026, 9, 11, 10), 'HR ने कहा');
    final saturday = said(DateTime(2026, 9, 12, 10), 'गाड़ी की सर्विस');
    final all = <NoteListItem>[today, todayLater, friday, saturday];

    test('no days picked shows every day', () {
      expect(
        NoteList.filter(all, ''),
        <NoteListItem>[todayLater, today, saturday, friday],
      );
    });

    test('one day, then several, newest first', () {
      expect(
        NoteList.filter(all, '', days: <DateTime>{DateTime(2026, 9, 15)}),
        <NoteListItem>[todayLater, today],
      );
      expect(
        NoteList.filter(
          all,
          '',
          days: <DateTime>{DateTime(2026, 9, 15), DateTime(2026, 9, 11)},
        ),
        <NoteListItem>[todayLater, today, friday],
      );
    });

    test('a picked day with nothing on it shows nothing', () {
      expect(
        NoteList.filter(all, '', days: <DateTime>{DateTime(2026, 9, 14)}),
        isEmpty,
      );
    });

    test('days and search are BOTH applied - search stays inside the days',
        () {
      // "HR" is said on two days; only the picked one comes back.
      expect(
        NoteList.filter(all, 'HR', days: <DateTime>{DateTime(2026, 9, 15)}),
        <NoteListItem>[today],
      );
      expect(
        NoteList.filter(all, 'HR', days: <DateTime>{DateTime(2026, 9, 11)}),
        <NoteListItem>[friday],
      );
      // A search that matches nothing inside the picked days finds nothing,
      // even though it would match elsewhere.
      expect(
        NoteList.filter(
          all,
          'सर्विस',
          days: <DateTime>{DateTime(2026, 9, 15)},
        ),
        isEmpty,
      );
    });

    test('a picked day is the whole day, whatever the time', () {
      expect(
        NoteList.onDays(today, <DateTime>{DateTime(2026, 9, 15)}),
        isTrue,
      );
      expect(
        NoteList.onDays(todayLater, <DateTime>{DateTime(2026, 9, 15)}),
        isTrue,
      );
      expect(NoteList.onDays(today, const <DateTime>{}), isTrue);
    });

    test('a heading says the day and how many rows are under it', () {
      final groups = NoteList.group(
        NoteList.filter(all, '', days: <DateTime>{DateTime(2026, 9, 15)}),
        now: _now,
      );
      expect(groups.single.heading, 'Today · 2 notes');

      final one = NoteList.group(
        NoteList.filter(all, '', days: <DateTime>{DateTime(2026, 9, 11)}),
        now: _now,
      );
      expect(one.single.heading, 'Friday · 1 note');
    });
  });

  group('a row', () {
    final at = DateTime(2026, 9, 15, 9, 14);

    test('quotes the first thing said, with time, length and speakers', () {
      final item = NoteListItem.from(
        _info(at),
        status: TranscriptStatus.done,
        transcript: _said(<(String, String?)>[
          ('कल की मीटिंग', 'S1'),
          ('ठीक है', 'S2'),
        ]),
      );

      expect(item.title, 'कल की मीटिंग');
      expect(item.titleIsState, isFalse);
      expect(item.meta, '09:14 · 12 min · 2 speakers');
      expect(item.badge, isNull);
    });

    test('says where the transcript stands when there are no words', () {
      String title(TranscriptStatus? status) =>
          NoteListItem.from(_info(at), status: status).title;
      expect(title(TranscriptStatus.queued), 'Waiting for transcript');
      expect(title(TranscriptStatus.noSpeech), 'No speech found');
      expect(title(TranscriptStatus.failed), "Couldn't transcribe");
      expect(title(TranscriptStatus.done), 'Loading…');
      expect(title(null), 'No transcript');
    });

    test('a running transcript shows its progress as the badge', () {
      final item = NoteListItem.from(
        _info(at),
        status: TranscriptStatus.running,
        progress: 0.4,
      );
      expect(item.title, 'Waiting for transcript');
      expect(item.badge, 'Transcribing 40%');
    });

    test('a note still being written says only that', () {
      final item = NoteListItem.from(
        _info(at),
        status: TranscriptStatus.none,
        isWriting: true,
      );
      expect(item.meta, '09:14 · Writing…');
      expect(item.badge, isNull);
    });

    test('audio badges only when they tell the user something', () {
      final deleted = NoteListItem.from(
        _info(at, hasAudio: false),
        status: TranscriptStatus.done,
      );
      expect(deleted.badge, 'Audio deleted');

      final keptWhileDeleting = NoteListItem.from(
        _info(at, keepAudio: true),
        status: TranscriptStatus.none,
        autoDeleteAudio: true,
      );
      expect(keptWhileDeleting.badge, 'Audio kept');
      expect(keptWhileDeleting.badgeKind, NoteBadgeKind.accent);

      // With nothing being deleted, "kept" means nothing.
      final keptAnyway = NoteListItem.from(
        _info(at, keepAudio: true),
        status: TranscriptStatus.none,
      );
      expect(keptAnyway.badge, isNull);
    });
  });
}
