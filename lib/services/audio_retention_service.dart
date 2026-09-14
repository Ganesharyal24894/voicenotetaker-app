import 'dart:convert';

import '../drivers/file_store.dart';
import '../model/audio_retention.dart';
import 'library_service.dart';
import 'transcription/transcript_store.dart';

/// What one sweep did.
class RetentionSweepReport {
  const RetentionSweepReport({
    required this.removed,
    required this.failed,
    required this.verdicts,
  });

  static const RetentionSweepReport nothing = RetentionSweepReport(
    removed: <String>[],
    failed: <String>[],
    verdicts: <String, RetentionVerdict>{},
  );

  /// Recordings whose WAV was removed.
  final List<String> removed;

  /// Recordings whose WAV should have been removed and could not be; the next
  /// sweep tries again.
  final List<String> failed;

  /// The verdict for every recording looked at, by path.
  final Map<String, RetentionVerdict> verdicts;

  @override
  String toString() =>
      'RetentionSweepReport(removed ${removed.length}, failed ${failed.length}'
      ' of ${verdicts.length})';
}

/// Removes recordings' audio 24 hours after they were made, keeping their
/// transcripts - and the "keep this audio" markers that stop it.
///
/// Domain logic over [FileStore]; the rules are [AudioRetention]'s. Nothing
/// here decides WHETHER a sweep runs - that is the `autoDeleteAudio` setting,
/// in the controller.
///
/// SAFE WHEN KILLED. For each recording: re-check the keep marker and whether
/// it is in use, write the audio-removed marker, then delete the WAV. Killed
/// after the marker, the WAV is still there and still listed, and the next
/// sweep removes it; killed after the delete, the marker already lists the
/// note from its transcript. The transcript itself is never touched.
class AudioRetentionService {
  AudioRetentionService({
    required this._fileStore,
    required this._directory,
    required this._transcripts,
  });

  final FileStore _fileStore;
  final String _directory;
  final TranscriptStore _transcripts;

  Future<bool> isKept(String audioPath) async =>
      await _fileStore.stat(RecordingNaming.keepAudioPathOf(audioPath)) !=
      null;

  /// Marks [audioPath]'s audio as kept, or not. Idempotent.
  Future<void> setKeep(String audioPath, {required bool keep}) async {
    final marker = RecordingNaming.keepAudioPathOf(audioPath);
    if (keep) {
      await _fileStore.writeBytes(
        marker,
        utf8.encode(jsonEncode(<String, Object?>{'version': 1})),
      );
    } else {
      await _fileStore.delete(marker);
    }
  }

  /// Looks at every recording and removes the audio [AudioRetention] allows.
  ///
  /// [isInUse] is asked twice per recording - when it is judged and again right
  /// before the delete - because the sweep awaits in between and playback or
  /// a transcription may have started meanwhile. A failed delete is reported,
  /// never thrown.
  Future<RetentionSweepReport> sweep({
    required DateTime now,
    required bool Function(String audioPath) isInUse,
  }) async {
    final paths = await _fileStore.list(_directory);
    final present = paths.toSet();
    final removed = <String>[];
    final failed = <String>[];
    final verdicts = <String, RetentionVerdict>{};

    for (final path in paths) {
      if (!path.toLowerCase().endsWith(RecordingNaming.extension)) continue;
      final name = _nameOf(path);
      final hasTranscript =
          present.contains(RecordingNaming.transcriptPathOf(path));
      final hasFailure =
          present.contains(RecordingNaming.transcriptFailurePathOf(path));
      final startedAt = RecordingNaming.timestampOf(name);
      var facts = RetentionFacts(
        hasAudio: true,
        keep: present.contains(RecordingNaming.keepAudioPathOf(path)),
        inUse: isInUse(path),
        startedAt: startedAt,
        // Only for a file whose name carries no time; otherwise it is read in
        // the second pass, where it can only postpone.
        modifiedAt: startedAt == null
            ? (await _fileStore.stat(path))?.modifiedAt
            : null,
        // Assumed good until the cheap rules say "delete": the transcript is
        // only ever a reason to KEEP, so reading it just for the recordings
        // that got that far gives the same verdict for a fraction of the I/O.
        transcript: hasFailure
            ? RetentionTranscript.failed
            : hasTranscript
                ? RetentionTranscript.done
                : RetentionTranscript.none,
      );
      var verdict = AudioRetention.decide(facts, now: now);
      if (verdict == RetentionVerdict.delete) {
        final stat = await _fileStore.stat(path);
        final transcript = await _transcripts.load(path);
        facts = RetentionFacts(
          hasAudio: stat != null,
          keep: await isKept(path),
          inUse: isInUse(path),
          startedAt: facts.startedAt,
          modifiedAt: stat?.modifiedAt,
          transcript: transcript == null
              ? RetentionTranscript.none
              : transcript.hasSpeech
                  ? RetentionTranscript.done
                  : RetentionTranscript.empty,
        );
        verdict = AudioRetention.decide(facts, now: now);
      }
      verdicts[path] = verdict;
      if (verdict != RetentionVerdict.delete) continue;
      try {
        await _fileStore.writeBytes(
          RecordingNaming.audioRemovedPathOf(path),
          utf8.encode(jsonEncode(<String, Object?>{
            'version': 1,
            'removedAt': now.toUtc().toIso8601String(),
          })),
        );
        // The last await before the delete was the marker write; one more
        // look, so a playback started in that gap is not pulled from under.
        if (isInUse(path)) {
          verdicts[path] = RetentionVerdict.inUse;
          continue;
        }
        await _fileStore.delete(path);
        removed.add(path);
      } on Object {
        failed.add(path);
      }
    }
    return RetentionSweepReport(
      removed: List<String>.unmodifiable(removed),
      failed: List<String>.unmodifiable(failed),
      verdicts: Map<String, RetentionVerdict>.unmodifiable(verdicts),
    );
  }

  String _nameOf(String path) {
    final slash = path.lastIndexOf(RegExp(r'[/\\]'));
    return slash < 0 ? path : path.substring(slash + 1);
  }
}

/// The retention setting, in one small JSON file beside the other settings.
class AudioRetentionSettingsStore {
  AudioRetentionSettingsStore({
    required this._fileStore,
    required String directory,
  }) : path = _fileStore.join(directory, fileName);

  static const String fileName = 'audio-retention-settings.json';

  final FileStore _fileStore;
  final String path;

  /// Whether audio is removed 24 h after recording. False when never saved or
  /// unreadable: the default is to delete nothing.
  Future<bool> loadAutoDeleteAudio() async {
    try {
      if (await _fileStore.stat(path) == null) return false;
      final json = jsonDecode(utf8.decode(await _fileStore.read(path)));
      return json is Map<String, Object?> &&
          json['version'] == 1 &&
          json['autoDeleteAudio'] == true;
    } on Object {
      return false;
    }
  }

  Future<void> saveAutoDeleteAudio(bool enabled) => _fileStore.writeBytes(
        path,
        utf8.encode(jsonEncode(<String, Object?>{
          'version': 1,
          'autoDeleteAudio': enabled,
        })),
      );
}
