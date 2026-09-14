import 'dart:async';

import '../drivers/file_store.dart';
import '../model/recording_info.dart';
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
  static String transcriptFailurePathOf(String audioPath) {
    final lower = audioPath.toLowerCase();
    final stem = lower.endsWith(extension)
        ? audioPath.substring(0, audioPath.length - extension.length)
        : audioPath;
    return '$stem$transcriptFailureSuffix';
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
      if (!path.toLowerCase().endsWith(RecordingNaming.extension)) continue;
      final info = await describe(
        path,
        hasTranscript:
            present.contains(RecordingNaming.transcriptPathOf(path)),
        transcriptFailed:
            present.contains(RecordingNaming.transcriptFailurePathOf(path)),
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
    );
  }

  /// Deletes the recording at [path], its saved transcript with it, and
  /// re-publishes the list.
  ///
  /// The recording goes first: if the transcript cannot be removed after
  /// that, what is left is a stray sidecar nobody can see, never a recording
  /// that has lost its transcript but is still listed.
  Future<void> delete(String path) async {
    await _fileStore.delete(path);
    await _fileStore.delete(RecordingNaming.transcriptPathOf(path));
    await _fileStore.delete(RecordingNaming.transcriptFailurePathOf(path));
    await refresh();
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
