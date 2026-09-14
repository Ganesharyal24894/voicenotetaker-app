/// What the Notes tab shows, worked out from the library and the transcript
/// states.
///
/// PURE: no clock, no I/O, no widgets. The view hands in what the controller
/// knows and renders what comes back.
library;

import 'audio_retention.dart';
import 'recording_info.dart';
import 'summary/summary_range.dart';
import 'transcript.dart';

/// The one word a Notes-today row may carry.
enum NoteRowState {
  /// Nothing worth a label: transcribed, or no speech, or not looked at.
  plain,

  /// Always-listening is still writing it.
  writing,

  /// Being transcribed now.
  transcribing,

  /// In the transcription queue.
  waiting,

  /// Transcription failed or the file cannot be transcribed.
  failed,
}

class NoteRow {
  const NoteRow({required this.recording, required this.state, this.progress});

  final RecordingInfo recording;
  final NoteRowState state;

  /// 0-1 while [NoteRowState.transcribing] and the job has said how far it is.
  final double? progress;
}

class NotesOverview {
  const NotesOverview({
    required this.today,
    required this.speech,
    required this.noteCount,
    required this.conversationCount,
    required this.audioDeletingSoon,
    required this.firstAudioDeletion,
    required this.failed,
  });

  /// How close to its removal a note's audio must be before Notes asks the
  /// user to look. Six hours: soon enough to be true, early enough that a
  /// morning glance catches notes from the previous morning.
  static const Duration audioWarning = Duration(hours: 6);

  /// Today's notes, newest first.
  final List<NoteRow> today;

  /// Total length of today's notes. Always-listening keeps only speech, with
  /// long pauses shortened, so this is close to time spent talking.
  final Duration speech;

  final int noteCount;

  /// Today's notes always-listening made on its own; null when that is not
  /// known, in which case only [noteCount] is shown.
  final int? conversationCount;

  /// Notes whose audio the 24-hour sweep removes within [audioWarning]. Empty
  /// unless auto-delete is on.
  final List<RecordingInfo> audioDeletingSoon;

  /// When the first of those goes; null when there are none.
  final DateTime? firstAudioDeletion;

  /// Notes that could not be transcribed, newest first.
  final List<RecordingInfo> failed;

  bool get needsYou => audioDeletingSoon.isNotEmpty || failed.isNotEmpty;

  /// Show conversations as their own figure only when it says something the
  /// note count does not.
  bool get showConversations =>
      conversationCount != null && conversationCount != noteCount;

  static NotesOverview derive({
    required List<RecordingInfo> recordings,
    required DateTime now,
    required TranscriptStatus Function(RecordingInfo) statusOf,
    String? writingPath,
    String? transcribingPath,
    int transcriptionDone = 0,
    int transcriptionTotal = 0,
    bool autoDeleteAudio = false,
    bool Function(RecordingInfo)? isAutomatic,
  }) {
    final window = SummaryRange.today.windowAt(now);
    final sorted = <RecordingInfo>[...recordings]
      ..sort((a, b) => b.recordedAt.compareTo(a.recordedAt));

    final today = <NoteRow>[];
    var speech = Duration.zero;
    var automatic = 0;
    final failed = <RecordingInfo>[];
    final soon = <RecordingInfo>[];
    DateTime? first;

    for (final recording in sorted) {
      final writing = recording.path == writingPath;
      final status = writing ? null : statusOf(recording);
      final isFailed = status == TranscriptStatus.failed ||
          status == TranscriptStatus.unsupported;
      if (isFailed) failed.add(recording);

      if (autoDeleteAudio &&
          !writing &&
          recording.hasAudio &&
          !recording.keepAudio &&
          status == TranscriptStatus.done) {
        final removal = recording.recordedAt.add(AudioRetention.maxAge);
        if (removal.difference(now) <= audioWarning) {
          soon.add(recording);
          final at = removal.isBefore(now) ? now : removal;
          if (first == null || at.isBefore(first)) first = at;
        }
      }

      if (!window.contains(recording.recordedAt)) continue;
      speech += recording.duration ?? Duration.zero;
      if (isAutomatic?.call(recording) ?? false) automatic++;
      final NoteRowState state;
      double? progress;
      if (writing) {
        state = NoteRowState.writing;
      } else if (recording.path == transcribingPath ||
          status == TranscriptStatus.running) {
        state = NoteRowState.transcribing;
        if (transcriptionTotal > 0) {
          progress = (transcriptionDone / transcriptionTotal).clamp(0.0, 1.0);
        }
      } else if (status == TranscriptStatus.queued) {
        state = NoteRowState.waiting;
      } else if (isFailed) {
        state = NoteRowState.failed;
      } else {
        state = NoteRowState.plain;
      }
      today.add(NoteRow(recording: recording, state: state, progress: progress));
    }

    return NotesOverview(
      today: today,
      speech: speech,
      noteCount: today.length,
      conversationCount: isAutomatic == null ? null : automatic,
      audioDeletingSoon: soon,
      firstAudioDeletion: first,
      failed: failed,
    );
  }
}
