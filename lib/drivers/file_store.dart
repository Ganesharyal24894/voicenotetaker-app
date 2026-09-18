import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// A file being written incrementally.
///
/// [patch] exists because a WAV header cannot be finalised until the payload
/// length is known: the writer emits a provisional 44-byte header, streams the
/// audio, then patches the two length fields on close.
abstract class FileSink {
  /// Bytes appended so far, header included.
  int get bytesWritten;

  Future<void> add(List<int> bytes);

  /// Overwrites [bytes] at absolute [offset]. Does not move the append cursor.
  Future<void> patch(int offset, List<int> bytes);

  Future<void> close();
}

/// Size and modification time of one file.
///
/// A plain data holder rather than `dart:io`'s `FileStat`, so that `services/`
/// can ask how big a recording is without importing `dart:io`.
class FileInfo {
  const FileInfo({
    required this.path,
    required this.sizeBytes,
    required this.modifiedAt,
  });

  final String path;
  final int sizeBytes;
  final DateTime modifiedAt;

  @override
  String toString() => 'FileInfo($path, $sizeBytes B, $modifiedAt)';
}

/// All filesystem access the app performs.
///
/// Abstract so that `services/` never imports `dart:io`, which keeps the domain
/// logic testable in-memory and portable to platforms where `dart:io` is not
/// available.
abstract class FileStore {
  /// Opens [path] for writing, truncating any existing file.
  Future<FileSink> openWrite(String path);

  /// Opens [path] for APPENDING: creates it and its parents when absent, and
  /// never truncates what is already there.
  ///
  /// This is what makes a model download resumable. [openWrite] cannot do it -
  /// it truncates on open, which would throw away the 180 MB that had already
  /// arrived.
  Future<FileSink> openAppend(String path);

  /// Renames [from] to [to], replacing anything at [to].
  ///
  /// Within one directory this is atomic, which is what turns a verified
  /// `.part` file into an installed model in one step: there is no instant at
  /// which a half file sits under the name the engine loads.
  Future<void> move(String from, String to);

  Future<Uint8List> read(String path);

  /// Reads bytes `[start, end)` of [path], clamped to the end of the file.
  ///
  /// The library reads the 44-byte WAV header of every recording; without this
  /// it would have to pull whole multi-megabyte files into memory to look at
  /// their first few bytes.
  Future<Uint8List> readRange(String path, int start, int end);

  /// Size and modification time of [path], or `null` when it does not exist.
  Future<FileInfo?> stat(String path);

  Future<void> writeBytes(String path, List<int> bytes);

  /// Overwrites [bytes] at [offset] in the EXISTING file at [path], without
  /// truncating it or reading it into memory.
  ///
  /// For repairing the length fields of a WAV header left behind by a capture
  /// the app was killed in the middle of - a file that can be a hundred
  /// megabytes long.
  Future<void> patchBytes(String path, int offset, List<int> bytes);

  Future<bool> exists(String path);

  Future<void> delete(String path);

  /// Absolute paths of the regular files directly inside [directory].
  Future<List<String>> list(String directory);

  /// Joins [directory] and [name] using the store's separator.
  String join(String directory, String name);
}

/// `dart:io` implementation, used on every platform the app currently targets.
class IoFileStore implements FileStore {
  const IoFileStore();

  @override
  Future<FileSink> openWrite(String path) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final handle = await file.open(mode: FileMode.write);
    return _IoFileSink(handle);
  }

  @override
  Future<FileSink> openAppend(String path) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    // `append` opens read-write without truncating and creates the file when
    // it is absent.
    final handle = await file.open(mode: FileMode.append);
    return _IoFileSink(handle, bytesAlready: await handle.length());
  }

  @override
  Future<void> move(String from, String to) async {
    final source = File(from);
    await File(to).parent.create(recursive: true);
    try {
      await source.rename(to);
    } on FileSystemException {
      // Across filesystems `rename` cannot work; copy and remove instead. The
      // models directory and its `.part` files are always the same volume, so
      // this is a safety net rather than a path the app takes.
      await source.copy(to);
      await source.delete();
    }
  }

  @override
  Future<Uint8List> read(String path) => File(path).readAsBytes();

  @override
  Future<Uint8List> readRange(String path, int start, int end) async {
    if (start < 0) {
      throw ArgumentError.value(start, 'start', 'must be >= 0');
    }
    if (end < start) {
      throw ArgumentError.value(end, 'end', 'must be >= start');
    }
    if (end == start) return Uint8List(0);
    final handle = await File(path).open();
    try {
      await handle.setPosition(start);
      return await handle.read(end - start);
    } finally {
      await handle.close();
    }
  }

  @override
  Future<FileInfo?> stat(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;
    final stat = await file.stat();
    return FileInfo(
      path: path,
      sizeBytes: stat.size,
      modifiedAt: stat.modified,
    );
  }

  @override
  Future<void> writeBytes(String path, List<int> bytes) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  @override
  Future<void> patchBytes(String path, int offset, List<int> bytes) async {
    if (offset < 0) {
      throw ArgumentError.value(offset, 'offset', 'must be >= 0');
    }
    // `append` opens read-write WITHOUT truncating; unlike O_APPEND, Dart still
    // honours `setPosition` for the write.
    final handle = await File(path).open(mode: FileMode.append);
    try {
      await handle.setPosition(offset);
      await handle.writeFrom(bytes);
      await handle.flush();
    } finally {
      await handle.close();
    }
  }

  @override
  Future<bool> exists(String path) => File(path).exists();

  @override
  Future<void> delete(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<List<String>> list(String directory) async {
    final dir = Directory(directory);
    if (!await dir.exists()) return const [];
    final entries = await dir.list(followLinks: false).toList();
    return entries.whereType<File>().map((f) => f.path).toList()..sort();
  }

  @override
  String join(String directory, String name) {
    if (directory.isEmpty) return name;
    final sep = Platform.pathSeparator;
    return directory.endsWith(sep)
        ? '$directory$name'
        : '$directory$sep$name';
  }
}

class _IoFileSink implements FileSink {
  _IoFileSink(this._handle, {int bytesAlready = 0})
      : _bytesWritten = bytesAlready;

  final RandomAccessFile _handle;

  /// Serialises writes: `RandomAccessFile` allows only one pending operation.
  Future<void> _queue = Future.value();

  int _bytesWritten;
  bool _closed = false;

  @override
  int get bytesWritten => _bytesWritten;

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  @override
  Future<void> add(List<int> bytes) {
    if (_closed) {
      throw StateError('cannot add to a closed FileSink');
    }
    _bytesWritten += bytes.length;
    return _enqueue(() async {
      await _handle.setPosition(await _handle.length());
      await _handle.writeFrom(bytes);
    });
  }

  @override
  Future<void> patch(int offset, List<int> bytes) {
    if (_closed) {
      throw StateError('cannot patch a closed FileSink');
    }
    return _enqueue(() async {
      await _handle.setPosition(offset);
      await _handle.writeFrom(bytes);
    });
  }

  @override
  Future<void> close() {
    if (_closed) return _queue;
    _closed = true;
    return _enqueue(() async {
      await _handle.flush();
      await _handle.close();
    });
  }
}
