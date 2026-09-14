import 'dart:async';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';

import '../drivers/clipboard_text.dart';
import '../drivers/share_sheet.dart';
import '../model/recording_info.dart';
import '../model/summary/day_summary.dart';
import '../model/summary/prompt_builder.dart';
import '../model/summary/prompt_note.dart';
import '../model/summary/reply_parser.dart';
import '../model/summary/summary_range.dart';
import '../model/transcript.dart';
import '../services/summary/day_summary_store.dart';

/// Reads one recording's saved transcript; null when it has none.
typedef TranscriptLoader = Future<Transcript?> Function(RecordingInfo recording);

/// What pasting did.
enum PasteResult {
  /// A summary was read and saved; Today shows it.
  saved,

  /// The clipboard had no text.
  emptyClipboard,

  /// The text had nothing in it this app could place.
  unreadable,
}

/// A range prompt and what the sheet says about the notes behind it.
class RangePromptInfo {
  const RangePromptInfo({required this.prompt, required this.untranscribed});

  final RangePrompt prompt;

  /// Notes in the range with no transcript yet, which the prompt leaves out.
  final int untranscribed;
}

/// A single-note prompt; [text] null when the note has no words yet.
class NotePromptInfo {
  const NotePromptInfo({required this.text, required this.wordCount});

  final String? text;
  final int wordCount;
}

/// The Today tab's controller: summaries, ticks, and the prompt round trip.
///
/// SEPARATE FROM `AppController` on purpose. Nothing here touches the radio,
/// and the recorder controller is big enough; this reaches the recordings
/// only through the [TranscriptLoader] it is handed.
class SummaryController extends ChangeNotifier {
  SummaryController({
    required this._loadTranscript,
    this._store,
    this._clipboard,
    ShareSheet? shareSheet,
    DateTime Function()? clock,
  })  : _share = shareSheet,
        _clock = clock ?? DateTime.now;

  static const String unreadableMessage =
      "Couldn't read this reply. Copy the whole answer from your AI and try again.";

  static const String emptyClipboardMessage =
      "Nothing to paste yet. Copy your AI's whole answer, then tap Paste AI reply.";

  /// A pasted reply is taken to be about the last prompt copied, if that was
  /// this recently; otherwise about today.
  static const Duration promptMemory = Duration(hours: 36);

  final TranscriptLoader _loadTranscript;
  final DaySummaryStore? _store;
  final ClipboardText? _clipboard;
  final ShareSheet? _share;
  final DateTime Function() _clock;

  List<DaySummary> _summaries = const <DaySummary>[];
  Set<String> _done = <String>{};
  LastPrompt? _lastPrompt;
  Future<void> _writes = Future<void>.value();
  bool _loaded = false;

  DateTime get now => _clock();

  bool get isLoaded => _loaded;

  /// Whether a share sheet is available; the Share buttons hide without one.
  bool get canShare => _share != null;

  /// The newest summary, with the user's ticks; null before the first paste.
  DaySummary? get latest =>
      _summaries.isEmpty ? null : _summaries.first.withTicks(_done);

  /// Reads the saved state. Safe to call more than once.
  Future<void> load() async {
    final store = _store;
    if (store != null) {
      final state = await store.load();
      _summaries = state.summaries;
      _done = <String>{...state.doneTodos};
      _lastPrompt = state.lastPrompt;
    }
    _loaded = true;
    notifyListeners();
  }

  /// Ticks or unticks [todo].
  Future<void> setDone(SummaryItem todo, bool done) async {
    final changed = done ? _done.add(todo.key) : _done.remove(todo.key);
    if (!changed) return;
    notifyListeners();
    await _persist();
  }

  /// Reads the clipboard and saves what it says.
  Future<PasteResult> pasteFromClipboard() async {
    String? text;
    try {
      text = await _clipboard?.read();
    } on Object catch (error) {
      debugPrint('Could not read the clipboard: $error');
    }
    if (text == null || text.trim().isEmpty) return PasteResult.emptyClipboard;
    return acceptReply(text);
  }

