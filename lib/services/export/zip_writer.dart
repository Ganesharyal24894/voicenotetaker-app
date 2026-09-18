import 'dart:convert';
import 'dart:typed_data';

import '../../drivers/file_store.dart';

/// Writes a ZIP archive one file at a time, without holding it in memory.
///
/// WHY THIS IS HERE AND NOT A PACKAGE. The one thing an export of voice notes
/// must do is not need as much RAM as the notes weigh, and the obvious
/// packages all want either the whole archive or the whole member as a byte
/// list first. A phone asked to export a day of continuous capture would be
/// holding hundreds of megabytes to produce a file that is barely smaller.
///
/// WHY NOTHING IS COMPRESSED. Every byte in here is either 16-bit PCM audio or
/// a JSON transcript. PCM does not deflate (a few per cent at a cost of
/// minutes of phone CPU) and the transcripts are a rounding error beside it.
/// Storing means the output size is known EXACTLY before the first byte is
/// written - see [ZipWriter.sizeOf] - which is what lets the export show a
/// real progress bar and check there is room before it starts, instead of
/// guessing and failing half way.
///
/// The format written is the plain one from PKWARE's APPNOTE: local header,
/// stored data, central directory, end-of-central-directory. No zip64 and no
/// data descriptors, so the result opens in Finder, Windows Explorer, the iOS
/// Files app and `unzip` with nothing installed.
class ZipWriter {
  ZipWriter._(this._sink);

  final FileSink _sink;
  final List<_ZipEntry> _entries = <_ZipEntry>[];
  bool _closed = false;

  /// A member whose header was written but whose data never finished.
  ///
  /// Once that has happened the file holds a local header the central
  /// directory will not mention, which is an archive some tools read and
  /// others reject. [close] refuses rather than producing one; [abort] is the
  /// only way out.
  bool _poisoned = false;

  int _incompleteMembers = 0;

  /// Fields in the ZIP header that hold a size or an offset are 32 bits, and
  /// this writer emits no zip64 records, so an archive may not cross 4 GiB.
  /// A caller that could exceed it is expected to ask [sizeOf] first and
  /// offer a smaller selection - which reads far better than a zip that only
  /// some tools can open.
  static const int maxArchiveBytes = 0xFFFFFFFF;

  /// How many members the end-of-central-directory record can count.
  ///
  /// 0xFFFE rather than 0xFFFF: 0xFFFF in that field is the ZIP64 sentinel,
  /// and a reader that sees it goes looking for a ZIP64 locator this writer
  /// never emits. One member short of the limit is a limit nobody will reach
  /// and every unzip understands.
  static const int maxEntries = 0xFFFE;

  static const int _localHeaderBytes = 30;
  static const int _centralHeaderBytes = 46;
  static const int _endOfCentralDirectoryBytes = 22;

  /// Bytes the archive will weigh once [names] are stored in it, each of
  /// [sizes] bytes. Pure, and exact - not an estimate.
  ///
  /// Order does not matter, only the names and the sizes, because a stored
  /// member costs its own bytes plus two headers that name it.
  static int sizeOf({required List<String> names, required List<int> sizes}) {
    if (names.length != sizes.length) {
      throw ArgumentError('names and sizes must be the same length');
    }
    var total = _endOfCentralDirectoryBytes;
    for (var i = 0; i < names.length; i++) {
      if (sizes[i] < 0) {
        throw ArgumentError.value(sizes[i], 'sizes[$i]', 'must be >= 0');
      }
      final nameBytes = utf8.encode(names[i]).length;
      total += _localHeaderBytes + nameBytes + sizes[i];
      total += _centralHeaderBytes + nameBytes;
    }
    return total;
  }

  /// Opens [path] for writing, replacing anything there.
  static Future<ZipWriter> create({
    required FileStore fileStore,
    required String path,
  }) async =>
      ZipWriter._(await fileStore.openWrite(path));

  /// Bytes written so far, headers included.
  int get bytesWritten => _sink.bytesWritten;

