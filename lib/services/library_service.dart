import 'dart:async';
import 'dart:convert';

import '../drivers/file_store.dart';
import '../model/recording_info.dart';
import '../model/transcript.dart';
import 'wav_reader.dart';

/// The recording file-name convention, in one place.
///
/// The name carries the capture time, and the library reads it back, so the
/// two halves live together: a change to one that is not made to the other is
/// a change to this file and is caught by `test/library_service_test.dart`.
abstract final class RecordingNaming {
  static const String prefix = 'voicenote-';
  static const String extension = '.wav';

  /// `voicenote-20260910-143005.wav`.
  static String fileName(DateTime when) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '$prefix${when.year}${two(when.month)}${two(when.day)}'
        '-${two(when.hour)}${two(when.minute)}${two(when.second)}$extension';
  }

  /// Suffix of the transcript saved beside a recording.
  static const String transcriptSuffix = '.transcript.json';

  /// Where the transcript of the recording at [audioPath] is kept: the same
  /// directory and name, `.wav` swapped for [transcriptSuffix].
  ///
  /// Beside the recording rather than in a folder of its own, so the two can
  /// only be moved, backed up or deleted together. The library lists `.wav`
  /// files only, so it never shows one as a recording.
  static String transcriptPathOf(String audioPath) {
    final lower = audioPath.toLowerCase();
    final stem = lower.endsWith(extension)
        ? audioPath.substring(0, audioPath.length - extension.length)
        : audioPath;
    return '$stem$transcriptSuffix';
  }

  /// Suffix of the marker saved beside a recording whose transcription
  /// failed, so the background queue does not try it again on every launch.
  static const String transcriptFailureSuffix = '.transcript-failed.json';

  /// Where the failure marker of the recording at [audioPath] is kept.
  static String transcriptFailurePathOf(String audioPath) =>
      _sidecarOf(audioPath, transcriptFailureSuffix);

  /// Suffix of the marker saying "keep this recording's audio".
  ///
  /// A SIDECAR, NOT A FIELD IN THE TRANSCRIPT: a recording can be kept before
  /// it has a transcript at all, and transcribing again replaces the
  /// transcript file whole. Its PRESENCE is the flag, so the library learns
  /// it from the directory listing it already makes, and setting or clearing
  /// it is one create or one delete - nothing half-written to parse after a
  /// kill.
  static const String keepAudioSuffix = '.keep-audio.json';

  static String keepAudioPathOf(String audioPath) =>
      _sidecarOf(audioPath, keepAudioSuffix);

  /// Suffix of the marker the retention sweep writes BEFORE it removes a WAV.
  ///
  /// It is what tells "audio removed on purpose, transcript kept" apart from a
  /// stray transcript left behind by a failed delete, which must stay hidden.
  /// Written first, so a sweep killed between the two steps leaves a marker
  /// beside a WAV that is still there - listed normally, and removed by the
  /// next sweep.
  static const String audioRemovedSuffix = '.audio-removed.json';

  static String audioRemovedPathOf(String audioPath) =>
      _sidecarOf(audioPath, audioRemovedSuffix);

  /// Suffix of the names the user gave a note's speakers.
  ///
  /// A SIDECAR, NOT A FIELD IN THE TRANSCRIPT: transcribing again replaces
  /// the transcript file whole, and the names must outlive that. Keyed by
  /// speaker label, so a new transcript keeps the names of the labels it
  /// still uses. Deleted with the recording; the retention sweep leaves it.
  static const String speakerNamesSuffix = '.speakers.json';

  static String speakerNamesPathOf(String audioPath) =>
      _sidecarOf(audioPath, speakerNamesSuffix);

  /// Suffix of the speaker count and merges the user chose for a note.
  ///
  /// A SIDECAR FOR THE SAME REASON as the names, and separate from them: it
  /// says how the note is SEPARATED rather than what the speakers are called,
  /// and separating the note again reads it back to reach the same answer.
  static const String speakerSettingsSuffix = '.speaker-settings.json';

  static String speakerSettingsPathOf(String audioPath) =>
      _sidecarOf(audioPath, speakerSettingsSuffix);

  /// Suffix of the marker saying "nothing was said in this note; delete it
  /// once nothing is using it".
  ///
  /// Written when a transcription finds no speech, and BEFORE any file of the
  /// note is deleted, so a deletion that was deferred (the note was open) or
  /// killed half way is picked up again at the next start. Removed last. See
  /// `EmptyNotePolicy`.
  static const String emptyNoteSuffix = '.empty-note.json';

  static String emptyNotePathOf(String audioPath) =>
      _sidecarOf(audioPath, emptyNoteSuffix);

  /// The recording a sidecar at [sidecarPath] with [suffix] belongs to.
  static String audioPathOfSidecar(String sidecarPath, String suffix) =>
      '${sidecarPath.substring(0, sidecarPath.length - suffix.length)}'
      '$extension';

  static String _sidecarOf(String audioPath, String suffix) {
    final lower = audioPath.toLowerCase();
    final stem = lower.endsWith(extension)
        ? audioPath.substring(0, audioPath.length - extension.length)
        : audioPath;
    return '$stem$suffix';
  }

  /// The capture time encoded in [name], or `null` when it is not one of ours.
  static DateTime? timestampOf(String name) {
    if (!name.startsWith(prefix) || !name.endsWith(extension)) return null;
    final stamp = name.substring(prefix.length, name.length - extension.length);
    if (stamp.length != 15 || stamp[8] != '-') return null;
    final year = int.tryParse(stamp.substring(0, 4));
    final month = int.tryParse(stamp.substring(4, 6));
    final day = int.tryParse(stamp.substring(6, 8));
    final hour = int.tryParse(stamp.substring(9, 11));
    final minute = int.tryParse(stamp.substring(11, 13));
    final second = int.tryParse(stamp.substring(13, 15));
    if (year == null ||
        month == null ||
        day == null ||
        hour == null ||
        minute == null ||
        second == null) {
      return null;
    }
    final when = DateTime(year, month, day, hour, minute, second);
    // Rejects 2026-13-45: DateTime rolls those over instead of complaining.
    if (when.month != month || when.day != day || when.hour != hour) {
      return null;
    }
    return when;
  }
}