  /// Parses [reply] and, when it holds anything, makes it the latest summary.
  Future<PasteResult> acceptReply(String reply, {SummarySource source = SummarySource.pasted}) async {
    final sections = ReplyParser.parse(reply);
    if (sections == null) return PasteResult.unreadable;
    final at = now;
    final last = _lastPrompt;
    final useLast = last != null && at.difference(last.at) <= promptMemory;
    final range = useLast ? last.range : SummaryRange.today;
    final summary = DaySummary(
      source: source,
      createdAt: at,
      range: range,
      window: useLast ? last.window : range.windowAt(at),
      sections: sections,
    );
    // A to-do the AI already marked done arrives ticked. Ticks the user made
    // on an earlier reply carry over through the same keys.
    for (final todo in summary.todos) {
      if (todo.done) _done.add(todo.key);
    }
    _summaries = <DaySummary>[summary, ..._summaries];
    notifyListeners();
    await _persist();
    return PasteResult.saved;
  }

  /// The prompt for [range] over [recordings].
  Future<RangePromptInfo> rangePrompt(
    SummaryRange range,
    List<RecordingInfo> recordings,
  ) async {
    final at = now;
    final window = range.windowAt(at);
    final notes = <PromptNote>[];
    var untranscribed = 0;
    for (final recording in recordings) {
      if (!window.contains(recording.recordedAt)) continue;
      final transcript = await _load(recording);
      if (transcript == null) {
        untranscribed++;
        continue;
      }
      notes.add(_noteOf(recording, transcript));
    }
    return RangePromptInfo(
      prompt: PromptBuilder.range(range: range, now: at, notes: notes),
      untranscribed: untranscribed,
    );
  }

  /// The "Summarize this note" prompt for [recording].
  Future<NotePromptInfo> notePrompt(RecordingInfo recording) async {
    final transcript = await _load(recording);
    if (transcript == null || !transcript.hasSpeech) {
      return const NotePromptInfo(text: null, wordCount: 0);
    }
    final note = _noteOf(recording, transcript);
    return NotePromptInfo(
      text: PromptBuilder.note(note: note, now: now),
      wordCount: note.wordCount,
    );
  }

  /// Copies [text]. With [from], remembers the range a reply will be about.
  Future<void> copy(String text, {RangePrompt? from}) async {
    await _clipboard?.write(text);
    await _remember(from);
  }

  /// Opens the share sheet with [text].
  Future<void> share(String text, {RangePrompt? from, Rect? origin}) async {
    await _remember(from);
    await _share?.shareText(text, origin: origin);
  }

  // ---------------------------------------------------------------------------

  Future<Transcript?> _load(RecordingInfo recording) async {
    try {
      return await _loadTranscript(recording);
    } on Object catch (error) {
      debugPrint('Could not read a transcript for the prompt: $error');
      return null;
    }
  }

  PromptNote _noteOf(RecordingInfo recording, Transcript transcript) =>
      PromptNote.fromTranscript(
        startedAt: recording.recordedAt,
        duration: recording.duration ?? transcript.audioDuration,
        transcript: transcript,
      );

  Future<void> _remember(RangePrompt? prompt) async {
    if (prompt == null) return;
    _lastPrompt = LastPrompt(range: prompt.range, window: prompt.window, at: now);
    await _persist();
  }

  /// Writes one at a time, in order, so two quick ticks cannot land out of
  /// order on disk. A failed write is logged and forgotten: the state is still
  /// right for this run.
  Future<void> _persist() {
    final store = _store;
    if (store == null) return Future<void>.value();
    final state = DaySummaryState(
      summaries: List<DaySummary>.of(_summaries.take(DaySummaryStore.keep)),
      doneTodos: Set<String>.of(_done),
      lastPrompt: _lastPrompt,
    );
    return _writes = _writes.then((_) async {
      try {
        await store.save(state);
      } on Object catch (error) {
        debugPrint('Could not save summaries: $error');
      }
    });
  }
}
