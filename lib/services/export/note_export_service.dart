import 'dart:async';

import '../../drivers/disk_space.dart';
import '../../drivers/file_store.dart';
import 'note_export_plan.dart';
import 'zip_writer.dart';

/// Why an export did not happen. Each one has a sentence the user can act on;
/// the view holds the words, this holds the reason.
enum ExportFailure {
  /// Nothing in the chosen range.
  nothingToExport,

  /// More than a plain zip can address. The answer is a shorter range.
  tooLarge,

  /// The phone does not have room for the zip beside the notes.
  noRoom,

  /// The user left the screen, or asked to stop.
  cancelled,

  /// The write itself failed.
  failed,
}

/// The outcome of one export: a file, or a reason there is not one.
class ExportResult {
  const ExportResult.written({
    required this.path,
    required this.sizeBytes,
    required this.noteCount,
    this.unreadableFiles = 0,
  })  : failure = null,
        freeBytes = null;

  const ExportResult.refused(this.failure, {this.freeBytes})
      : path = null,
        sizeBytes = 0,
        noteCount = 0,
        unreadableFiles = 0;

  final String? path;
  final int sizeBytes;
  final int noteCount;
  final ExportFailure? failure;

  /// Files whose bytes could not all be read, so their place in the zip is
  /// partly silence. The zip is still a valid zip - see
  /// [ZipWriter.incompleteMembers] for why this has to be said out loud.
  final int unreadableFiles;

  /// For [ExportFailure.noRoom]: what the phone said it had left, so the view
  /// can say how short it is rather than "not enough space".
  final int? freeBytes;

  bool get ok => path != null;
}

/// Writes the user's notes into one zip they can hand to anything.
///
/// THE FALLBACK, NOT THE MAIN ROAD. Pulling the notes over a cable
/// (`tool/pull_iphone_notes.sh`) copies faster, needs no second copy on the
/// phone and has no size limit. This exists for when there is no cable: a zip
/// through the share sheet goes to AirDrop, to Files, to a message, to
/// whatever the phone can reach.
///
/// It streams. At no point does the service hold more than one 512 KB chunk of
/// audio, whatever the export weighs - see [ZipWriter].
class NoteExportService {
  NoteExportService({
    required FileStore fileStore,
    required String recordingsDirectory,
    required String exportsDirectory,
    DiskSpace diskSpace = const FixedDiskSpace(),
    // Plain fields behind public names; an initializing formal cannot be used
    // because the fields are private and the parameters are part of the API.
    // ignore: prefer_initializing_formals
  })  : _fileStore = fileStore,
        _recordings = recordingsDirectory,
        _exports = exportsDirectory,
        // ignore: prefer_initializing_formals
        _diskSpace = diskSpace;

  final FileStore _fileStore;
  final String _recordings;
  final String _exports;
  final DiskSpace _diskSpace;

  /// Room wanted beyond the zip itself before one is started, so an export
  /// does not fill the phone to the last byte and leave the next recording
  /// nowhere to go.
  static const int headroomBytes = 64 * 1024 * 1024;

  /// What an export of [range] would contain. Reads the directory; writes
  /// nothing.
  Future<ExportPlan> plan(ExportRange range, {DateTime? now}) async {
    final paths = await _fileStore.list(_recordings);
    final files = <FileInfo>[];
    for (final path in paths) {
      final stat = await _fileStore.stat(path);
      if (stat != null) files.add(stat);
    }
    return planExport(
      directoryFiles: files,
      range: range,
      now: now ?? DateTime.now(),
    );
  }

