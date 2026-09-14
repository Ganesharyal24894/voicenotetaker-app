import 'dart:convert';

import '../drivers/file_store.dart';
import '../model/empty_note_policy.dart';
import 'library_service.dart';
import 'transcription/transcript_store.dart';

/// What is using a note right now, as the controller knows it.
typedef NoteUse = ({
  bool writing,
  bool capturing,
  bool open,
  bool transcribing,
});

/// What one sweep did.
class EmptyNoteSweepReport {
  const EmptyNoteSweepReport({
    required this.deleted,
    required this.deferred,
    required this.failed,
    required this.verdicts,
  });

  static const EmptyNoteSweepReport nothing = EmptyNoteSweepReport(
    deleted: <String>[],
    deferred: <String>[],
    failed: <String>[],
    verdicts: <String, EmptyNoteVerdict>{},
  );

  /// Notes deleted, by recording path.
  final List<String> deleted;

  /// Notes left for later - open, written, recorded or transcribed.
  final List<String> deferred;

  /// Notes whose deletion threw; the marker stays, so the next sweep tries
  /// again.
  final List<String> failed;

  final Map<String, EmptyNoteVerdict> verdicts;

  @override
  String toString() =>
      'EmptyNoteSweepReport(deleted ${deleted.length}, deferred '
      '${deferred.length}, failed ${failed.length} of ${verdicts.length})';
}

/// Deletes notes in which nothing was said, by the [EmptyNotePolicy] rules.
///
/// Domain logic over [FileStore].
///
/// SAFE WHEN KILLED. The marker (`RecordingNaming.emptyNotePathOf`) is written
/// before any file goes, and removed after the last one. A sweep killed half
/// way leaves the marker, and the next sweep - every start runs one - sees
/// either the transcript still empty, or audio and transcript both gone, and
/// finishes. A deferred note keeps its marker the same way.
class EmptyNoteService {
  EmptyNoteService({
    required this._fileStore,
    required this._directory,
    required this._transcripts,
    required String settingsDirectory,
  }) : _sweepDonePath = _fileStore.join(settingsDirectory, sweepDoneFileName);

  /// Written once every existing note has been looked at, so that full sweep
  /// runs once; the marker sweep runs at every start.
  static const String sweepDoneFileName = 'empty-notes-sweep.json';

  final FileStore _fileStore;
  final String _directory;
  final TranscriptStore _transcripts;
  final String _sweepDonePath;

  /// Records that [audioPath]'s transcription found no speech. The next
  /// [sweep] deletes it when the rules allow.
  Future<void> markEmpty(String audioPath, {required DateTime now}) =>
      _fileStore.writeBytes(
        RecordingNaming.emptyNotePathOf(audioPath),
        utf8.encode(jsonEncode(<String, Object?>{
          'version': 1,
          'markedAt': now.toUtc().toIso8601String(),
        })),
      );

  /// Whether the one-time sweep of every note has run on this install.
  Future<bool> isFullSweepDone() async {
    try {
      return await _fileStore.stat(_sweepDonePath) != null;
    } on Object {
      return false;
    }
  }

  /// Looks at every marked note - and, with [allNotes], every note with a
  /// saved transcript - and deletes those [EmptyNotePolicy] allows.
  ///
  /// [useOf] is asked when a note is judged and again right before its files
  /// go, because the sweep awaits in between. Never throws; a failed delete
  /// is reported. With [allNotes], a completed sweep is remembered.
  Future<EmptyNoteSweepReport> sweep({
    required NoteUse Function(String audioPath) useOf,
    required DateTime now,
    bool allNotes = false,
  }) async {
    final List<String> paths;
    try {
      paths = await _fileStore.list(_directory);
    } on Object {
      return EmptyNoteSweepReport.nothing;
    }
    final present = paths.toSet();
    final candidates = <String>{
      for (final path in paths)
        if (path.endsWith(RecordingNaming.emptyNoteSuffix))
          RecordingNaming.audioPathOfSidecar(
            path,
            RecordingNaming.emptyNoteSuffix,
          )
        else if (allNotes &&
            path.toLowerCase().endsWith(RecordingNaming.extension) &&
            present.contains(RecordingNaming.transcriptPathOf(path)) &&
            !present.contains(RecordingNaming.transcriptFailurePathOf(path)))
          path,
    };

    final deleted = <String>[];
    final deferred = <String>[];
    final failed = <String>[];
    final verdicts = <String, EmptyNoteVerdict>{};
    for (final audio in candidates.toList()..sort()) {
      final marker = RecordingNaming.emptyNotePathOf(audio);
      try {
        final transcript = await _transcripts.load(audio);
        final kind = transcript == null
            ? EmptyNoteTranscript.none
            : transcript.hasSpeech
                ? EmptyNoteTranscript.speech
                : EmptyNoteTranscript.empty;
        EmptyNoteFacts factsNow() {
          final use = useOf(audio);
          return EmptyNoteFacts(
            hasAudio: present.contains(audio),
            transcript: kind,
            failed: present.contains(
              RecordingNaming.transcriptFailurePathOf(audio),
            ),
            keep: present.contains(RecordingNaming.keepAudioPathOf(audio)),
            writing: use.writing,
            capturing: use.capturing,
            open: use.open,
            transcribing: use.transcribing,
          );
        }

        var verdict = EmptyNotePolicy.decide(factsNow());
        final marked = present.contains(marker);
        if (verdict == EmptyNoteVerdict.delete) {
          // Marker first: from here a kill is finished by the next sweep.
          if (!marked) await markEmpty(audio, now: now);
          // Fresh facts from the disk and the controller, after the awaits.
          present
            ..remove(RecordingNaming.keepAudioPathOf(audio))
            ..remove(RecordingNaming.transcriptFailurePathOf(audio))
            ..remove(audio);
          if (await _fileStore.stat(audio) != null) present.add(audio);
          if (await _fileStore.stat(RecordingNaming.keepAudioPathOf(audio)) !=
              null) {
            present.add(RecordingNaming.keepAudioPathOf(audio));
          }
          if (await _fileStore.stat(
                RecordingNaming.transcriptFailurePathOf(audio),
              ) !=
              null) {
            present.add(RecordingNaming.transcriptFailurePathOf(audio));
          }
          verdict = EmptyNotePolicy.decide(factsNow());
        }
        verdicts[audio] = verdict;
        if (verdict == EmptyNoteVerdict.delete) {
          await LibraryService.deleteFiles(_fileStore, audio);
          deleted.add(audio);
        } else if (verdict.isDeferred) {
          deferred.add(audio);
          // Remembered across a restart, but only for a note known empty.
          if (!marked && kind == EmptyNoteTranscript.empty) {
            await markEmpty(audio, now: now);
          }
        } else {
          // Kept, failed, words, or no transcript: forget any intent.
          if (await _fileStore.stat(marker) != null) {
            await _fileStore.delete(marker);
          }
        }
      } on Object {
        failed.add(audio);
      }
    }
    if (allNotes && failed.isEmpty) {
      try {
        await _fileStore.writeBytes(
          _sweepDonePath,
          utf8.encode(jsonEncode(<String, Object?>{
            'version': 1,
            'doneAt': now.toUtc().toIso8601String(),
          })),
        );
      } on Object {
        // Runs again next start; it changes nothing twice.
      }
    }
    return EmptyNoteSweepReport(
      deleted: List<String>.unmodifiable(deleted),
      deferred: List<String>.unmodifiable(deferred),
      failed: List<String>.unmodifiable(failed),
      verdicts: Map<String, EmptyNoteVerdict>.unmodifiable(verdicts),
    );
  }
}
