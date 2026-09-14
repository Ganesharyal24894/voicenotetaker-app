import 'dart:convert';

import '../../drivers/file_store.dart';

/// The recorders this phone owns, as far as the app knows, and since when.
///
/// WHY THE APP REMEMBERS AT ALL: iOS has no API that says "bonded". The
/// firmware doc's answer is to store the peripheral identifier after the first
/// successful encrypted read - iOS keeps it stable for a bonded peripheral.
/// Android reports its bonds itself, but the date shown in Settings ("Since
/// 2 Sep") is only known here.
class PairingRecord {
  const PairingRecord({this.owners = const <String, DateTime>{}});

  /// Recorder id (lower-cased) to the first time this phone connected to it
  /// encrypted.
  final Map<String, DateTime> owners;

  Map<String, Object?> toJson() => <String, Object?>{
        'version': 1,
        'owners': <String, int>{
          for (final entry in owners.entries)
            entry.key: entry.value.millisecondsSinceEpoch,
        },
      };

  /// The record in [json]; empty for anything unreadable. Never throws.
  static PairingRecord fromJson(Object? json) {
    if (json is! Map<String, Object?> || json['version'] != 1) {
      return const PairingRecord();
    }
    final owners = json['owners'];
    if (owners is! Map<String, Object?>) return const PairingRecord();
    return PairingRecord(
      owners: <String, DateTime>{
        for (final entry in owners.entries)
          if (entry.value is int)
            entry.key.toLowerCase():
                DateTime.fromMillisecondsSinceEpoch(entry.value! as int),
      },
    );
  }
}

/// [PairingRecord] in one small JSON file beside the other app settings.
class PairingStore {
  PairingStore({required this._fileStore, required String directory})
      : path = _fileStore.join(directory, fileName);

  static const String fileName = 'pairing.json';

  final FileStore _fileStore;
  final String path;

  Future<PairingRecord> load() async {
    try {
      if (await _fileStore.stat(path) == null) return const PairingRecord();
      final bytes = await _fileStore.read(path);
      return PairingRecord.fromJson(jsonDecode(utf8.decode(bytes)));
    } on Object {
      return const PairingRecord();
    }
  }

  Future<void> save(PairingRecord record) => _fileStore.writeBytes(
        path,
        utf8.encode(jsonEncode(record.toJson())),
      );
}
