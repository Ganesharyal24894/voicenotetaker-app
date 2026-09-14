import '../../model/recording_info.dart';

/// Which recordings to transcribe in the background, and in what order.
///
/// Pure ordering logic, no I/O and no timers: the controller decides WHEN a
/// job runs (only in the foreground, one at a time) and asks this WHICH.
///
/// NEWEST FIRST, because the note someone just finished is the one they are
/// most likely to open. A recording the user opens jumps to the front.
class TranscriptionQueue {
  final List<String> _pending = <String>[];

  /// Paths waiting, front first.
  List<String> get pending => List<String>.unmodifiable(_pending);

  bool get isEmpty => _pending.isEmpty;

  bool contains(String path) => _pending.contains(path);

  /// The recordings that need a transcript, newest first.
  ///
  /// Skipped: those with a saved transcript, those that already failed (the
  /// Transcribe button is still there for them), the note still being
  /// written, and anything already running.
  static List<String> plan({
    required List<RecordingInfo> recordings,
    Set<String> failed = const <String>{},
    String? writing,
    String? running,
  }) {
    final sorted = <RecordingInfo>[...recordings]
      ..sort((a, b) => b.recordedAt.compareTo(a.recordedAt));
    return <String>[
      for (final recording in sorted)
        if (!recording.hasTranscript &&
            !recording.transcriptFailed &&
            !failed.contains(recording.path) &&
            recording.path != writing &&
            recording.path != running)
          recording.path,
    ];
  }

  /// Replaces the queue with [paths], in that order, keeping a recording the
  /// user had already moved to the front there.
  void replace(List<String> paths) {
    final front = _pending.isEmpty ? null : _pending.first;
    _pending
      ..clear()
      ..addAll(paths);
    if (front != null && _pending.remove(front)) _pending.insert(0, front);
  }

  /// Puts [path] first, adding it if it was not waiting. For a note that has
  /// just been finished.
  void addFront(String path) {
    _pending
      ..remove(path)
      ..insert(0, path);
  }

  /// Moves [path] to the front if it is waiting. True when it was.
  bool prioritise(String path) {
    if (!_pending.remove(path)) return false;
    _pending.insert(0, path);
    return true;
  }

  /// Takes the next path to run, passing over [skip] (the note being written)
  /// without dropping it.
  String? takeNext({String? skip}) {
    for (var i = 0; i < _pending.length; i++) {
      if (_pending[i] == skip) continue;
      return _pending.removeAt(i);
    }
    return null;
  }

  void remove(String path) => _pending.remove(path);

  void clear() => _pending.clear();
}
