import '../../drivers/file_store.dart';
import '../library_service.dart';
import 'zip_writer.dart';

/// How much of the library one export covers.
///
/// Three, and only three. A date-range picker is a screen of its own for a
/// thing the user does when they are already annoyed that their notes are on
/// the wrong device; "today", "the last week" and "all of it" is what anyone
/// actually reaches for.
enum ExportRange {
  today,
  lastSevenDays,
  everything;

  /// Plain words for a button. No date arithmetic in the view layer.
  String get label => switch (this) {
        ExportRange.today => 'Today',
        ExportRange.lastSevenDays => 'Last 7 days',
        ExportRange.everything => 'Everything',
      };
}

/// One file the export will store, and the name it will have inside the zip.
class ExportFile {
  const ExportFile({
    required this.sourcePath,
    required this.nameInZip,
    required this.sizeBytes,
    required this.modifiedAt,
  });

  final String sourcePath;

  /// Path inside the archive, `/` separated. Always under `recordings/`, so
  /// unzipping gives the same shape the phone has and the same shape
  /// `tool/pull_iphone_notes.sh` copies.
  final String nameInZip;

  final int sizeBytes;
  final DateTime modifiedAt;

  @override
  String toString() => 'ExportFile($nameInZip, $sizeBytes B)';
}

/// Everything decided before a single byte is written.
///
/// Pure data produced by [planExport], which is why what an export contains,
/// what it is called and what it will weigh can all be tested without a
/// filesystem, a phone or a zip.
class ExportPlan {
  const ExportPlan({
    required this.range,
    required this.zipName,
    required this.files,
    required this.noteCount,
    required this.audioBytes,
    required this.zipBytes,
    required this.tooLarge,
  });

  final ExportRange range;

  /// File name to offer to the share sheet, extension included.
  final String zipName;

  /// Members, in the order they will be stored: oldest note first, and within
  /// a note its recording before its sidecars, so a half-written archive is
  /// still a run of whole notes from the beginning of the range.
  final List<ExportFile> files;

  /// Recordings covered - notes, not files. A note is one `.wav` plus however
  /// many sidecars it has collected.
  final int noteCount;

  /// Bytes of the files themselves, headers excluded.
  final int audioBytes;

  /// Bytes the finished zip will weigh, exactly. Nothing is compressed, so
  /// this is arithmetic rather than a guess - see [ZipWriter.sizeOf].
  final int zipBytes;

  /// Whether [zipBytes] is past what a plain zip can address, in which case
  /// nothing should be written and the user should be offered a shorter
  /// range.
  final bool tooLarge;

  bool get isEmpty => files.isEmpty;

  @override
  String toString() =>
      'ExportPlan($zipName, $noteCount notes, ${files.length} files, '
      '$zipBytes B${tooLarge ? ', too large' : ''})';
}

