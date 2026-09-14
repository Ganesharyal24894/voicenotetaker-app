import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/controller/summary_controller.dart';
import 'package:voicenotetaker_app/model/recording_info.dart';
import 'package:voicenotetaker_app/model/summary/day_summary.dart';
import 'package:voicenotetaker_app/model/summary/summary_range.dart';
import 'package:voicenotetaker_app/model/transcript.dart';
import 'package:voicenotetaker_app/services/summary/day_summary_store.dart';

import '../view/harness.dart';
import 'fakes.dart';

const String _reply = '''
## Summary
- Deadline moved to Friday.
## To-dos
- [ ] Get staging access | You promised | today | 09:14
- [ ] Book car service | Note to self | - | 10:21
''';

void main() {
  late MemoryFileStore files;
  late FakeClipboard clipboard;
  late FakeShareSheet share;
  late DateTime now;
  final transcripts = <String, Transcript?>{};

  SummaryController make({bool persisted = true}) => SummaryController(
        loadTranscript: (recording) async => transcripts[recording.path],
        store: persisted ? DaySummaryStore(fileStore: files, directory: '/support') : null,
        clipboard: clipboard,
        shareSheet: share,
        clock: () => now,
      );

  setUp(() {
    files = MemoryFileStore();
    clipboard = FakeClipboard();
    share = FakeShareSheet();
    now = DateTime(2026, 9, 15, 18, 30);
    transcripts.clear();
  });

  group('pasting a reply', () {
    test('saves it as the latest pasted summary for today', () async {
      final controller = make();
      await controller.load();
      clipboard.text = _reply;

      expect(await controller.pasteFromClipboard(), PasteResult.saved);
      final latest = controller.latest!;
      expect(latest.source, SummarySource.pasted);
      expect(latest.createdAt, now);
      expect(latest.range, SummaryRange.today);
      expect(latest.window, SummaryRange.today.windowAt(now));
      expect(latest.todos.map((t) => t.text), <String>['Get staging access', 'Book car service']);
    });

    test('an empty clipboard and an unreadable reply are told apart', () async {
      final controller = make();
      await controller.load();
      expect(await controller.pasteFromClipboard(), PasteResult.emptyClipboard);
      clipboard.text = 'Sorry, I cannot help with that.';
      expect(await controller.pasteFromClipboard(), PasteResult.unreadable);
      expect(controller.latest, isNull);
      expect(SummaryController.unreadableMessage,
          "Couldn't read this reply. Copy the whole answer from your AI and try again.");
    });

    test('the reply is about the range last copied, if copied recently', () async {
      final controller = make();
      await controller.load();
      final info = await controller.rangePrompt(SummaryRange.last7Days, const <RecordingInfo>[]);
      await controller.copy(info.prompt.whole, from: info.prompt);
      now = now.add(const Duration(hours: 2));

      await controller.acceptReply(_reply);
      expect(controller.latest!.range, SummaryRange.last7Days);
      expect(controller.latest!.window, info.prompt.window);

      now = now.add(const Duration(days: 2));
      await controller.acceptReply(_reply);
      expect(controller.latest!.range, SummaryRange.today, reason: 'the copy is too old to be what this is about');
    });

    test('survives a restart', () async {
      final first = make();
      await first.load();
      await first.acceptReply(_reply);
      await first.setDone(first.latest!.todos.first, true);

      final second = make();
      await second.load();
      expect(second.latest!.todos.map((t) => t.done), <bool>[true, false]);
      expect(jsonDecode(utf8.decode(files.files['/support/day-summaries.json']!)), isA<Map<String, Object?>>());
    });

    test('a damaged file loads as nothing rather than failing', () async {
      files.files['/support/day-summaries.json'] = utf8.encode('{not json');
      final controller = make();
      await controller.load();
      expect(controller.latest, isNull);
      expect(controller.isLoaded, isTrue);
    });
  });

  group('ticks carry over to a newer reply', () {
    test('matched by normalised task text and note time', () async {
      final controller = make();
      await controller.load();
      await controller.acceptReply(_reply);
      await controller.setDone(controller.latest!.todos.first, true);

      await controller.acceptReply('''
## To-dos
- [ ] get staging ACCESS. | IT | today | 09:14
- [ ] Get staging access | IT | today | 11:00
- [ ] Book car service | Note to self | - | 10:21
- [ ] Pay rent
''');
      expect(controller.latest!.todos.map((t) => t.done), <bool>[true, false, false, false]);
    });

    test('unticking is remembered too', () async {
      final controller = make();
      await controller.load();
      await controller.acceptReply(_reply);
      final todo = controller.latest!.todos.first;
      await controller.setDone(todo, true);
      await controller.setDone(todo, false);
      await controller.acceptReply(_reply);
      expect(controller.latest!.todos.first.done, isFalse);
    });

    test('a to-do the AI marked [x] arrives ticked', () async {
      final controller = make();
      await controller.load();
      await controller.acceptReply('## To-dos\n- [x] Done already | me | - | 08:00');
      expect(controller.latest!.todos.single.done, isTrue);
    });
  });

  group('prompts', () {
    test('the range prompt uses only notes in the window, and counts the untranscribed', () async {
      final controller = make();
      final inRange = recordingAt(DateTime(2026, 9, 15, 9, 14));
      final noTranscript = recordingAt(DateTime(2026, 9, 15, 10, 0), hasTranscript: false);
      final yesterday = recordingAt(DateTime(2026, 9, 14, 9, 0));
      transcripts[inRange.path] = transcriptOf('आज की मीटिंग');
      transcripts[yesterday.path] = transcriptOf('कल');

      final info = await controller.rangePrompt(
        SummaryRange.today,
        <RecordingInfo>[inRange, noTranscript, yesterday],
      );
      expect(info.prompt.noteCount, 1);
      expect(info.untranscribed, 1);
      expect(info.prompt.whole, contains('[09:14 · 12 min]\nआज की मीटिंग'));
      expect(info.prompt.whole, isNot(contains('कल')));
    });

    test('copy writes the clipboard; share opens the sheet with the text', () async {
      final controller = make();
      await controller.copy('prompt text');
      expect(clipboard.text, 'prompt text');
      await controller.share('shared text');
      expect(share.shared, <String>['shared text']);
    });

    test('the note prompt, or nothing for a note without words', () async {
      final controller = make();
      final note = recordingAt(DateTime(2026, 9, 15, 9, 14));
      final silent = recordingAt(DateTime(2026, 9, 15, 9, 30));
      transcripts[note.path] = transcriptOf('एक दो तीन');
      transcripts[silent.path] = transcriptOf('  ');

      final info = await controller.notePrompt(note);
      expect(info.text, contains('at 09:14 (12 min)'));
      expect(info.text, endsWith('[00:00] एक दो तीन'));
      expect(info.wordCount, 3);
      expect((await controller.notePrompt(silent)).text, isNull);
    });

    test('a transcript that fails to load is left out, not thrown', () async {
      final controller = SummaryController(
        loadTranscript: (_) async => throw StateError('disk'),
        clock: () => now,
      );
      final info = await controller.rangePrompt(SummaryRange.today, <RecordingInfo>[recordingAt(DateTime(2026, 9, 15, 9))]);
      expect(info.prompt.noteCount, 0);
      expect(info.untranscribed, 1);
    });
  });
}
