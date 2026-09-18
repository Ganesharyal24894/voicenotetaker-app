import 'dart:typed_data';

import 'package:voicenotetaker_app/drivers/file_store.dart';

/// An in-memory [FileStore] that can be WRITTEN to, which the library's own
/// fake cannot: the export is the first thing in the app that streams a file
/// out through [FileStore.openWrite] and patches it afterwards.
class MemoryFileStore implements FileStore {
  final Map<String, BytesBuilderFile> files = <String, BytesBuilderFile>{};

  /// Paths whose ranged reads throw, for the "a note vanished mid-export" case.
  final Set<String> unreadable = <String>{};

  /// Largest range any caller asked for, so a test can prove the export never
  /// pulled a whole recording into memory.
  int largestReadRange = 0;

  void put(String path, List<int> bytes, {DateTime? at}) {
    files[path] = BytesBuilderFile(
      Uint8List.fromList(bytes),
      at ?? DateTime(2026, 1, 1),
    );
  }

  Uint8List bytesOf(String path) => files[path]!.bytes;

  @override
  Future<FileSink> openWrite(String path) async {
    final file = BytesBuilderFile(Uint8List(0), DateTime(2026, 1, 1));
    files[path] = file;
    return _MemorySink(file);
  }

  @override
  Future<FileSink> openAppend(String path) async =>
      _MemorySink(files.putIfAbsent(
        path,
        () => BytesBuilderFile(Uint8List(0), DateTime(2026, 1, 1)),
      ));

  @override
  Future<void> move(String from, String to) async {
    files[to] = files.remove(from)!;
  }

  @override
  Future<Uint8List> read(String path) async {
    if (unreadable.contains(path)) throw StateError('unreadable: $path');
    final file = files[path];
    if (file == null) throw StateError('no such file: $path');
    return file.bytes;
  }

  @override
  Future<Uint8List> readRange(String path, int start, int end) async {
    if (end - start > largestReadRange) largestReadRange = end - start;
    final bytes = await read(path);
    final from = start.clamp(0, bytes.length);
    final to = end.clamp(from, bytes.length);
    return Uint8List.sublistView(bytes, from, to);
  }

  @override
  Future<FileInfo?> stat(String path) async {
    final file = files[path];
    if (file == null) return null;
    return FileInfo(
      path: path,
      sizeBytes: file.bytes.length,
      modifiedAt: file.modifiedAt,
    );
  }

  @override
  Future<void> writeBytes(String path, List<int> bytes) async =>
      put(path, bytes);

  @override
  Future<void> patchBytes(String path, int offset, List<int> bytes) async =>
      files[path]!.patch(offset, bytes);

  @override
  Future<bool> exists(String path) async => files.containsKey(path);

  @override
  Future<void> delete(String path) async => files.remove(path);

  @override
  Future<List<String>> list(String directory) async =>
      files.keys.where((p) => p.startsWith('$directory/')).toList()..sort();

  @override
  String join(String directory, String name) => '$directory/$name';
}

/// One file's bytes, growable and patchable in place.
class BytesBuilderFile {
  BytesBuilderFile(this._bytes, this.modifiedAt);

  Uint8List _bytes;
  DateTime modifiedAt;

  Uint8List get bytes => _bytes;

  void append(List<int> more) {
    final grown = Uint8List(_bytes.length + more.length)
      ..setRange(0, _bytes.length, _bytes)
      ..setRange(_bytes.length, _bytes.length + more.length, more);
    _bytes = grown;
  }

  void patch(int offset, List<int> bytes) =>
      _bytes.setRange(offset, offset + bytes.length, bytes);
}

class _MemorySink implements FileSink {
  _MemorySink(this._file);

  final BytesBuilderFile _file;
  bool closed = false;

  @override
  int get bytesWritten => _file.bytes.length;

  @override
  Future<void> add(List<int> bytes) async => _file.append(bytes);

  @override
  Future<void> patch(int offset, List<int> bytes) async =>
      _file.patch(offset, bytes);

  @override
  Future<void> close() async => closed = true;
}

/// A member read back out of a finished archive.
class ZipMember {
  const ZipMember({
    required this.name,
    required this.bytes,
    required this.crc,
  });

  final String name;
  final Uint8List bytes;
  final int crc;
}

/// Reads an archive back the way an unzip does: from the end-of-central-
/// directory record, through the central directory, to each local header.
///
/// A round trip through a reader that does NOT share code with the writer is
/// the only honest test of a file format - a writer checked against its own
/// assumptions passes whatever it does.
List<ZipMember> readZip(Uint8List archive) {
  final view = ByteData.sublistView(archive);
  var end = archive.length - 22;
  while (end >= 0 && view.getUint32(end, Endian.little) != 0x06054b50) {
    end--;
  }
  if (end < 0) throw StateError('no end-of-central-directory record');

  final count = view.getUint16(end + 10, Endian.little);
  var offset = view.getUint32(end + 16, Endian.little);

  final members = <ZipMember>[];
  for (var i = 0; i < count; i++) {
    if (view.getUint32(offset, Endian.little) != 0x02014b50) {
      throw StateError('bad central header at $offset');
    }
    final crc = view.getUint32(offset + 16, Endian.little);
    final compressed = view.getUint32(offset + 20, Endian.little);
    final uncompressed = view.getUint32(offset + 24, Endian.little);
    final nameLength = view.getUint16(offset + 28, Endian.little);
    final extraLength = view.getUint16(offset + 30, Endian.little);
    final commentLength = view.getUint16(offset + 32, Endian.little);
    final localOffset = view.getUint32(offset + 42, Endian.little);
    final name = String.fromCharCodes(
      archive.sublist(offset + 46, offset + 46 + nameLength),
    );

    if (compressed != uncompressed) {
      throw StateError('$name is not stored');
    }
    if (view.getUint32(localOffset, Endian.little) != 0x04034b50) {
      throw StateError('bad local header for $name');
    }
    if (view.getUint32(localOffset + 14, Endian.little) != crc) {
      throw StateError('$name: local and central CRCs disagree');
    }
    final localNameLength = view.getUint16(localOffset + 26, Endian.little);
    final localExtraLength = view.getUint16(localOffset + 28, Endian.little);
    final dataAt = localOffset + 30 + localNameLength + localExtraLength;

    members.add(ZipMember(
      name: name,
      bytes: Uint8List.sublistView(archive, dataAt, dataAt + uncompressed),
      crc: crc,
    ));
    offset += 46 + nameLength + extraLength + commentLength;
  }
  return members;
}