  /// Writes [plan] into the exports directory and answers where it landed.
  ///
  /// [onProgress] is called with bytes written and the total the plan says
  /// there will be, so the bar is determinate from the first frame.
  ///
  /// [isCancelled] is asked between chunks, so Stop takes effect inside a
  /// large recording rather than after it. A cancelled export deletes its own
  /// half-written file: a 2 GB partial zip left in the app's storage is
  /// exactly the sort of thing nobody finds until the phone is full.
  Future<ExportResult> write(
    ExportPlan plan, {
    void Function(int written, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (plan.isEmpty) {
      return const ExportResult.refused(ExportFailure.nothingToExport);
    }
    if (plan.tooLarge) {
      return const ExportResult.refused(ExportFailure.tooLarge);
    }

    // Last export first: it has already been shared or abandoned, and keeping
    // two copies of the library on a phone is not a kindness.
    await _clearPreviousExports();

    final free = await _diskSpace.freeBytesFor(_exports);
    if (free != null && free < plan.zipBytes + headroomBytes) {
      return ExportResult.refused(ExportFailure.noRoom, freeBytes: free);
    }

    final destination = _fileStore.join(_exports, plan.zipName);
    ZipWriter? writer;
    int unreadable;
    int written;
    try {
      writer = await ZipWriter.create(
        fileStore: _fileStore,
        path: destination,
      );
      final archive = writer;
      for (final file in plan.files) {
        if (isCancelled?.call() ?? false) throw const ZipCancelledException();
        await archive.addFile(
          name: file.nameInZip,
          sourcePath: file.sourcePath,
          fileStore: _fileStore,
          sizeBytes: file.sizeBytes,
          modifiedAt: file.modifiedAt,
          // The archive's own length, not a running sum of the payloads: the
          // headers are bytes on disk too, and a bar that leaves them out
          // finishes a little before the file does.
          onProgress: (_) => onProgress?.call(archive.bytesWritten, plan.zipBytes),
          isCancelled: isCancelled,
        );
        onProgress?.call(archive.bytesWritten, plan.zipBytes);
      }
      await writer.close();
      onProgress?.call(plan.zipBytes, plan.zipBytes);
      unreadable = writer.incompleteMembers;
      // Read INSIDE the try: `stat` goes to the filesystem and can throw like
      // anything else, and a throw out of here would leave the caller's screen
      // stuck on "writing" with no result to show.
      written = (await _fileStore.stat(destination))?.sizeBytes ?? plan.zipBytes;
    } on ZipCancelledException {
      await _cleanUp(writer, destination);
      return const ExportResult.refused(ExportFailure.cancelled);
    } on Object {
      // Anything at all: a read that failed, a disk that filled under us, a
      // note deleted mid-export. The partial file goes, and the caller is
      // told the export did not happen rather than handed half of one.
      await _cleanUp(writer, destination);
      return const ExportResult.refused(ExportFailure.failed);
    }

    return ExportResult.written(
      path: destination,
      sizeBytes: written,
      noteCount: plan.noteCount,
      unreadableFiles: unreadable,
    );
  }

  /// Throws the half-written archive away. Neither step may throw: this runs
  /// from a catch arm, and an exception here would replace the reason the
  /// export failed with a second, less useful one.
  Future<void> _cleanUp(ZipWriter? writer, String destination) async {
    try {
      await writer?.abort();
    } on Object {
      // The file is being deleted next; a sink that would not close cleanly
      // changes nothing.
    }
    try {
      await _fileStore.delete(destination);
    } on Object {
      // Nothing further to do about it, and the caller is about to be told the
      // export did not happen either way.
    }
  }

  /// Removes any zip left in the exports directory.
  ///
  /// Called before an export, and worth calling after the share sheet closes:
  /// the zip is a copy, and the notes it was made from have not moved.
  Future<void> clearExports() => _clearPreviousExports();

  Future<void> _clearPreviousExports() async {
    try {
      for (final path in await _fileStore.list(_exports)) {
        if (path.toLowerCase().endsWith('.zip')) {
          await _fileStore.delete(path);
        }
      }
    } on Object {
      // A directory that is not there yet is the ordinary first-run case, and
      // a file we cannot remove is not a reason to refuse the export.
    }
  }
}