/// The saved recordings, newest first.
///
/// Domain logic only: it reaches the disk through [FileStore] and reads each
/// file's own WAV header through `WavReader`, so it is exercised in tests
/// against an in-memory store with no filesystem at all.
class LibraryService {
  /// Private initializing formals keep the public parameter names
  /// (`fileStore:`, `directory:`) while assigning the private fields, the same
  /// shape `RecordingService` uses.
  LibraryService({
    required this._fileStore,
    required this._directory,
  });

  final FileStore _fileStore;
  final String _directory;

  final StreamController<List<RecordingInfo>> _recordings =
      StreamController<List<RecordingInfo>>.broadcast();

  List<RecordingInfo> _current = const <RecordingInfo>[];

  /// Directory the recordings live in.
  String get directory => _directory;

  /// The list, re-published whenever it changes.
  Stream<List<RecordingInfo>> get recordings => _recordings.stream;

  /// The list as of the last [refresh]; empty before the first one.
  List<RecordingInfo> get current => List<RecordingInfo>.unmodifiable(_current);

  /// Re-reads the directory and publishes the result.
  ///
  /// A file that cannot be described - deleted mid-scan, or a header that will
  /// not parse - is still listed, with a `null` duration, rather than dropped:
  /// a recording that exists on disk must be visible so the user can delete it.
  Future<List<RecordingInfo>> refresh() async {
    final paths = await _fileStore.list(_directory);
    // The sidecars come out of the same listing, so knowing whether a
    // recording has a transcript costs no extra I/O at all.
    final present = paths.toSet();
    final found = <RecordingInfo>[];
    for (final path in paths) {
      if (path.endsWith(RecordingNaming.audioRemovedSuffix)) {
        // A note whose audio the retention sweep removed: listed from its
        // transcript, as long as it still has one and the WAV is really gone.
        final audio = RecordingNaming.audioPathOfSidecar(
          path,
          RecordingNaming.audioRemovedSuffix,
        );
        if (present.contains(audio)) continue;
        final transcript = RecordingNaming.transcriptPathOf(audio);
        if (!present.contains(transcript)) continue;
        final info = await _describeWithoutAudio(audio, transcript);
        if (info != null) found.add(info);
        continue;
      }
      if (!path.toLowerCase().endsWith(RecordingNaming.extension)) continue;
      final info = await describe(
        path,
        hasTranscript:
            present.contains(RecordingNaming.transcriptPathOf(path)),
        transcriptFailed:
            present.contains(RecordingNaming.transcriptFailurePathOf(path)),
        keepAudio: present.contains(RecordingNaming.keepAudioPathOf(path)),
      );
      if (info != null) found.add(info);
    }
    // Newest first.
    found.sort((a, b) => b.recordedAt.compareTo(a.recordedAt));
    _current = found;
    if (!_recordings.isClosed) {
      _recordings.add(List<RecordingInfo>.unmodifiable(found));
    }
    return current;
  }

