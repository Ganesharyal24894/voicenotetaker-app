import 'dart:convert';

import '../drivers/file_store.dart';
import '../model/battery_anchor.dart';

/// Every `fe09` anchor the phone has taken, in one small JSON file in the app
/// support directory.
///
/// Through [FileStore] rather than a database: a few hundred small records do
/// not justify a package, and this runs in tests against the in-memory store.
///
/// BOUNDED. [maxAnchors] at one read per connect plus one per 30 min while
/// connected is weeks of history - more than the eight sessions the recorder
/// itself keeps - and the file stays around 60 kB at most.
class BatteryAnchorStore {
  BatteryAnchorStore({
    required this._fileStore,
    required String directory,
  }) : path = _fileStore.join(directory, fileName);

  static const String fileName = 'battery-anchors.json';
  static const int maxAnchors = 400;

  final FileStore _fileStore;
  final String path;

  List<BatteryAnchor>? _cache;

  /// The saved anchors, oldest first; empty when there are none or the file is
  /// damaged. Never throws.
  Future<List<BatteryAnchor>> load() async {
    final cached = _cache;
    if (cached != null) return List<BatteryAnchor>.unmodifiable(cached);
    final anchors = <BatteryAnchor>[];
    try {
      if (await _fileStore.stat(path) != null) {
        final json = jsonDecode(utf8.decode(await _fileStore.read(path)));
        if (json is Map && json['version'] == 1 && json['anchors'] is List) {
          for (final item in json['anchors'] as List) {
            final anchor = BatteryAnchor.fromJson(item);
            if (anchor != null) anchors.add(anchor);
          }
        }
      }
    } on Object {
      anchors.clear();
    }
    anchors.sort((a, b) => a.utc.compareTo(b.utc));
    _cache = anchors;
    return List<BatteryAnchor>.unmodifiable(anchors);
  }

  /// Records [anchor] and saves. A failed save throws; the anchor is still
  /// kept in memory for this run.
  ///
  /// AWAKE SECONDS THAT GO BACKWARDS (the firmware doc, step 8): within one
  /// session id, a lower count WITH more boots is a reset that lost unsaved
  /// seconds, so the older anchors stay; WITHOUT more boots it is a different
  /// session that reused the id, so the older anchors of that id are dropped.
  Future<List<BatteryAnchor>> add(BatteryAnchor anchor) async {
    await load();
    final anchors = _cache!;
    BatteryAnchor? previous;
    for (final existing in anchors) {
      if (existing.sessionId == anchor.sessionId &&
          existing.state == anchor.state &&
          !existing.utc.isAfter(anchor.utc)) {
        previous = existing;
      }
    }
    if (previous != null &&
        anchor.awakeSeconds < previous.awakeSeconds &&
        anchor.boots <= previous.boots) {
      anchors.removeWhere(
        (a) => a.sessionId == anchor.sessionId && a.state == anchor.state,
      );
    }
    anchors
      ..add(anchor)
      ..sort((a, b) => a.utc.compareTo(b.utc));
    if (anchors.length > maxAnchors) {
      anchors.removeRange(0, anchors.length - maxAnchors);
    }
    await _fileStore.writeBytes(
      path,
      utf8.encode(
        jsonEncode(<String, Object?>{
          'version': 1,
          'anchors': <Object?>[for (final a in anchors) a.toJson()],
        }),
      ),
    );
    return List<BatteryAnchor>.unmodifiable(anchors);
  }
}
