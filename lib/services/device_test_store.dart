import 'dart:convert';
import 'dart:typed_data';

import '../drivers/file_store.dart';
import '../model/device_test_aggregate.dart';
import '../model/device_test_result.dart';

/// Where device-test results are kept between runs.
///
/// THE POINT OF THE WHOLE HARNESS IS THE COMPARISON, and a comparison needs
/// yesterday's number. A result that lives only in a widget's state is gone the
/// moment the screen is popped, so every run is appended to one JSON file
/// through [FileStore] - the same driver seam the recordings use, which is what
/// keeps this class free of `dart:io` and testable in memory.
///
/// The file is read once on [load] and rewritten on every append. That is a
/// few kilobytes rewritten a handful of times a day, which is not worth the
/// complexity of an append-only format.
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
  static const int formatVersion = 1;

  /// Runs kept, newest first. Well past a year of daily use, and small enough
  /// that the whole history fits in a diagnostics paste.
  static const int defaultMaxResults = 200;

  final FileStore _fileStore;
  final String _directory;
  final String fileName;
  final int maxResults;

  List<DeviceTestResult> _results = const <DeviceTestResult>[];

  /// True once [load] has run, whether it found a file or not. Until then the
  /// screen has no history to show and must not claim there is none.
  bool _loaded = false;

  bool get isLoaded => _loaded;

  /// Every saved run, newest first.
  List<DeviceTestResult> get results => List.unmodifiable(_results);

  String get path => _fileStore.join(_directory, fileName);

  /// The most recent run of [kind], or `null` when there has never been one.
  DeviceTestResult? latestOf(DeviceTestKind kind) {
    for (final result in _results) {
      if (result.kind == kind) return result;
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
        _results.where((result) => result.kind == kind),
      );

  /// Reads the file, tolerating everything except being lied to.
  ///
  /// A missing file is an empty history, not an error - that is what a fresh
  /// install looks like. A file that cannot be parsed at all leaves the history
  /// empty and RETHROWS nothing: losing the display of old results is bad, but
  /// refusing to run new tests because of a corrupt file would be worse.
  /// Individual entries this build does not understand are skipped one by one,
  /// so one bad row written by a newer build does not hide the other 199.
  Future<void> load() async {
    _loaded = true;
    Uint8List bytes;
    try {
      if (!await _fileStore.exists(path)) {
        _results = const <DeviceTestResult>[];
        return;
      }
      bytes = await _fileStore.read(path);
    } on Object {
      _results = const <DeviceTestResult>[];
      return;
    }
    _results = _decode(bytes);
  }

  /// Saves [result] as the newest run and returns the full history.
  ///
  /// A write failure is reported by throwing, because a test whose result was
  /// not saved has failed at the only thing this harness exists to do, and the
  /// screen must say so rather than show a number that will not be there
  /// tomorrow.
  Future<List<DeviceTestResult>> append(DeviceTestResult result) async {
    final next = <DeviceTestResult>[result, ..._results];
    if (next.length > maxResults) next.removeRange(maxResults, next.length);
    await _fileStore.writeBytes(path, _encode(next));
    _results = next;
    return results;
  }

  /// Forgets every saved run. Used only by an explicit action.
  Future<void> clear() async {
    await _fileStore.writeBytes(path, _encode(const <DeviceTestResult>[]));
    _results = const <DeviceTestResult>[];
  }

  List<int> _encode(List<DeviceTestResult> results) => utf8.encode(
        const JsonEncoder.withIndent('  ').convert(<String, Object?>{
          'version': formatVersion,
          'results': results.map((r) => r.toJson()).toList(),
        }),
      );

  List<DeviceTestResult> _decode(Uint8List bytes) {
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on Object {
      return const <DeviceTestResult>[];
    }
    if (decoded is! Map) return const <DeviceTestResult>[];
    final version = decoded['version'];
    // A file from a newer build is left ALONE and not shown. Reading fields
    // whose meaning may have changed would put wrong numbers on screen, and
    // rewriting the file would destroy the newer build's history.
    if (version is! int || version > formatVersion) {
      return const <DeviceTestResult>[];
    }
    final raw = decoded['results'];
    if (raw is! List) return const <DeviceTestResult>[];
    final results = <DeviceTestResult>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      try {
        results.add(DeviceTestResult.fromJson(entry.cast<String, Object?>()));
      } on Object {
        // One unreadable row, skipped. See the method comment.
        continue;
      }
    }
    return results;
  }
}
