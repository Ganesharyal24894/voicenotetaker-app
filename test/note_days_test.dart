import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/note_days.dart';
import 'package:voicenotetaker_app/model/recording_info.dart';

RecordingInfo _at(DateTime when, {bool hasAudio = true}) => RecordingInfo(
      path: '/rec/${when.toIso8601String()}.wav',
      name: 'n',
      recordedAt: when,
      sizeBytes: hasAudio ? 1 : 0,
      duration: const Duration(minutes: 4),
      hasAudio: hasAudio,
      hasTranscript: !hasAudio,
    );

void main() {
  group('NoteDayIndex', () {
    test('counts the notes on each day, whatever time of day they were', () {
      final index = NoteDayIndex.of(<RecordingInfo>[
        _at(DateTime(2026, 9, 20, 0, 1)),
        _at(DateTime(2026, 9, 20, 17, 20)),
        _at(DateTime(2026, 9, 20, 23, 59)),
        _at(DateTime(2026, 9, 18, 9, 14)),
      ]);

      expect(index.total, 4);
      expect(index.countFor(DateTime(2026, 9, 20)), 3);
      expect(index.countFor(DateTime(2026, 9, 18)), 1);
      // Any time on that day asks the same question.
      expect(index.countFor(DateTime(2026, 9, 18, 22, 30)), 1);
    });

    test('a day with nothing on it has nothing, and is not selectable', () {
      final index = NoteDayIndex.of(<RecordingInfo>[
        _at(DateTime(2026, 9, 20, 9)),
      ]);

      expect(index.countFor(DateTime(2026, 9, 19)), 0);
      expect(index.has(DateTime(2026, 9, 19)), isFalse);
      expect(index.has(DateTime(2026, 9, 20)), isTrue);
    });

    test('a note whose audio was deleted still counts - it is still a note',
        () {
      final index = NoteDayIndex.of(<RecordingInfo>[
        _at(DateTime(2026, 9, 12, 11), hasAudio: false),
        _at(DateTime(2026, 9, 12, 15), hasAudio: false),
      ]);

      expect(index.countFor(DateTime(2026, 9, 12)), 2);
      expect(index.has(DateTime(2026, 9, 12)), isTrue);
    });

    test('picked days add up - the Show N notes number', () {
      final index = NoteDayIndex.of(<RecordingInfo>[
        _at(DateTime(2026, 9, 20, 9)),
        _at(DateTime(2026, 9, 20, 11)),
        _at(DateTime(2026, 9, 18, 9)),
        _at(DateTime(2026, 9, 12, 9)),
      ]);

      expect(
        index.countForAll(<DateTime>{
          DateTime(2026, 9, 20),
          DateTime(2026, 9, 12),
        }),
        3,
      );
      // A day with nothing adds nothing rather than breaking the sum.
      expect(
        index.countForAll(<DateTime>{DateTime(2026, 9, 19)}),
        0,
      );
      expect(index.countForAll(const <DateTime>{}), 0);
    });

    test('an empty month is empty, and a month with one note is not', () {
      final index = NoteDayIndex.of(<RecordingInfo>[
        _at(DateTime(2026, 9, 20, 9)),
      ]);

      expect(index.hasMonth(DateTime(2026, 9)), isTrue);
      expect(index.hasMonth(DateTime(2026, 8)), isFalse);
      expect(index.hasMonth(DateTime(2026, 10)), isFalse);
      // Same month, different year, is a different month.
      expect(index.hasMonth(DateTime(2025, 9)), isFalse);
    });

    test('no notes at all: nothing counted, no newest day', () {
      final index = NoteDayIndex.of(const <RecordingInfo>[]);

      expect(index.total, 0);
      expect(index.newestDay, isNull);
      expect(index.days, isEmpty);
      expect(index.hasMonth(DateTime(2026, 9)), isFalse);
      expect(NoteDayIndex.empty.total, 0);
      expect(NoteDayIndex.empty.newestDay, isNull);
    });

    test('days come back newest first, and the newest is the newest', () {
      final index = NoteDayIndex.of(<RecordingInfo>[
        _at(DateTime(2026, 9, 12, 9)),
        _at(DateTime(2026, 9, 20, 9)),
        _at(DateTime(2026, 9, 18, 9)),
      ]);

      expect(index.days, <DateTime>[
        DateTime(2026, 9, 20),
        DateTime(2026, 9, 18),
        DateTime(2026, 9, 12),
      ]);
      expect(index.newestDay, DateTime(2026, 9, 20));
    });

    test('dayOf is midnight, and is what a day is keyed on', () {
      expect(
        NoteDayIndex.dayOf(DateTime(2026, 9, 20, 23, 59, 59)),
        DateTime(2026, 9, 20),
      );
      expect(
        NoteDayIndex.dayOf(DateTime(2026, 9, 20)),
        DateTime(2026, 9, 20),
      );
    });
  });
}
