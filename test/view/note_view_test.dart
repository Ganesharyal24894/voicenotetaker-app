import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/drivers/audio_player.dart';
import 'package:voicenotetaker_app/model/recording_info.dart';
import 'package:voicenotetaker_app/model/transcript.dart';
import 'package:voicenotetaker_app/model/transcription.dart';
import 'package:voicenotetaker_app/services/library_service.dart';
import 'package:voicenotetaker_app/services/transcription/transcript_store.dart';
import 'package:voicenotetaker_app/view/note_audio_panel.dart';
import 'package:voicenotetaker_app/view/note_view.dart';
import 'package:voicenotetaker_app/view/widgets/waveform.dart';

import 'harness.dart';

const Duration _length = Duration(minutes: 4, seconds: 12);
final DateTime _at = DateTime(2026, 9, 10, 9, 14);
final DateTime _now = DateTime(2026, 9, 10, 15, 14);

Transcript _transcript(List<(int, String, String?)> lines) => Transcript(
      languageCode: 'hi',
      modelId: SpeechModels.indicConformerHindiInt8.id,
      createdAt: DateTime.utc(2026, 9, 10),
      audioDuration: _length,
      segments: <TranscriptSegment>[
        for (final (at, text, speaker) in lines)
          TranscriptSegment(
            start: Duration(seconds: at),
            end: Duration(seconds: at + 5),
            text: text,
            speaker: speaker,
          ),
      ],
    );

final Transcript _plain = _transcript(<(int, String, String?)>[
  (0, 'हाँ, सुनो', null),
  (42, 'ठीक है', null),
]);

final Transcript _twoSpeakers = _transcript(<(int, String, String?)>[
  (0, 'हाँ, सुनो', 'S1'),
  (9, 'अच्छा, ये तो अच्छी न्यूज़ है', 'S2'),
]);

class _Note {
  _Note(this.harness, this.fake, this.info);

  final ViewHarness harness;
  final FakePlayback fake;
  final RecordingInfo info;

  MockAudioPlayer get player => fake.player;

  Future<void> emit(
    WidgetTester tester, {
    required bool isPlaying,
    required Duration position,
  }) async {
    fake.emit(
      isPlaying: isPlaying,
      position: position,
      duration: _length,
      path: info.path,
    );
    await tester.pump();
    await tester.pump();
  }
}

Future<_Note> _open(
  WidgetTester tester, {
  bool withPlayer = true,
  FakePlayback? fake,
  ScriptedRecognizer? recognizer,
  bool speechModelInstalled = true,
  Transcript? saved,
  bool autoDelete = false,
  bool keep = false,
  bool removeAudio = false,
  VoidCallback? onDeleted,
  VoidCallback? onSummarize,
}) async {
  final playback = fake ?? FakePlayback();
  addTearDown(playback.close);
  final harness = ViewHarness(
    audioPlayer: withPlayer ? playback.player : null,
    recognizer: recognizer,
    speechModelInstalled: speechModelInstalled,
    // The retention sweep's clock: six hours after the note, not too old.
    clock: () => _now,
  );
  addTearDown(harness.dispose);
  await harness.controller.initialise();

  final path = await harness.seedRecording(at: _at, length: _length);
  if (saved != null) {
    await TranscriptStore(fileStore: harness.fileStore).save(path, saved);
  }
  if (keep) await harness.controller.setKeepAudio(path, true);
  if (autoDelete) {
    // The sweep runs at once; the note is 6 h old, so nothing is removed.
    await tester.runAsync(() => harness.controller.setAutoDeleteAudio(true));
  }
  if (removeAudio) {
    harness.fileStore.files[RecordingNaming.audioRemovedPathOf(path)] =
        <int>[123, 125];
    harness.fileStore.files.remove(path);
  }
  await harness.controller.refreshLibrary();
  final info = harness.controller.recordings.firstWhere((r) => r.path == path);

  await pumpScreen(
    tester,
    NoteView(
      controller: harness.controller,
      recording: info,
      now: _now,
      onDeleted: onDeleted,
      onSummarize: onSummarize,
    ),
  );
  await flush(tester);
  return _Note(harness, playback, info);
}

Future<void> _openAudio(WidgetTester tester) async {
  await tester.tap(find.bySemanticsLabel('Show audio'));
  await tester.pump();
  await tester.pump();
}

