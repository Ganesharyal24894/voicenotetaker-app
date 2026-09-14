import 'dart:typed_data';

import '../drivers/file_store.dart';
import 'library_service.dart';
import 'wav_reader.dart';

/// Brings the length fields of interrupted recordings up to date.
///
/// A capture writes a provisional header and patches it as it goes - on stop
/// for a manual recording, every few seconds for an always-listening note. An
/// app killed in between leaves a header that claims less audio than the file
/// holds, sometimes none at all, and a player trusts the header. This pass
/// runs once at startup, before anything is writing, and makes each header
/// describe the bytes that are really there.
///
/// Domain logic only, through [FileStore]: one header read per recording, and
/// a patch of eight bytes where one is needed. Never reads a payload.
abstract final class WavRepair {
  /// Repairs every recording in [directory]. Returns the paths it changed.
  ///
  /// A file that fails to read or patch is left as it was - the library still
  /// lists it, so the user can delete it - and the pass carries on.
  static Future<List<String>> repairDirectory(
    FileStore fileStore,
    String directory,
  ) async {
    final repaired = <String>[];
    final List<String> paths;
    try {
      paths = await fileStore.list(directory);
    } on Object {
      return repaired;
    }
    for (final path in paths) {
      if (!path.toLowerCase().endsWith(RecordingNaming.extension)) continue;
      try {
        if (await repair(fileStore, path)) repaired.add(path);
      } on Object {
        // Left for the library to list as it is.
      }
    }
    return repaired;
  }

  /// Repairs the one file at [path]. True when it was changed.
  ///
  /// Only 16-bit-style PCM (format 1) is touched, and only a header whose
  /// `data` length disagrees with the whole samples on disk. Anything this
  /// reader cannot parse is not ours to rewrite.
  static Future<bool> repair(FileStore fileStore, String path) async {
    final info = await fileStore.stat(path);
    if (info == null) return false;
    final probe = await fileStore.readRange(path, 0, WavReader.probeLength);
    final header = WavReader.parse(probe);
    if (header == null || header.audioFormat != 1 || header.blockAlign <= 0) {
      return false;
    }
    final available = info.sizeBytes - header.dataOffset;
    if (available < 0) return false;
    final dataLength = available - available % header.blockAlign;
    if (header.dataLength == dataLength) return false;

    // RIFF size is everything after its own eight bytes, up to the end of the
    // audio; any trailing odd byte is not counted.
    await fileStore.patchBytes(
      path,
      4,
      _uint32le(header.dataOffset + dataLength - 8),
    );
    await fileStore.patchBytes(
      path,
      header.dataOffset - 4,
      _uint32le(dataLength),
    );
    return true;
  }

  static Uint8List _uint32le(int value) {
    final bytes = Uint8List(4);
    ByteData.sublistView(bytes).setUint32(0, value, Endian.little);
    return bytes;
  }
}
