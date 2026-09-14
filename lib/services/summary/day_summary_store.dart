import 'dart:convert';

import '../../drivers/file_store.dart';
import '../../model/summary/day_summary.dart';
import '../../model/summary/summary_range.dart';

/// Everything the Today tab keeps between launches, as one small JSON file in
/// the app support directory.
class DaySummaryState {
  const DaySummaryState({
    this.summaries = const <DaySummary>[],
    this.doneTodos = const <String>{},
    this.lastPrompt,
  });

  /// Newest first.
  final List<DaySummary> summaries;

  /// [SummaryItem.key]s of ticked to-dos. Kept apart from the summaries so a
  /// newer reply about the same day keeps the ticks.
  final Set<String> doneTodos;

  /// The range of the last prompt copied or shared, which is what a pasted
  /// reply is about.
  final LastPrompt? lastPrompt;
}

class LastPrompt {
  const LastPrompt({required this.range, required this.window, required this.at});

  final SummaryRange range;
  final DayWindow window;
  final DateTime at;
}

/// Reads and writes [DaySummaryState]. Domain logic only, through [FileStore],
/// so it runs in tests against memory.
class DaySummaryStore {
  DaySummaryStore({required FileStore fileStore, required String directory})
      : _fileStore = fileStore,
        _path = fileStore.join(directory, fileName);

  static const String fileName = 'day-summaries.json';
  static const int formatVersion = 1;

  /// How many summaries are kept. Only the newest drives Today; the rest are
  /// there for a history screen, and cost a few kB.
  static const int keep = 30;

  final FileStore _fileStore;
  final String _path;

  /// The saved state, or an empty one when there is none or it cannot be
  /// read. Never throws: a damaged file costs the summaries, not the app.
  Future<DaySummaryState> load() async {
    try {
      if (await _fileStore.stat(_path) == null) return const DaySummaryState();
      final json = jsonDecode(utf8.decode(await _fileStore.read(_path)));
      if (json is! Map<String, Object?> || json['version'] != formatVersion) {
        return const DaySummaryState();
      }
      final rawSummaries = json['summaries'];
      final rawDone = json['doneTodos'];
      final rawLast = json['lastPrompt'];
      LastPrompt? last;
      if (rawLast is Map<String, Object?>) {
        final range = SummaryRange.byName(rawLast['range']);
        final start = DateTime.tryParse('${rawLast['windowStart']}');
        final end = DateTime.tryParse('${rawLast['windowEnd']}');
        final at = DateTime.tryParse('${rawLast['at']}');
        if (range != null && start != null && end != null && at != null) {
          last = LastPrompt(range: range, window: DayWindow(start, end), at: at);
        }
      }
      return DaySummaryState(
        summaries: <DaySummary>[
          if (rawSummaries is List<Object?>)
            for (final raw in rawSummaries) ?DaySummary.fromJson(raw),
        ],
        doneTodos: <String>{
          if (rawDone is List<Object?>) ...rawDone.whereType<String>(),
        },
        lastPrompt: last,
      );
    } on Object {
      return const DaySummaryState();
    }
  }

  Future<void> save(DaySummaryState state) {
    final last = state.lastPrompt;
    return _fileStore.writeBytes(
      _path,
      utf8.encode(jsonEncode(<String, Object?>{
        'version': formatVersion,
        'summaries': <Object?>[
          for (final summary in state.summaries.take(keep)) summary.toJson(),
        ],
        'doneTodos': state.doneTodos.toList()..sort(),
        if (last != null)
          'lastPrompt': <String, Object?>{
            'range': last.range.name,
            'windowStart': last.window.start.toIso8601String(),
            'windowEnd': last.window.end.toIso8601String(),
            'at': last.at.toIso8601String(),
          },
      })),
    );
  }
}