void main() {
  setUpAll(registerViewFallbacks);

  group('the transcript comes first', () {
    testWidgets('title, meta and plain paragraphs with timestamps',
        (tester) async {
      await _open(tester, saved: _plain);

      expect(find.text('09:14 · 4 min'), findsOneWidget);
      expect(find.text('Today · 4 words'), findsOneWidget);
      expect(find.text('00:00'), findsOneWidget);
      expect(find.text('00:42'), findsOneWidget);
      expect(find.text('हाँ, सुनो'), findsOneWidget);
      expect(find.text('ठीक है'), findsOneWidget);
      // One voice: no chips, no Rename.
      expect(find.text('Rename'), findsNothing);
      // Nothing is played until asked.
      expect(find.byType(NoteAudioPanel), findsNothing);
      expect(find.text('Summarize with your AI'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('two speakers: chips, labels, and the count in the meta',
        (tester) async {
      await _open(tester, saved: _twoSpeakers);

      expect(find.text('Today · 2 speakers · 8 words'), findsOneWidget);
      // A chip and a paragraph label each.
      expect(find.text('Speaker 1'), findsNWidgets(2));
      expect(find.text('Speaker 2'), findsNWidgets(2));
      expect(find.text('Rename'), findsOneWidget);
    });

    testWidgets('Rename saves names that replace Speaker N everywhere',
        (tester) async {
      final note = await _open(tester, saved: _twoSpeakers);

      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(1), 'Priya');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      await flush(tester);

      expect(find.text('Priya'), findsNWidgets(2));
      expect(find.text('Speaker 2'), findsNothing);
      expect(
        note.harness.fileStore.files,
        contains(RecordingNaming.speakerNamesPathOf(note.info.path)),
      );
    });

    testWidgets('Copy copies timestamps and words, and says Copied',
        (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied =
                (call.arguments as Map<Object?, Object?>)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      await _open(tester, saved: _twoSpeakers);
      await tester.tap(find.bySemanticsLabel('Copy transcript'));
      await tester.pump();
      await tester.pump();

      expect(copied, '[00:00] Speaker 1: हाँ, सुनो\n'
          '[00:09] Speaker 2: अच्छा, ये तो अच्छी न्यूज़ है');
      expect(find.text('Copied'), findsOneWidget);
    });

    testWidgets('Summarize calls back', (tester) async {
      var asked = 0;
      await _open(tester, saved: _plain, onSummarize: () => asked++);

      await tester.tap(find.text('Summarize with your AI'));
      await tester.pump();

      expect(asked, 1);
    });
  });

  group('transcript states fill the body', () {
    Future<void> runJob(WidgetTester tester, _Note note) async {
      for (var i = 0; i < 200; i++) {
        await tester.pump();
        if (!note.harness.controller.isTranscribing) break;
      }
      await tester.pump();
    }

    void expectNoRawErrors() {
      for (final raw in <String>['Exception', 'Error', 'boom', 'onnx', '/tmp/']) {
        expect(find.textContaining(raw), findsNothing, reason: raw);
      }
    }

    testWidgets('no transcript: says so, offers Transcribe, runs nothing',
        (tester) async {
      final recognizer = ScriptedRecognizer();
      var summarized = 0;
      await _open(
        tester,
        recognizer: recognizer,
        onSummarize: () => summarized++,
      );

      expect(find.text('Not transcribed yet.'), findsOneWidget);
      expect(find.bySemanticsLabel('Transcribe'), findsOneWidget);
      expect(recognizer.calls, 0);
      // Nothing to summarize yet.
      await tester.tap(find.text('Summarize with your AI'));
      await tester.pump();
      expect(summarized, 0);
    });

    testWidgets('transcribing: percent and a progress bar, then the words',
        (tester) async {
      // 4:12 is 32 windows; holding before window 8 is 25%.
      final recognizer = ScriptedRecognizer()
        ..gate = Completer<void>()
        ..holdBefore = 8
        ..texts = <int, String>{0: 'चेक चेक'};
      final note = await _open(tester, recognizer: recognizer);

      await tester.tap(find.bySemanticsLabel('Transcribe'));
      for (var i = 0; i < 40; i++) {
        await tester.pump();
      }
      expect(find.text('Transcribing 25%'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      recognizer.gate!.complete();
      await runJob(tester, note);

      expect(find.text('चेक चेक'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('waiting: waiting to transcribe', (tester) async {
      final recognizer = ScriptedRecognizer()..gate = Completer<void>();
      final note = await _open(tester, recognizer: recognizer);
      final other = await note.harness.seedRecording(at: DateTime(2026, 9, 1));
      // Another note running, this one queued behind it.
      unawaited(note.harness.controller.transcribe(note.harness.controller
          .recordings
          .firstWhere((r) => r.path == other)));
      await tester.runAsync(() => note.harness.controller.appForegrounded());
      await flush(tester);

      expect(find.text('Waiting to transcribe…'), findsOneWidget);

      final cancelled = note.harness.controller.cancelTranscription();
      await flush(tester);
      await cancelled;
    });

    testWidgets('no speech found', (tester) async {
      final note = await _open(tester, recognizer: ScriptedRecognizer());
      await tester.tap(find.bySemanticsLabel('Transcribe'));
      await runJob(tester, note);

      expect(find.text('No speech found.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('failed: a plain message, Try again, and Transcribe again in '
        'the menu', (tester) async {
      final recognizer = ScriptedRecognizer()..failWith = StateError('onnx boom');
      final note = await _open(tester, recognizer: recognizer);
      await tester.tap(find.bySemanticsLabel('Transcribe'));
      await runJob(tester, note);

      expect(find.text("Couldn't transcribe this note."), findsOneWidget);
      expect(find.bySemanticsLabel('Try again'), findsOneWidget);
      expectNoRawErrors();

      await tester.tap(find.bySemanticsLabel('More'));
      await tester.pumpAndSettle();
      expect(find.text('Transcribe again'), findsOneWidget);

      recognizer
        ..failWith = null
        ..texts = <int, String>{0: 'हैलो'};
      await tester.tap(find.text('Transcribe again'));
      await tester.pumpAndSettle();
      await runJob(tester, note);

      expect(find.text('हैलो'), findsOneWidget);
    });

    testWidgets('a finished transcript is not offered again', (tester) async {
      await _open(tester, recognizer: ScriptedRecognizer(), saved: _plain);

      await tester.tap(find.bySemanticsLabel('More'));
      await tester.pumpAndSettle();

      expect(find.text('Transcribe again'), findsNothing);
      expect(find.text('Delete note'), findsOneWidget);
    });

    testWidgets('model missing: says so plainly', (tester) async {
      final recognizer = ScriptedRecognizer();
      final note = await _open(
        tester,
        recognizer: recognizer,
        speechModelInstalled: false,
      );
      await tester.tap(find.bySemanticsLabel('Transcribe'));
      await runJob(tester, note);

      expect(find.text("The Hindi speech model isn't on this phone."),
          findsOneWidget);
      expect(recognizer.calls, 0);
      expectNoRawErrors();
    });
  });

  group('audio row', () {
    testWidgets('hidden while audio is never deleted', (tester) async {
      await _open(tester, saved: _plain);

      expect(find.textContaining('Audio deletes'), findsNothing);
      expect(find.bySemanticsLabel('Keep'), findsNothing);
    });

    testWidgets('with auto-delete on: time left, and Keep keeps it',
        (tester) async {
      final note = await _open(tester, saved: _plain, autoDelete: true);

      expect(find.text('Audio deletes in 18 h'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Keep'));
      await flush(tester);

      expect(note.harness.controller.keepAudioFor(note.info.path), isTrue);
      expect(find.text('Audio kept'), findsOneWidget);
      expect(find.textContaining('Audio deletes'), findsNothing);
    });

    testWidgets('kept: says so', (tester) async {
      await _open(tester, saved: _plain, autoDelete: true, keep: true);

      expect(find.text('Audio kept'), findsOneWidget);
    });

    testWidgets('audio deleted: transcript kept, and nothing to play',
        (tester) async {
      await _open(tester, saved: _plain, removeAudio: true);

      expect(find.text('Audio deleted · transcript kept'), findsOneWidget);
      expect(find.bySemanticsLabel('Show audio'), findsNothing);
      expect(find.text('ठीक है'), findsOneWidget);
    });
  });

  group('audio panel', () {
    testWidgets('the Audio button opens it and plays; the chevron closes and '
        'pauses', (tester) async {
      final note = await _open(tester, saved: _plain);

      await _openAudio(tester);
      expect(find.byType(NoteAudioPanel), findsOneWidget);
      expect(find.text('Summarize with your AI'), findsNothing);
      verify(() => note.player.load(note.info.path)).called(1);
      verify(() => note.player.play()).called(1);

      await note.emit(tester, isPlaying: true, position: const Duration(seconds: 10));
      expect(find.bySemanticsLabel('Pause'), findsOneWidget);
      expect(find.text('00:10'), findsOneWidget);
      expect(find.text('−04:02'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Hide audio'));
      await tester.pump();
      expect(find.byType(NoteAudioPanel), findsNothing);
      expect(find.text('Summarize with your AI'), findsOneWidget);
      verify(() => note.player.pause()).called(1);
    });

    testWidgets('play/pause follows the driver, not a local flag',
        (tester) async {
      final note = await _open(tester, saved: _plain);
      await _openAudio(tester);

      expect(find.bySemanticsLabel('Play'), findsOneWidget);
      await note.emit(tester, isPlaying: true, position: const Duration(seconds: 5));
      await tester.tap(find.bySemanticsLabel('Pause'));
      await tester.pump();
      verify(() => note.player.pause()).called(1);
      expect(find.bySemanticsLabel('Pause'), findsOneWidget);

      await note.emit(tester, isPlaying: false, position: const Duration(seconds: 5));
      expect(find.bySemanticsLabel('Play'), findsOneWidget);
    });

    testWidgets('skips seek from the real position and clamp', (tester) async {
      final note = await _open(tester, saved: _plain);
      await _openAudio(tester);

      await note.emit(tester, isPlaying: true, position: const Duration(seconds: 60));
      await tester.tap(find.bySemanticsLabel('Skip forward 30 seconds'));
      await tester.pump();
      verify(() => note.player.seek(const Duration(seconds: 90))).called(1);

      await tester.tap(find.bySemanticsLabel('Skip back 15 seconds'));
      await tester.pump();
      verify(() => note.player.seek(const Duration(seconds: 45))).called(1);

      await note.emit(tester, isPlaying: true, position: const Duration(seconds: 5));
      await tester.tap(find.bySemanticsLabel('Skip back 15 seconds'));
      await tester.pump();
      verify(() => note.player.seek(Duration.zero)).called(1);

      await note.emit(tester, isPlaying: true, position: const Duration(seconds: 240));
      await tester.tap(find.bySemanticsLabel('Skip forward 30 seconds'));
      await tester.pump();
      verify(() => note.player.seek(_length)).called(1);
    });

    testWidgets('tapping the waveform seeks', (tester) async {
      final note = await _open(tester, saved: _plain);
      await _openAudio(tester);

      final box = tester.getRect(find.byType(ScrubWaveform));
      await tester.tapAt(Offset(box.left + box.width * 0.75, box.center.dy));
      await tester.pump();

      verify(() => note.player.seek(const Duration(minutes: 3, seconds: 9)))
          .called(1);
    });

    testWidgets('the speed chip cycles and drives the player', (tester) async {
      final note = await _open(tester, saved: _plain);
      await _openAudio(tester);

      await tester.tap(find.text('1.0×'));
      await tester.pump();
      expect(find.text('1.5×'), findsOneWidget);
      verify(() => note.player.setSpeed(1.5)).called(1);
    });

    testWidgets('a file that will not load says so plainly', (tester) async {
      final fake = FakePlayback();
      when(() => fake.player.load(any()))
          .thenThrow(const AudioPlayerException('could not load the file'));
      await _open(tester, saved: _plain, fake: fake);
      await _openAudio(tester);
      await tester.pump();

      expect(find.text("Couldn't play this audio."), findsOneWidget);
      expect(find.textContaining('could not load'), findsNothing);
    });

    testWidgets('the playing paragraph is lit, and tapping one seeks there',
        (tester) async {
      final note = await _open(tester, saved: _plain);
      await _openAudio(tester);

      await note.emit(tester, isPlaying: true, position: const Duration(seconds: 44));
      expect(find.text('Playing'), findsOneWidget);

      await tester.tap(find.text('हाँ, सुनो'));
      await tester.pump();
      verify(() => note.player.seek(Duration.zero)).called(1);
    });

    testWidgets('tapping a paragraph with the panel closed opens it and plays '
        'from there', (tester) async {
      final note = await _open(tester, saved: _plain);

      await tester.tap(find.text('ठीक है'));
      await flush(tester);

      expect(find.byType(NoteAudioPanel), findsOneWidget);
      verify(() => note.player.load(note.info.path)).called(1);
      verify(() => note.player.seek(const Duration(seconds: 42))).called(1);
    });

    testWidgets('leaving the note stops what it played', (tester) async {
      final note = await _open(tester, saved: _plain);
      await _openAudio(tester);
      await note.emit(tester, isPlaying: true, position: const Duration(seconds: 3));

      await tester.pumpWidget(const SizedBox());
      await tester.pump();

      verify(() => note.player.stop()).called(1);
    });

    testWidgets('without a player there is no Audio button', (tester) async {
      await _open(tester, saved: _plain, withPlayer: false);

      expect(find.bySemanticsLabel('Show audio'), findsNothing);
    });

    testWidgets('every control clears the 44px minimum', (tester) async {
      await _open(tester, saved: _twoSpeakers, autoDelete: true);
      final labels = <String>[
        'Back',
        'More',
        'Rename speakers',
        'Keep',
        'Copy transcript',
        'Show audio',
      ];
      for (final label in labels) {
        final size = tester.getSize(find.bySemanticsLabel(label));
        expect(size.width, greaterThanOrEqualTo(44), reason: label);
        expect(size.height, greaterThanOrEqualTo(44), reason: label);
      }

      await _openAudio(tester);
      for (final label in <String>[
        'Skip back 15 seconds',
        'Play',
        'Skip forward 30 seconds',
        'Playback speed',
        'Hide audio',
      ]) {
        final size = tester.getSize(find.bySemanticsLabel(label));
        expect(size.width, greaterThanOrEqualTo(44), reason: label);
        expect(size.height, greaterThanOrEqualTo(44), reason: label);
      }
    });
  });

  group('following the playhead', () {
    final long = _transcript(<(int, String, String?)>[
      for (var i = 0; i < 30; i++)
        (i * 8, 'नमस्ते दोस्त मैं हूँ गुरु तुम्हारा नया दोस्त चलो आज हम कुछ '
            'नया सीखते हैं - $i', null),
    ]);

    double offset(WidgetTester tester) => tester
        .state<ScrollableState>(find.byType(Scrollable).last)
        .position
        .pixels;

    testWidgets('scrolls to the paragraph being heard', (tester) async {
      final note = await _open(tester, saved: long);
      await _openAudio(tester);
      expect(offset(tester), 0);

      await note.emit(tester, isPlaying: true, position: const Duration(seconds: 200));
      await tester.pumpAndSettle();

      expect(offset(tester), greaterThan(0));
    });

    testWidgets('leaves the transcript alone right after the user scrolls',
        (tester) async {
      final note = await _open(tester, saved: long);
      await _openAudio(tester);
      await note.emit(tester, isPlaying: true, position: Duration.zero);

      await tester.drag(find.text(long.segments[1].text), const Offset(0, -60));
      await tester.pumpAndSettle();
      final scrolled = offset(tester);

      await note.emit(tester, isPlaying: true, position: const Duration(seconds: 200));
      await tester.pumpAndSettle();
      expect(offset(tester), scrolled);

      // A few seconds later it follows again, from the next paragraph on.
      await tester.pump(NoteView.userScrollHold);
      await note.emit(tester, isPlaying: true, position: const Duration(seconds: 216));
      await tester.pumpAndSettle();
      expect(offset(tester), greaterThan(scrolled));
    });
  });

  group('delete', () {
    testWidgets('from the menu, confirmed, stops playback first and leaves',
        (tester) async {
      var left = false;
      final note = await _open(tester, saved: _plain, onDeleted: () => left = true);
      await _openAudio(tester);
      await note.emit(tester, isPlaying: true, position: const Duration(seconds: 30));

      await tester.tap(find.bySemanticsLabel('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete note'));
      await tester.pumpAndSettle();
      expect(find.text('Delete recording?'), findsOneWidget);
      expect(find.textContaining('09:14 · 4 min'), findsWidgets);

      await tester.tap(find.text('Delete'));
      await flush(tester);
      await tester.pumpAndSettle();

      verify(() => note.player.stop()).called(greaterThanOrEqualTo(1));
      expect(note.harness.controller.recordings, isEmpty);
      expect(note.harness.controller.nowPlaying, isNull);
      expect(left, isTrue);
    });

    testWidgets('Cancel deletes nothing', (tester) async {
      final note = await _open(tester, saved: _plain);

      await tester.tap(find.bySemanticsLabel('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete note'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(note.harness.controller.recordings, hasLength(1));
    });
  });
}