/// Works out what an export of [range] would contain, given every file
/// [directoryFiles] in the recordings directory and the current time [now].
///
/// A note's date comes from its file name, which is where the capture time is
/// recorded; a file whose name does not parse falls back to its modification
/// time rather than being dropped, because a note nobody can date is still the
/// user's note. Sidecars are dated by the RECORDING they belong to, never by
/// their own name or mtime: renaming a speaker months later must not move that
/// note into today's export or out of last week's.
///
/// Files that do not belong to any note in the directory - something dropped
/// in by hand, a stray sidecar whose recording was deleted - come along only
/// when [range] is [ExportRange.everything]. Nothing the user owns is silently
/// left behind by "all of it".
ExportPlan planExport({
  required List<FileInfo> directoryFiles,
  required ExportRange range,
  required DateTime now,
}) {
  final from = _startOf(range, now);

  // Group by the note each file belongs to. The stem of a recording and of
  // every sidecar beside it are the same string, which is the whole point of
  // the sidecar convention - see `RecordingNaming`.
  final byNote = <String, List<FileInfo>>{};
  for (final file in directoryFiles) {
    byNote.putIfAbsent(_stemOf(_baseName(file.path)), () => <FileInfo>[])
        .add(file);
  }

  final chosen = <_DatedNote>[];
  for (final entry in byNote.entries) {
    final files = entry.value;
    final audio = files.where((f) => _isRecording(f.path)).firstOrNull;
    final DateTime when;
    if (audio != null) {
      when = RecordingNaming.timestampOf(_baseName(audio.path)) ??
          audio.modifiedAt;
    } else if (range != ExportRange.everything) {
      // A note with no recording left: its transcript may still be here after
      // the retention sweep, and the sweep does not rewrite the name, so the
      // stem still carries the date.
      final dated = RecordingNaming.timestampOf('${entry.key}.wav');
      if (dated == null) continue;
      when = dated;
    } else {
      when = RecordingNaming.timestampOf('${entry.key}.wav') ??
          files.first.modifiedAt;
    }
    if (from != null && when.isBefore(from)) continue;
    chosen.add(_DatedNote(when: when, audio: audio, files: files));
  }

  chosen.sort((a, b) {
    final byDate = a.when.compareTo(b.when);
    return byDate != 0 ? byDate : a.files.first.path.compareTo(b.files.first.path);
  });

  final members = <ExportFile>[];
  var audioBytes = 0;
  var noteCount = 0;
  for (final note in chosen) {
    if (note.audio != null) noteCount++;
    final sidecars = note.files.where((f) => f != note.audio).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    final ordered = <FileInfo>[
      if (note.audio != null) note.audio!,
      ...sidecars,
    ];
    for (final file in ordered) {
      members.add(ExportFile(
        sourcePath: file.path,
        nameInZip: 'recordings/${_baseName(file.path)}',
        sizeBytes: file.sizeBytes,
        modifiedAt: file.modifiedAt,
      ));
      audioBytes += file.sizeBytes;
    }
  }

  final zipBytes = ZipWriter.sizeOf(
    names: members.map((m) => m.nameInZip).toList(),
    sizes: members.map((m) => m.sizeBytes).toList(),
  );

  return ExportPlan(
    range: range,
    zipName: exportFileName(range: range, now: now),
    files: members,
    noteCount: noteCount,
    audioBytes: audioBytes,
    zipBytes: zipBytes,
    tooLarge: zipBytes > ZipWriter.maxArchiveBytes ||
        members.length > ZipWriter.maxEntries,
  );
}

/// What the zip is called. It says what is in it and when it was made, so two
/// exports in a folder are told apart without opening either.
///
///   voicenotetaker-20260918.zip
///   voicenotetaker-20260912-to-20260918.zip
///   voicenotetaker-all-20260918.zip
String exportFileName({required ExportRange range, required DateTime now}) {
  final today = _day(now);
  return switch (range) {
    ExportRange.today => 'voicenotetaker-$today.zip',
    ExportRange.lastSevenDays =>
      'voicenotetaker-${_day(_sevenDaysBack(now))}-to-$today.zip',
    ExportRange.everything => 'voicenotetaker-all-$today.zip',
  };
}

/// Start of [range] relative to [now], or `null` for no lower bound.
///
/// Midnight LOCAL, not `now` minus a duration: someone exporting "today" at
/// 00:10 means the notes with today's date on them, and someone exporting
/// "last 7 days" means seven whole days, the current one included.
DateTime? _startOf(ExportRange range, DateTime now) => switch (range) {
      ExportRange.today => DateTime(now.year, now.month, now.day),
      ExportRange.lastSevenDays => _sevenDaysBack(now),
      ExportRange.everything => null,
    };

/// Midnight at the start of the seventh day back, counting today as the first.
///
/// Built by arithmetic on the DAY NUMBER rather than by subtracting 144 hours:
/// `DateTime` normalises a day out of range, and a clock that moved for
/// daylight saving in between would otherwise land this an hour either side of
/// midnight and drop or add a note at the edge.
DateTime _sevenDaysBack(DateTime now) =>
    DateTime(now.year, now.month, now.day - 6);

String _day(DateTime when) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${when.year}${two(when.month)}${two(when.day)}';
}

String _baseName(String path) {
  final slash = path.lastIndexOf(RegExp(r'[/\\]'));
  return slash < 0 ? path : path.substring(slash + 1);
}

/// The part of a file name shared by a recording and all of its sidecars: the
/// name up to the first dot after the `voicenote-...` stamp.
String _stemOf(String name) {
  final dot = name.indexOf('.');
  return dot < 0 ? name : name.substring(0, dot);
}

bool _isRecording(String path) =>
    path.toLowerCase().endsWith(RecordingNaming.extension);

class _DatedNote {
  const _DatedNote({
    required this.when,
    required this.audio,
    required this.files,
  });

  final DateTime when;
  final FileInfo? audio;
  final List<FileInfo> files;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
