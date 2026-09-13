import 'dart:convert';
import 'dart:typed_data';

import '../drivers/file_store.dart';
import '../model/device_test_aggregate.dart';
import '../model/device_test_result.dart';

/// Where mic-check results are kept between runs.
///
/// THE POINT OF THE WHOLE THING IS THE COMPARISON, and a comparison needs
/// yesterday's number. A result that lives only in a widget's state is gone the
/// moment the screen is popped, so every run is appended to one JSON file
/// through [FileStore] - the same driver seam the recordings use, which is what
/// keeps this class free of `dart:io` and testable in memory.
///
/// THE FILE IS ALSO A BASELINE SOMEBODY ALREADY PAID FOR. There is a phone with
/// runs in it taken on the bare board, before the enclosure existed, and those
/// numbers cannot be taken again - the board is going in a case. So this class
/// keeps EVERY ROW IT FINDS, including rows it cannot read: see [_Row] and
/// [retiredKinds]. The file is rewritten on every append, and a rewrite that
/// quietly dropped what this build does not understand would destroy the very
/// measurements the file exists for.
class DeviceTestStore {
  /// Private initializing formals keep the public parameter names
  /// (`fileStore:`, `directory:`) while assigning the private fields - the same
  /// shape [RecordingService] uses.
  DeviceTestStore({
    required this._fileStore,
    required this._directory,
    this.fileName = defaultFileName,
    this.maxResults = defaultMaxResults,
  });

  /// Sits beside the recordings rather than in a cache directory: it is a
  /// measurement record, and the OS must not evict it.
  static const String defaultFileName = 'device-tests.json';

  /// Bumped only if the shape changes incompatibly. A file from a NEWER
  /// version is not read, because this build cannot know what its fields mean.
  ///
  /// NOT BUMPED when the range walk, the link soak and the wake test were
  /// retired, and deliberately: the shape did not change, three values of one
  /// field simply stopped being produced. Bumping would have made this build
  /// refuse to read the baseline it most needs.
  static const int formatVersion = 1;

  /// Runs kept, newest first. Well past a year of daily use, and small enough
  /// that the whole history fits in a diagnostics paste.
  static const int defaultMaxResults = 200;

  /// Measurements this app used to take and no longer does.
  ///
  /// DOCUMENTED RATHER THAN FORGOTTEN. Rows with these kinds are still on disk
  /// on any phone that ran the old build, they are still written back out
  /// verbatim, and the screen says how many there are - which is the difference
  /// between "ignored" and "quietly deleted". The reasons each was retired are
  /// in the library comment of `model/device_test_result.dart`.
  static const Set<String> retiredKinds = <String>{
    'range',
    'link-soak',
    'wake-on-motion',
  };

  final FileStore _fileStore;
  final String _directory;
  final String fileName;
  final int maxResults;

  List<_Row> _rows = const <_Row>[];

  /// True once [load] has run, whether it found a file or not. Until then the
  /// screen has no history to show and must not claim there is none.
  bool _loaded = false;

  bool get isLoaded => _loaded;

  /// Every saved run this build can read, newest first.
  List<DeviceTestResult> get results => List<DeviceTestResult>.unmodifiable(
        _rows.map((row) => row.result).whereType<DeviceTestResult>(),
      );

  /// Rows in the file this build does not read: runs of a retired measurement,
  /// and anything written by a newer build.
  ///
  /// Surfaced as a COUNT rather than hidden, so a history that shows 12 runs out
  /// of a file of 15 can say where the other three went instead of looking like
  /// data loss.
  int get unreadRunCount => _rows.where((row) => row.result == null).length;

  /// How many of [unreadRunCount] are runs of a measurement that was retired,
  /// as against rows from a future build.
  int get retiredRunCount => _rows
      .where((row) => row.result == null && row.isRetired)
      .length;

  String get path => _fileStore.join(_directory, fileName);

  /// The most recent run of [kind], or `null` when there has never been one.
  DeviceTestResult? latestOf(DeviceTestKind kind) {
    for (final row in _rows) {
      final result = row.result;
      if (result != null && result.kind == kind) return result;
    }
    return null;
  }