  /// Describes the single file at [path], or `null` when it is gone.
  ///
  /// [hasTranscript] and [transcriptFailed] are passed in by [refresh], which
  /// already knows them from its directory listing.
  Future<RecordingInfo?> describe(
    String path, {
    bool hasTranscript = false,
    bool transcriptFailed = false,
    bool keepAudio = false,
  }) async {
    final stat = await _fileStore.stat(path);
    if (stat == null) return null;

    final name = _nameOf(path);
    final header = await _readHeader(path, stat.sizeBytes);

    return RecordingInfo(
      path: path,
      name: name,
      // The file name carries the capture time exactly; the modification time
      // is the fallback for files this app did not write.
      recordedAt: RecordingNaming.timestampOf(name) ?? stat.modifiedAt,
      sizeBytes: stat.sizeBytes,
      duration: _durationFrom(header, stat.sizeBytes),
      sampleRateHz: header?.sampleRateHz,
      channels: header?.channels,
      hasTranscript: hasTranscript,
      transcriptFailed: transcriptFailed,
      keepAudio: keepAudio,
    );
  }

  /// A recording whose WAV was removed, described from its transcript: the
  /// time from the name (or the transcript's modification time), the length
  /// the transcript recorded. Null when the transcript is gone or unreadable -
  /// there is then nothing to show.
  Future<RecordingInfo?> _describeWithoutAudio(
    String audioPath,
    String transcriptPath,
  ) async {
    try {
      final stat = await _fileStore.stat(transcriptPath);
      if (stat == null) return null;
      final transcript = Transcript.fromJson(
        jsonDecode(utf8.decode(await _fileStore.read(transcriptPath))),
      );
      if (transcript == null) return null;
      final name = _nameOf(audioPath);
      return RecordingInfo(
        path: audioPath,
        name: name,
        recordedAt: RecordingNaming.timestampOf(name) ?? stat.modifiedAt,
        sizeBytes: 0,
        duration: transcript.audioDuration,
        hasTranscript: true,
        hasAudio: false,
      );
    } on Object {
      return null;
    }
  }

  /// Deletes the recording at [path], its saved transcript with it, and
  /// re-publishes the list.
  ///
  /// The recording goes first: if the transcript cannot be removed after
  /// that, what is left is a stray sidecar nobody can see, never a recording
  /// that has lost its transcript but is still listed.
  Future<void> delete(String path) async {
    await deleteFiles(_fileStore, path);
    await refresh();
  }

  /// Deletes the recording at [path] and every file kept beside it, without
  /// re-listing. The order is load-bearing - see [delete].
  static Future<void> deleteFiles(FileStore fileStore, String path) async {
    await fileStore.delete(path);
    await fileStore.delete(RecordingNaming.transcriptPathOf(path));
    await fileStore.delete(RecordingNaming.transcriptFailurePathOf(path));
    await fileStore.delete(RecordingNaming.keepAudioPathOf(path));
    await fileStore.delete(RecordingNaming.speakerNamesPathOf(path));
    await fileStore.delete(RecordingNaming.speakerSettingsPathOf(path));
    // Last: for a note whose audio was already removed, this marker is what
    // lists it, so a delete interrupted before here leaves it visible and
    // deletable rather than a hidden stray.
    await fileStore.delete(RecordingNaming.audioRemovedPathOf(path));
    // After everything: while it is there, an interrupted empty-note deletion
    // is finished at the next start.
    await fileStore.delete(RecordingNaming.emptyNotePathOf(path));
  }

  Future<void> dispose() async {
    if (!_recordings.isClosed) await _recordings.close();
  }

  Future<WavHeader?> _readHeader(String path, int sizeBytes) async {
    if (sizeBytes <= 0) return null;
    try {
      final probe = await _fileStore.readRange(
        path,
        0,
        sizeBytes < WavReader.probeLength ? sizeBytes : WavReader.probeLength,
      );
      return WavReader.parse(probe);
    } on Object catch (_) {
      // Unreadable is indistinguishable from malformed as far as the list is
      // concerned, and neither may take the whole library down.
      return null;
    }
  }

  /// Length from the header's own fields, never from the file size.
  ///
  /// The one concession: when the file is shorter than the header claims -
  /// which is what a capture killed mid-write looks like - the bytes that are
  /// actually there are timed at the header's byte rate instead.
  Duration? _durationFrom(WavHeader? header, int sizeBytes) {
    if (header == null) return null;
    final available = sizeBytes - header.dataOffset;
    if (available <= 0) return Duration.zero;
    if (header.dataLength > available) return header.durationOf(available);
    return header.duration;
  }

  String _nameOf(String path) {
    final slash = path.lastIndexOf(RegExp(r'[/\\]'));
    return slash < 0 ? path : path.substring(slash + 1);
  }
}
