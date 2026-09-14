import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/notes_overview.dart';
import 'package:voicenotetaker_app/model/recording_info.dart';
import 'package:voicenotetaker_app/model/transcript.dart';

RecordingInfo _rec(
  DateTime at, {
  int minutes = 10,
  bool hasAudio = true,
  bool keep = false,
}) =>
    RecordingInfo(
      path: '/r/${at.millisecondsSinceEpoch}.wav',
      name: 'n',
      recordedAt: at,
      sizeBytes: 1,
      duration: Duration(minutes: minutes),
      hasAudio: hasAudio,
      keepAudio: keep,
    );

void main() {
  final now = DateTime(2026, 9, 15, 18, 0);

  NotesOverview derive(
    List<RecordingInfo> recordings, {
    Map<String, TranscriptStatus> status = const <String, TranscriptStatus>{},
    String? writing,
    String? transcribing,
    int done = 0,
    int total = 0,
    bool autoDelete = false,
    bool Function(RecordingInfo)? isAutomatic,
  }) =>
      NotesOverview.derive(
        recordings: recordings,
        now: now,
        statusOf: (r) => status[r.path] ?? TranscriptStatus.done,
        writingPath: writing,
        transcribingPath: transcribing,
        transcriptionDone: done,
        transcriptionTotal: total,
        autoDeleteAudio: autoDelete,
        isAutomatic: isAutomatic,
      );

  test('today only, newest first, with speech time and a count', () {
    final a = _rec(DateTime(2026, 9, 15, 9, 14), minutes: 12);
    final b = _rec(DateTime(2026, 9, 15, 17, 15), minutes: 6);
    final old = _rec(DateTime(2026, 9, 14, 23, 50));
    final overview = derive(<RecordingInfo>[a, old, b]);
    expect(overview.today.map((r) => r.recording), <RecordingInfo>[b, a]);
    expect(overview.speech, const Duration(minutes: 18));
    expect(overview.noteCount, 2);
    expect(overview.needsYou, isFalse);
  });

  test('row states: writing, transcribing with progress, waiting, failed, plain', () {
    final writing = _rec(DateTime(2026, 9, 15, 17, 52));
    final running = _rec(DateTime(2026, 9, 15, 17, 40));
    final queued = _rec(DateTime(2026, 9, 15, 17, 0));
    final failed = _rec(DateTime(2026, 9, 15, 14, 22));
    final unsupported = _rec(DateTime(2026, 9, 15, 13, 0));
    final plain = _rec(DateTime(2026, 9, 15, 12, 40));
    final overview = derive(
      <RecordingInfo>[writing, running, queued, failed, unsupported, plain],
      writing: writing.path,
      transcribing: running.path,
      done: 2,
      total: 5,
      status: <String, TranscriptStatus>{
        running.path: TranscriptStatus.running,
        queued.path: TranscriptStatus.queued,
        failed.path: TranscriptStatus.failed,
        unsupported.path: TranscriptStatus.unsupported,
        plain.path: TranscriptStatus.noSpeech,
      },
    );
    expect(overview.today.map((r) => r.state), <NoteRowState>[
      NoteRowState.writing,
      NoteRowState.transcribing,
      NoteRowState.waiting,
      NoteRowState.failed,
      NoteRowState.failed,
      NoteRowState.plain,
    ]);
    expect(overview.today[1].progress, 0.4);
    expect(overview.failed, <RecordingInfo>[failed, unsupported]);
    expect(overview.needsYou, isTrue);
  });

  test('transcribing before the job knows its length has no percentage', () {
    final running = _rec(DateTime(2026, 9, 15, 17, 40));
    final overview = derive(<RecordingInfo>[running], transcribing: running.path);
    expect(overview.today.single.state, NoteRowState.transcribing);
    expect(overview.today.single.progress, isNull);
  });

  test('failed notes from earlier days still need you; they are not in today', () {
    final old = _rec(DateTime(2026, 9, 12, 9));
    final overview = derive(<RecordingInfo>[old], status: <String, TranscriptStatus>{old.path: TranscriptStatus.failed});
    expect(overview.failed, <RecordingInfo>[old]);
    expect(overview.today, isEmpty);
  });

  group('audio that deletes soon', () {
    final soon = _rec(DateTime(2026, 9, 14, 20, 0)); // removed 20:00 today, in 2 h
    final later = _rec(DateTime(2026, 9, 15, 9, 0)); // removed tomorrow 09:00
    final overdue = _rec(DateTime(2026, 9, 14, 10, 0)); // due at the next sweep

    test('nothing at all while auto-delete is off', () {
      expect(derive(<RecordingInfo>[soon, overdue]).audioDeletingSoon, isEmpty);
    });

    test('within six hours, earliest first, overdue counted as now', () {
      final overview = derive(<RecordingInfo>[soon, later, overdue], autoDelete: true);
      expect(overview.audioDeletingSoon, unorderedEquals(<RecordingInfo>[soon, overdue]));
      expect(overview.firstAudioDeletion, now);
      expect(derive(<RecordingInfo>[soon], autoDelete: true).firstAudioDeletion, DateTime(2026, 9, 15, 20));
      expect(overview.needsYou, isTrue);
    });

    test('kept, already removed, untranscribed or still being written are not at risk', () {
      final kept = _rec(DateTime(2026, 9, 14, 20, 0), keep: true);
      final gone = _rec(DateTime(2026, 9, 14, 20, 1), hasAudio: false);
      final untranscribed = _rec(DateTime(2026, 9, 14, 20, 2));
      final writing = _rec(DateTime(2026, 9, 14, 20, 3));
      final overview = derive(
        <RecordingInfo>[kept, gone, untranscribed, writing],
        autoDelete: true,
        writing: writing.path,
        status: <String, TranscriptStatus>{untranscribed.path: TranscriptStatus.none},
      );
      expect(overview.audioDeletingSoon, isEmpty);
    });
  });

  group('conversations', () {
    final a = _rec(DateTime(2026, 9, 15, 9));
    final b = _rec(DateTime(2026, 9, 15, 10));

    test('unknown: only notes are shown', () {
      final overview = derive(<RecordingInfo>[a, b]);
      expect(overview.conversationCount, isNull);
      expect(overview.showConversations, isFalse);
    });

    test('equal to notes: shown once', () {
      final overview = derive(<RecordingInfo>[a, b], isAutomatic: (_) => true);
      expect(overview.conversationCount, 2);
      expect(overview.showConversations, isFalse);
    });

    test('different: both', () {
      final overview = derive(<RecordingInfo>[a, b], isAutomatic: (r) => r == a);
      expect(overview.conversationCount, 1);
      expect(overview.showConversations, isTrue);
    });
  });
}