  /// Members added so far.
  int get entryCount => _entries.length;

  /// Stores [bytes] in the archive as [name].
  Future<void> addBytes({
    required String name,
    required List<int> bytes,
    required DateTime modifiedAt,
  }) async {
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final offset = await _writeLocalHeader(
      name: name,
      sizeBytes: data.length,
      modifiedAt: modifiedAt,
    );
    await _sink.add(data);
    await _finish(
      name: name,
      sizeBytes: data.length,
      modifiedAt: modifiedAt,
      crc: Crc32.of(data),
      localHeaderOffset: offset,
    );
  }

  /// Stores the file at [sourcePath] in the archive as [name], reading it in
  /// [chunkBytes] pieces so a 400 MB recording never exists in memory.
  ///
  /// [onProgress] is called with the bytes of THIS member copied so far, after
  /// each chunk, which is what the export screen's bar follows.
  ///
  /// [isCancelled] is asked between chunks and throws [ZipCancelledException]
  /// when it answers true. Asked per CHUNK rather than per member because a
  /// single recording can be hundreds of megabytes, and a Stop button that
  /// does nothing until the current file finishes is a Stop button that looks
  /// broken.
  ///
  /// The size is taken once, before the copy, and the copy is clipped to it:
  /// a file still growing (a capture that is running) contributes the length
  /// it had when the export started, and the header stays true to the bytes
  /// that follow it. A file that has SHRUNK or gone away since - the retention
  /// sweep is allowed to do that at any moment - would leave a short member,
  /// so the shortfall is padded with zeros rather than written as a lie.
  Future<void> addFile({
    required String name,
    required String sourcePath,
    required FileStore fileStore,
    required int sizeBytes,
    required DateTime modifiedAt,
    void Function(int bytesCopied)? onProgress,
    bool Function()? isCancelled,
    int chunkBytes = 512 * 1024,
  }) async {
    if (chunkBytes <= 0) {
      throw ArgumentError.value(chunkBytes, 'chunkBytes', 'must be > 0');
    }
    final offset = await _writeLocalHeader(
      name: name,
      sizeBytes: sizeBytes,
      modifiedAt: modifiedAt,
    );

    final crc = Crc32();
    var copied = 0;
    var padded = 0;
    _poisoned = true;
    while (copied < sizeBytes) {
      if (isCancelled?.call() ?? false) {
        throw const ZipCancelledException();
      }
      final end = (copied + chunkBytes) > sizeBytes ? sizeBytes : copied + chunkBytes;
      Uint8List chunk;
      try {
        chunk = await fileStore.readRange(sourcePath, copied, end);
      } on Object {
        chunk = Uint8List(0);
      }
      if (chunk.isEmpty) {
        // Nothing left to read but the header promised more. Pad, so the
        // archive stays structurally sound and the member is obviously short
        // rather than silently corrupt.
        final padding = Uint8List(end - copied);
        crc.add(padding);
        await _sink.add(padding);
        padded += padding.length;
        copied = end;
        onProgress?.call(copied);
        continue;
      }
      crc.add(chunk);
      await _sink.add(chunk);
      copied += chunk.length;
      onProgress?.call(copied);
    }

    if (padded > 0) _incompleteMembers++;
    await _finish(
      name: name,
      sizeBytes: sizeBytes,
      modifiedAt: modifiedAt,
      crc: crc.value,
      localHeaderOffset: offset,
    );
    _poisoned = false;
  }

  /// Members whose source could not be read in full, so their place in the
  /// archive is partly silence.
  ///
  /// THE ARCHIVE ITSELF IS SOUND when this is not zero - the padding is
  /// covered by the CRC and the sizes add up, so `unzip -t` passes and nothing
  /// looks wrong. That is exactly why the count has to come back out: a
  /// full-length WAV of silence is indistinguishable from a recording of a
  /// quiet room, and the only place that difference is known is here.
  int get incompleteMembers => _incompleteMembers;

