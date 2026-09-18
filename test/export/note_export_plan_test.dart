import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/drivers/file_store.dart';
import 'package:voicenotetaker_app/services/export/note_export_plan.dart';
import 'package:voicenotetaker_app/services/export/zip_writer.dart';

const String dir = '/documents/recordings';

FileInfo file(String name, {int bytes = 1000, DateTime? at}) => FileInfo(
      path: '$dir/$name',
      sizeBytes: bytes,
      modifiedAt: at ?? DateTime(2026, 9, 18, 12),
    );

/// A note: the recording plus the sidecars named after it.
List<FileInfo> note(
  String stamp, {
  int bytes = 1000,
  List<String> sidecars = const <String>['.transcript.json'],
}) =>
    <FileInfo>[
      file('voicenote-$stamp.wav', bytes: bytes),
      for (final suffix in sidecars) file('voicenote-$stamp$suffix', bytes: 50),
    ];

void main() {
  // Thursday.
  final now = DateTime(2026, 9, 18, 21, 30);

  group('what goes in', () {
    test('today takes the notes with today\'s date and nothing older', () {
      final plan = planExport(
        directoryFiles: <FileInfo>[
          ...note('20260918-090000'),
          ...note('20260918-201500'),
          ...note('20260917-235959'),
        ],
        range: ExportRange.today,
        now: now,
      );

      expect(plan.noteCount, 2);
      expect(
        plan.files.map((f) => f.nameInZip),
        <String>[
          'recordings/voicenote-20260918-090000.wav',
          'recordings/voicenote-20260918-090000.transcript.json',
          'recordings/voicenote-20260918-201500.wav',
          'recordings/voicenote-20260918-201500.transcript.json',
        ],
      );
    });

    test('today means the calendar day, not the last 24 hours', () {
      // 00:10, and a note from 23:50 last night. "Today" must not sweep it in.
      final plan = planExport(
        directoryFiles: <FileInfo>[
          ...note('20260918-001000'),
          ...note('20260917-235000'),
        ],
        range: ExportRange.today,
        now: DateTime(2026, 9, 18, 0, 10),
      );
      expect(plan.noteCount, 1);
      expect(plan.files.first.nameInZip,
          'recordings/voicenote-20260918-001000.wav');
    });

    test('last 7 days is seven whole days, today included', () {
      final plan = planExport(
        directoryFiles: <FileInfo>[
          ...note('20260918-100000'), // today
          ...note('20260912-000001'), // seventh day back, just after midnight
          ...note('20260911-235959'), // eighth day back
        ],
        range: ExportRange.lastSevenDays,
        now: now,
      );
      expect(plan.noteCount, 2);
      expect(
        plan.files.map((f) => f.nameInZip),
        contains('recordings/voicenote-20260912-000001.wav'),
      );
      expect(
        plan.files.map((f) => f.nameInZip),
        isNot(contains('recordings/voicenote-20260911-235959.wav')),
      );
    });

    test('everything takes every note, however old', () {
      final plan = planExport(
        directoryFiles: <FileInfo>[
          ...note('20260918-100000'),
          ...note('20240101-000000'),
        ],
        range: ExportRange.everything,
        now: now,
      );
      expect(plan.noteCount, 2);
      expect(plan.files, hasLength(4));
    });

    test('sidecars ride with their recording, never with their own date', () {
      // Speaker names edited today; the note itself is from last month. A
      // "today" export must not pull the old note in on the strength of a
      // sidecar's modification time.
      final plan = planExport(
        directoryFiles: <FileInfo>[
          file('voicenote-20260810-120000.wav'),
          file('voicenote-20260810-120000.speakers.json',
              at: DateTime(2026, 9, 18, 20)),
        ],
        range: ExportRange.today,
        now: now,
      );
      expect(plan.isEmpty, isTrue);
    });

    test('every sidecar a note has collected comes along', () {
      final plan = planExport(
        directoryFiles: note(
          '20260918-090000',
          sidecars: <String>[
            '.transcript.json',
            '.speakers.json',
            '.speaker-settings.json',
            '.keep-audio.json',
          ],
        ),
        range: ExportRange.today,
        now: now,
      );
      expect(plan.files, hasLength(5));
      expect(plan.noteCount, 1, reason: 'five files, but one note');
    });

    test('a note whose audio the sweep removed still exports its transcript',
        () {
      final plan = planExport(
        directoryFiles: <FileInfo>[
          file('voicenote-20260918-090000.transcript.json', bytes: 400),
          file('voicenote-20260918-090000.audio-removed.json', bytes: 40),
        ],
        range: ExportRange.today,
        now: now,
      );
      expect(plan.files, hasLength(2));
      expect(plan.noteCount, 0, reason: 'there is no recording to count');
      expect(plan.isEmpty, isFalse);
    });

    test('a file with a name we do not recognise is kept only by "everything"',
        () {
      final files = <FileInfo>[file('notes-from-somewhere-else.txt')];

      expect(
        planExport(
          directoryFiles: files,
          range: ExportRange.today,
          now: now,
        ).isEmpty,
        isTrue,
      );
      expect(
        planExport(
          directoryFiles: files,
          range: ExportRange.everything,
          now: now,
        ).files.single.nameInZip,
        'recordings/notes-from-somewhere-else.txt',
      );
    });

    test('a recording whose name does not parse falls back to its mtime', () {
      final plan = planExport(
        directoryFiles: <FileInfo>[
          FileInfo(
            path: '$dir/odd-name.wav',
            sizeBytes: 100,
            modifiedAt: DateTime(2026, 9, 18, 8),
          ),
        ],
        range: ExportRange.today,
        now: now,
      );
      expect(plan.noteCount, 1);
    });

    test('an empty directory plans an empty export', () {
      final plan = planExport(
        directoryFiles: const <FileInfo>[],
        range: ExportRange.everything,
        now: now,
      );
      expect(plan.isEmpty, isTrue);
      expect(plan.noteCount, 0);
      expect(plan.zipBytes, 22, reason: 'the end record and nothing else');
    });
  });

  group('order', () {
    test('oldest note first, and its recording before its sidecars', () {
      final plan = planExport(
        directoryFiles: <FileInfo>[
          ...note('20260918-160000',
              sidecars: <String>['.speakers.json', '.transcript.json']),
          ...note('20260918-080000', sidecars: <String>['.transcript.json']),
        ],
        range: ExportRange.today,
        now: now,
      );
      expect(plan.files.map((f) => f.nameInZip), <String>[
        'recordings/voicenote-20260918-080000.wav',
        'recordings/voicenote-20260918-080000.transcript.json',
        'recordings/voicenote-20260918-160000.wav',
        'recordings/voicenote-20260918-160000.speakers.json',
        'recordings/voicenote-20260918-160000.transcript.json',
      ]);
    });
  });

  group('naming', () {
    test('says what is in it and when it was made', () {
      expect(exportFileName(range: ExportRange.today, now: now),
          'voicenotetaker-20260918.zip');
      expect(exportFileName(range: ExportRange.lastSevenDays, now: now),
          'voicenotetaker-20260912-to-20260918.zip');
      expect(exportFileName(range: ExportRange.everything, now: now),
          'voicenotetaker-all-20260918.zip');
    });

    test('pads single-digit months and days', () {
      expect(
        exportFileName(range: ExportRange.today, now: DateTime(2026, 3, 4)),
        'voicenotetaker-20260304.zip',
      );
    });

    test('a 7-day window that crosses a month boundary counts days, not hours',
        () {
      // 3 Oct, so the window opens on 27 Sep.
      final october = DateTime(2026, 10, 3, 9);
      expect(
        exportFileName(range: ExportRange.lastSevenDays, now: october),
        'voicenotetaker-20260927-to-20261003.zip',
      );
      final plan = planExport(
        directoryFiles: <FileInfo>[
          ...note('20260927-000000'),
          ...note('20260926-235959'),
        ],
        range: ExportRange.lastSevenDays,
        now: october,
      );
      expect(plan.noteCount, 1);
    });

    test('the plan carries the same name', () {
      final plan = planExport(
        directoryFiles: note('20260918-090000'),
        range: ExportRange.today,
        now: now,
      );
      expect(plan.zipName, 'voicenotetaker-20260918.zip');
    });

    test('members keep the file name the phone uses, under recordings/', () {
      final plan = planExport(
        directoryFiles: note('20260918-090000'),
        range: ExportRange.today,
        now: now,
      );
      expect(plan.files.first.sourcePath,
          '$dir/voicenote-20260918-090000.wav');
      expect(plan.files.first.nameInZip,
          'recordings/voicenote-20260918-090000.wav');
    });
  });

  group('size accounting', () {
    test('zipBytes is the files plus their headers, exactly', () {
      final plan = planExport(
        directoryFiles: note('20260918-090000', bytes: 640000),
        range: ExportRange.today,
        now: now,
      );
      expect(plan.audioBytes, 640050);
      expect(
        plan.zipBytes,
        ZipWriter.sizeOf(
          names: plan.files.map((f) => f.nameInZip).toList(),
          sizes: plan.files.map((f) => f.sizeBytes).toList(),
        ),
      );
      expect(plan.zipBytes, greaterThan(plan.audioBytes),
          reason: 'headers are not free');
    });

    test('audioBytes counts every member, sidecars included', () {
      final plan = planExport(
        directoryFiles: note('20260918-090000',
            bytes: 1000, sidecars: <String>['.transcript.json']),
        range: ExportRange.today,
        now: now,
      );
      expect(plan.audioBytes, 1050);
    });

    test('a library past 4 GB is refused rather than written wrong', () {
      final plan = planExport(
        directoryFiles: <FileInfo>[
          file('voicenote-20260918-090000.wav', bytes: 3000000000),
          file('voicenote-20260918-100000.wav', bytes: 2000000000),
        ],
        range: ExportRange.today,
        now: now,
      );
      expect(plan.tooLarge, isTrue);
      expect(plan.zipBytes, greaterThan(ZipWriter.maxArchiveBytes));
    });

    test('an ordinary day is not refused', () {
      final plan = planExport(
        directoryFiles: <FileInfo>[
          for (var hour = 8; hour < 20; hour++)
            ...note('202609${18}-${hour.toString().padLeft(2, '0')}0000',
                bytes: 115 * 1000 * 1000),
        ],
        range: ExportRange.today,
        now: now,
      );
      expect(plan.noteCount, 12);
      expect(plan.tooLarge, isFalse);
    });
  });

  group('the range labels', () {
    test('are the words on the buttons', () {
      expect(ExportRange.today.label, 'Today');
      expect(ExportRange.lastSevenDays.label, 'Last 7 days');
      expect(ExportRange.everything.label, 'Everything');
    });
  });
}
