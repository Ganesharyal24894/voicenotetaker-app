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

/// All filesystem access the app performs.
///
/// Abstract so that `services/` never imports `dart:io`, which keeps the domain
/// logic testable in-memory and portable to platforms where `dart:io` is not
/// available.
abstract class FileStore {
  /// Opens [path] for writing, truncating any existing file.
  Future<FileSink> openWrite(String path);

  Future<Uint8List> read(String path);

  Future<void> writeBytes(String path, List<int> bytes);

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
  Future<Uint8List> read(String path) => File(path).readAsBytes();

  @override
  Future<void> writeBytes(String path, List<int> bytes) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
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
  _IoFileSink(this._handle);

  final RandomAccessFile _handle;

  /// Serialises writes: `RandomAccessFile` allows only one pending operation.
  Future<void> _queue = Future.value();

  int _bytesWritten = 0;
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