  /// Writes the central directory and closes the file. The archive is not
  /// readable until this has run.
  Future<void> close() async {
    if (_closed) return;
    if (_poisoned) {
      throw StateError(
        'a member was started and not finished; abort() this archive',
      );
    }
    _closed = true;
    final directoryOffset = _sink.bytesWritten;
    for (final entry in _entries) {
      await _sink.add(_centralHeader(entry));
    }
    final directoryBytes = _sink.bytesWritten - directoryOffset;
    await _sink.add(_endOfCentralDirectory(
      entries: _entries.length,
      directoryBytes: directoryBytes,
      directoryOffset: directoryOffset,
    ));
    await _sink.close();
  }

  /// Closes the underlying file without finishing the archive, for an export
  /// that was cancelled or failed. The partial file is the caller's to delete.
  Future<void> abort() async {
    if (_closed) return;
    _closed = true;
    await _sink.close();
  }

  Future<int> _writeLocalHeader({
    required String name,
    required int sizeBytes,
    required DateTime modifiedAt,
  }) async {
    if (_closed) {
      throw StateError('the archive is closed');
    }
    if (sizeBytes < 0) {
      throw ArgumentError.value(sizeBytes, 'sizeBytes', 'must be >= 0');
    }
    if (_entries.length >= maxEntries) {
      throw ZipTooLargeException(
        'a zip cannot hold more than $maxEntries files',
      );
    }
    final nameBytes = utf8.encode(name);
    final offset = _sink.bytesWritten;
    if (offset + _localHeaderBytes + nameBytes.length + sizeBytes >
        maxArchiveBytes) {
      throw ZipTooLargeException(
        'a zip cannot grow past ${maxArchiveBytes ~/ (1024 * 1024)} MB',
      );
    }

    final header = Uint8List(_localHeaderBytes);
    final view = ByteData.sublistView(header);
    view.setUint32(0, 0x04034b50, Endian.little);
    view.setUint16(4, 20, Endian.little); // version needed: 2.0, stored
    view.setUint16(6, 0x0800, Endian.little); // names are UTF-8
    view.setUint16(8, 0, Endian.little); // method: stored
    view.setUint16(10, _dosTime(modifiedAt), Endian.little);
    view.setUint16(12, _dosDate(modifiedAt), Endian.little);
    view.setUint32(14, 0, Endian.little); // crc32, patched on _finish
    view.setUint32(18, sizeBytes, Endian.little);
    view.setUint32(22, sizeBytes, Endian.little);
    view.setUint16(26, nameBytes.length, Endian.little);
    view.setUint16(28, 0, Endian.little); // no extra field

    await _sink.add(header);
    await _sink.add(nameBytes);
    return offset;
  }

  /// Patches the CRC into the local header now that the data has been read.
  ///
  /// The alternative is a data descriptor after the member, which is what a
  /// writer that cannot seek has to do; this one can, exactly as `WavWriter`
  /// patches its length fields, and a header with the real numbers in it is
  /// the form every unzip handles without a second thought.
  Future<void> _finish({
    required String name,
    required int sizeBytes,
    required DateTime modifiedAt,
    required int crc,
    required int localHeaderOffset,
  }) async {
    final patch = Uint8List(4);
    ByteData.sublistView(patch).setUint32(0, crc, Endian.little);
    await _sink.patch(localHeaderOffset + 14, patch);
    _entries.add(_ZipEntry(
      name: name,
      sizeBytes: sizeBytes,
      modifiedAt: modifiedAt,
      crc: crc,
      localHeaderOffset: localHeaderOffset,
    ));
  }