  /// Every batch of [kind], newest first.
  ///
  /// THE UNIT OF COMPARISON IS A BATCH, not a run: one noisy measurement cannot
  /// be compared against one noisy measurement. The grouping arithmetic lives in
  /// `model/device_test_aggregate.dart`, which is pure and host-testable; this
  /// class only knows which rows to hand it.
  List<DeviceTestBatch> batchesOf(DeviceTestKind kind) => DeviceTestBatch.group(
        results.where((result) => result.kind == kind),
      );

  /// Reads the file, tolerating everything except being lied to.
  ///
  /// A missing file is an empty history, not an error - that is what a fresh
  /// install looks like. A file that cannot be parsed at all leaves the history
  /// empty and RETHROWS nothing: losing the display of old results is bad, but
  /// refusing to run new checks because of a corrupt file would be worse.
  /// Individual entries this build does not understand are kept as [_Row]s with
  /// no result, so one row written by a newer build neither hides the other 199
  /// nor gets erased by the next append.
  Future<void> load() async {
    _loaded = true;
    Uint8List bytes;
    try {
      if (!await _fileStore.exists(path)) {
        _rows = const <_Row>[];
        return;
      }
      bytes = await _fileStore.read(path);
    } on Object {
      _rows = const <_Row>[];
      return;
    }
    _rows = _decode(bytes);
  }

  /// Saves [result] as the newest run and returns the full readable history.
  ///
  /// A write failure is reported by throwing, because a check whose result was
  /// not saved has failed at the only thing this file exists to do, and the
  /// screen must say so rather than show a number that will not be there
  /// tomorrow.
  Future<List<DeviceTestResult>> append(DeviceTestResult result) async {
    final next = <_Row>[_Row.of(result), ..._rows];
    if (next.length > maxResults) next.removeRange(maxResults, next.length);
    await _fileStore.writeBytes(path, _encode(next));
    _rows = next;
    return results;
  }

  /// Forgets every saved run, INCLUDING the ones this build cannot read. Used
  /// only by an explicit action, because it throws away a baseline.
  Future<void> clear() async {
    await _fileStore.writeBytes(path, _encode(const <_Row>[]));
    _rows = const <_Row>[];
  }

  List<int> _encode(List<_Row> rows) => utf8.encode(
        const JsonEncoder.withIndent('  ').convert(<String, Object?>{
          'version': formatVersion,
          // Each row's own JSON: re-encoded from the model when this build read
          // it, and passed through byte-for-byte when it did not.
          'results': rows.map((row) => row.json).toList(),
        }),
      );

  List<_Row> _decode(Uint8List bytes) {
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on Object {
      return const <_Row>[];
    }
    if (decoded is! Map) return const <_Row>[];
    final version = decoded['version'];
    // A file from a newer build is left ALONE and not shown. Reading fields
    // whose meaning may have changed would put wrong numbers on screen, and
    // rewriting the file would destroy the newer build's history.
    if (version is! int || version > formatVersion) {
      return const <_Row>[];
    }
    final raw = decoded['results'];
    if (raw is! List) return const <_Row>[];
    final rows = <_Row>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      rows.add(_Row.read(entry.cast<String, Object?>()));
    }
    return rows;
  }
}

/// One entry of the saved file: its JSON, and the result if this build can read
/// it.
///
/// THE JSON IS THE SOURCE OF TRUTH FOR WRITING, not the model. That is what lets
/// a run of a retired measurement survive every future append: it is never
/// interpreted, only carried.
class _Row {
  const _Row({required this.json, required this.result});

  /// A row this build just wrote.
  factory _Row.of(DeviceTestResult result) =>
      _Row(json: result.toJson(), result: result);

  /// A row out of the file. [result] is null when it cannot be read - a retired
  /// kind, or anything a newer build invented.
  factory _Row.read(Map<String, Object?> json) {
    try {
      return _Row(json: json, result: DeviceTestResult.fromJson(json));
    } on Object {
      return _Row(json: json, result: null);
    }
  }

  final Map<String, Object?> json;

  /// Null when this build does not understand the row.
  final DeviceTestResult? result;

  /// True when the row is a run of a measurement this app used to take.
  bool get isRetired {
    final kind = json['kind'];
    return kind is String && DeviceTestStore.retiredKinds.contains(kind);
  }
}