  Uint8List _centralHeader(_ZipEntry entry) {
    final nameBytes = utf8.encode(entry.name);
    final header = Uint8List(_centralHeaderBytes + nameBytes.length);
    final view = ByteData.sublistView(header);
    view.setUint32(0, 0x02014b50, Endian.little);
    view.setUint16(4, 20, Endian.little); // version made by
    view.setUint16(6, 20, Endian.little); // version needed
    view.setUint16(8, 0x0800, Endian.little);
    view.setUint16(10, 0, Endian.little); // stored
    view.setUint16(12, _dosTime(entry.modifiedAt), Endian.little);
    view.setUint16(14, _dosDate(entry.modifiedAt), Endian.little);
    view.setUint32(16, entry.crc, Endian.little);
    view.setUint32(20, entry.sizeBytes, Endian.little);
    view.setUint32(24, entry.sizeBytes, Endian.little);
    view.setUint16(28, nameBytes.length, Endian.little);
    view.setUint16(30, 0, Endian.little); // extra
    view.setUint16(32, 0, Endian.little); // comment
    view.setUint16(34, 0, Endian.little); // disk
    view.setUint16(36, 0, Endian.little); // internal attributes
    view.setUint32(38, 0, Endian.little); // external attributes
    view.setUint32(42, entry.localHeaderOffset, Endian.little);
    header.setRange(_centralHeaderBytes, header.length, nameBytes);
    return header;
  }

  Uint8List _endOfCentralDirectory({
    required int entries,
    required int directoryBytes,
    required int directoryOffset,
  }) {
    final record = Uint8List(_endOfCentralDirectoryBytes);
    final view = ByteData.sublistView(record);
    view.setUint32(0, 0x06054b50, Endian.little);
    view.setUint16(4, 0, Endian.little);
    view.setUint16(6, 0, Endian.little);
    view.setUint16(8, entries, Endian.little);
    view.setUint16(10, entries, Endian.little);
    view.setUint32(12, directoryBytes, Endian.little);
    view.setUint32(16, directoryOffset, Endian.little);
    view.setUint16(20, 0, Endian.little); // no archive comment
    return record;
  }

  /// MS-DOS time: hours in bits 11-15, minutes 5-10, two-second units 0-4.
  static int _dosTime(DateTime when) =>
      (when.hour << 11) | (when.minute << 5) | (when.second ~/ 2);

  /// MS-DOS date: years since 1980 in bits 9-15, month 5-8, day 0-4.
  ///
  /// Clamped at BOTH ends, to 1980 and 2107, which is everything seven bits
  /// can say. A filesystem with a broken clock hands out dates outside that
  /// range, and a clamped date is a wrong date anyone can see; a wrapped one
  /// is a plausible date that is silently false.
  static int _dosDate(DateTime when) {
    final year = when.year.clamp(1980, 2107);
    return ((year - 1980) << 9) | (when.month << 5) | when.day;
  }
}

/// Raised out of a copy the caller asked to stop.
class ZipCancelledException implements Exception {
  const ZipCancelledException();

  @override
  String toString() => 'ZipCancelledException';
}

/// Raised when what was asked for cannot be expressed in a plain zip.
class ZipTooLargeException implements Exception {
  const ZipTooLargeException(this.message);

  final String message;

  @override
  String toString() => 'ZipTooLargeException: $message';
}

class _ZipEntry {
  const _ZipEntry({
    required this.name,
    required this.sizeBytes,
    required this.modifiedAt,
    required this.crc,
    required this.localHeaderOffset,
  });

  final String name;
  final int sizeBytes;
  final DateTime modifiedAt;
  final int crc;
  final int localHeaderOffset;
}

/// CRC-32 (the IEEE polynomial zip uses), computed a chunk at a time.
class Crc32 {
  int _value = 0xFFFFFFFF;

  static final Uint32List _table = _buildTable();

  static Uint32List _buildTable() {
    final table = Uint32List(256);
    for (var i = 0; i < 256; i++) {
      var value = i;
      for (var bit = 0; bit < 8; bit++) {
        value = (value & 1) == 1 ? 0xEDB88320 ^ (value >> 1) : value >> 1;
      }
      table[i] = value;
    }
    return table;
  }

  /// The CRC of [bytes] on their own.
  static int of(List<int> bytes) => (Crc32()..add(bytes)).value;

  void add(List<int> bytes) {
    var value = _value;
    for (final byte in bytes) {
      value = _table[(value ^ byte) & 0xFF] ^ (value >> 8);
    }
    _value = value;
  }

  int get value => (_value ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
