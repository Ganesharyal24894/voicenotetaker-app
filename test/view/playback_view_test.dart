import 'dart:async';

import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/drivers/audio_player.dart';
import 'package:voicenotetaker_app/model/recording_info.dart';
import 'package:voicenotetaker_app/model/transcript.dart';
import 'package:voicenotetaker_app/model/transcription.dart';
import 'package:voicenotetaker_app/services/transcription/transcript_store.dart';
import 'package:voicenotetaker_app/view/playback_view.dart';
import 'package:voicenotetaker_app/view/recording_entry.dart';
import 'package:voicenotetaker_app/view/widgets/waveform.dart';

import 'harness.dart';

/// The seeded recording's length: 4:12, the length the mock shows.
const Duration _length = Duration(minutes: 4, seconds: 12);

/// The screen under test, with the fake it is driven by.
class _Playback {
  _Playback({required this.harness, required this.fake, required this.info});

  final ViewHarness harness;
  final FakePlayback fake;

  /// The saved file the screen was opened on.
  final RecordingInfo info;

  MockAudioPlayer get player => fake.player;

  /// Reports a driver state for the loaded file, and lets the screen see it.
  ///
  /// Two pumps: one for the stream event to reach the controller, one for the
  /// frame the screen rebuilds in.
  Future<void> emit(
    WidgetTester tester, {
    required bool isPlaying,
    required Duration position,
    Duration? duration = _length,
  }) async {
    fake.emit(
      isPlaying: isPlaying,
      position: position,
      duration: duration,
      path: info.path,
    );
    await tester.pump();
    await tester.pump();
  }

  /// Fails the way the driver does, and lets the screen see it.
  Future<void> fail(WidgetTester tester, Object error) async {
    fake.fail(error);
    await tester.pump();
    await tester.pump();
  }
}

/// Seeds one real WAV file, opens the playback screen on it and returns both.
///
/// [withPlayer] false builds the controller with no playback driver at all -
/// `AppController.canPlay` is then false. [withFile] false opens the screen on
/// an entry that has no saved file behind it.
Future<_Playback> _open(
  WidgetTester tester, {
  bool withPlayer = true,
  bool withFile = true,
  FakePlayback? fake,
  VoidCallback? onDeleted,
  ScriptedRecognizer? recognizer,
  bool speechModelInstalled = true,
  Transcript? savedTranscript,
}) async {
  final playback = fake ?? FakePlayback();
  addTearDown(playback.close);
  final harness = ViewHarness(
    audioPlayer: withPlayer ? playback.player : null,
    recognizer: recognizer,
    speechModelInstalled: speechModelInstalled,
  );
  addTearDown(harness.dispose);

  // The playback subscription is opened by initialise(), exactly as main.dart
  // does it; without it nothing the driver reports would reach the screen.
  await harness.controller.initialise();

  // Anchored to today so the header's "Today, 09:14" is stable whenever the
  // suite runs.
  final now = DateTime.now();
  final path = await harness.seedRecording(
    at: DateTime(now.year, now.month, now.day, 9, 14),
    length: _length,
  );
  final info = harness.controller.recordings.firstWhere((r) => r.path == path);
  if (savedTranscript != null) {
    await TranscriptStore(fileStore: harness.fileStore)
        .save(path, savedTranscript);
  }

  await pumpScreen(
    tester,
    PlaybackView(
      controller: harness.controller,
      entry: RecordingEntry.fromInfo(info),
      recording: withFile ? info : null,
      onDeleted: onDeleted,
    ),
  );
  await tester.pump();

  return _Playback(harness: harness, fake: playback, info: info);
}

Rect _scrubber(WidgetTester tester) =>
    tester.getRect(find.byType(ScrubWaveform));

void main() {
  setUpAll(registerViewFallbacks);

  testWidgets('builds with title, metadata, scrubber and transport',
      (tester) async {
    await _open(tester);

    expect(find.text('Voice note 09:14'), findsOneWidget);
    expect(find.textContaining('Today, 09:14'), findsOneWidget);
    expect(find.textContaining('16 kHz mono'), findsOneWidget);
    expect(find.byType(ScrubWaveform), findsOneWidget);
    expect(find.text('15s'), findsOneWidget);
    expect(find.text('30s'), findsOneWidget);
    expect(find.text('1.0×'), findsOneWidget);
    expect(find.text('Transcribe'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('opening a recording loads that file and starts it',
      (tester) async {
    final screen = await _open(tester);

    verify(() => screen.player.load(screen.info.path)).called(1);
    verify(() => screen.player.play()).called(1);
    expect(screen.harness.controller.nowPlaying?.path, screen.info.path);
  });

  testWidgets('play/pause follows the driver, not a local flag',
      (tester) async {
    final screen = await _open(tester);

    // play() has been called, but nothing has reported playing yet, so the
    // screen must NOT be claiming it is playing.
    expect(find.bySemanticsLabel('Play'), findsOneWidget);
    expect(find.bySemanticsLabel('Pause'), findsNothing);

    await screen.emit(tester, isPlaying: true, position: const Duration(seconds: 10));
    await tester.pump();

    expect(find.bySemanticsLabel('Pause'), findsOneWidget);
    // Elapsed and remaining are the driver's position, not a local clock.
    expect(find.text('00:10'), findsOneWidget);
    expect(find.text('−04:02'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Pause'));
    await tester.pump();

    verify(() => screen.player.pause()).called(1);
    // Still Pause: the driver has not confirmed, so the screen does not
    // pretend on its own.
    expect(find.bySemanticsLabel('Pause'), findsOneWidget);

    await screen.emit(tester, isPlaying: false, position: const Duration(seconds: 10));
    await tester.pump();
    expect(find.bySemanticsLabel('Play'), findsOneWidget);
  });

  testWidgets('the scrubber follows the reported position', (tester) async {
    final screen = await _open(tester);

    await screen.emit(tester, isPlaying: true, position: const Duration(seconds: 126));
    await tester.pump();

    final scrubber = tester.widget<ScrubWaveform>(find.byType(ScrubWaveform));
    expect(scrubber.progress, closeTo(0.5, 0.001));
    expect(find.text('02:06'), findsOneWidget);
  });

  testWidgets('the 30s skip seeks forward from the real position',
      (tester) async {
    final screen = await _open(tester);
    await screen.emit(tester, isPlaying: true, position: const Duration(seconds: 60));
    await tester.pump();

    await tester.tap(find.bySemanticsLabel('Skip forward 30 seconds'));
    await tester.pump();

    verify(() => screen.player.seek(const Duration(seconds: 90))).called(1);
  });

  testWidgets('the 15s skip seeks back from the real position',
      (tester) async {
    final screen = await _open(tester);
    await screen.emit(tester, isPlaying: true, position: const Duration(seconds: 60));
    await tester.pump();

    await tester.tap(find.bySemanticsLabel('Skip back 15 seconds'));
    await tester.pump();

    verify(() => screen.player.seek(const Duration(seconds: 45))).called(1);
  });

  testWidgets('skipping back clamps at the start', (tester) async {
    final screen = await _open(tester);
    await screen.emit(tester, isPlaying: true, position: const Duration(seconds: 5));
    await tester.pump();

    await tester.tap(find.bySemanticsLabel('Skip back 15 seconds'));
    await tester.pump();

    verify(() => screen.player.seek(Duration.zero)).called(1);
  });

  testWidgets('skipping forward clamps at the duration', (tester) async {
    final screen = await _open(tester);
    await screen.emit(tester, isPlaying: true, position: const Duration(seconds: 240));
    await tester.pump();

    await tester.tap(find.bySemanticsLabel('Skip forward 30 seconds'));
    await tester.pump();

    verify(() => screen.player.seek(_length)).called(1);
  });

  testWidgets('tapping the waveform seeks to the position that implies',
      (tester) async {
    final screen = await _open(tester);

    final box = _scrubber(tester);
    await tester.tapAt(Offset(box.left + box.width * 0.75, box.center.dy));
    await tester.pump();

    // 75% of 4:12 is 3:09.
    verify(
      () => screen.player.seek(const Duration(minutes: 3, seconds: 9)),
    ).called(1);
  });

  testWidgets('dragging the waveform seeks', (tester) async {
    final screen = await _open(tester);

    final box = _scrubber(tester);
    final gesture = await tester.startGesture(
      Offset(box.left + box.width * 0.25, box.center.dy),
    );
    await gesture.moveTo(Offset(box.left + box.width * 0.5, box.center.dy));
    await gesture.up();
    await tester.pump();

    // Half of 4:12 is 2:06.
    verify(
      () => screen.player.seek(const Duration(minutes: 2, seconds: 6)),
    ).called(1);
  });

  testWidgets('completion is not shown as playing, and playing again restarts',
      (tester) async {
    final screen = await _open(tester);

    await screen.emit(tester, isPlaying: true, position: const Duration(seconds: 250));
    await tester.pump();
    expect(find.bySemanticsLabel('Pause'), findsOneWidget);

    // The driver pins the position at the duration and stops.
    await screen.emit(tester, isPlaying: false, position: _length);
    await tester.pump();

    expect(find.bySemanticsLabel('Play'), findsOneWidget);
    expect(find.bySemanticsLabel('Pause'), findsNothing);
    expect(find.text('04:12'), findsOneWidget);
    expect(find.text('−00:00'), findsOneWidget);

    // The opening play() is not what this asserts on.
    clearInteractions(screen.player);
    await tester.tap(find.bySemanticsLabel('Play'));
    await tester.pump();

    // The file is already loaded, so it is played again rather than reloaded;
    // restarting from the end is the driver's job.
    verify(() => screen.player.play()).called(1);
    verifyNever(() => screen.player.load(any()));
  });

  testWidgets('a file that will not load surfaces the error', (tester) async {
    final fake = FakePlayback();
    when(() => fake.player.load(any())).thenThrow(
      const AudioPlayerException('could not load the file'),
    );

    await _open(tester, fake: fake);

    expect(find.textContaining('could not load the file'), findsOneWidget);
    // It does not pretend it played.
    expect(find.bySemanticsLabel('Play'), findsOneWidget);
    expect(find.text('00:00'), findsOneWidget);
  });

  testWidgets('an error from the driver surfaces while playing',
      (tester) async {
    final screen = await _open(tester);
    await screen.emit(tester, isPlaying: true, position: const Duration(seconds: 10));
    await tester.pump();

    await screen.fail(tester, const AudioPlayerException('the platform gave up'));

    expect(find.textContaining('the platform gave up'), findsOneWidget);
  });

  testWidgets('a file that is still opening says so', (tester) async {
    final fake = FakePlayback();
    final opened = Completer<void>();
    when(() => fake.player.load(any())).thenAnswer((_) => opened.future);

    await _open(tester, fake: fake);
    expect(find.text('Loading…'), findsOneWidget);

    opened.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('Loading…'), findsNothing);
  });

  testWidgets('leaving the screen stops playback and leaves nothing running',
      (tester) async {
    final screen = await _open(tester);
    await screen.emit(tester, isPlaying: true, position: const Duration(seconds: 30));
    await tester.pump();

    // The screen is gone - popped, in the app.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    verify(() => screen.player.stop()).called(1);
    // Nothing left ticking: no leaked subscription, no animation.
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('without a playback driver the transport is visibly disabled',
      (tester) async {
    final handle = tester.ensureSemantics();
    final screen = await _open(tester, withPlayer: false);

    expect(
      find.text('Playback is unavailable on this build.'),
      findsOneWidget,
    );
    final play = tester.getSemantics(find.bySemanticsLabel('Play'));
    expect(play.flagsCollection.isEnabled, Tristate.isFalse);
    expect(
      tester.widget<ScrubWaveform>(find.byType(ScrubWaveform)).onSeek,
      isNull,
    );

    // And it really is dead, not just dim.
    await tester.tap(find.bySemanticsLabel('Play'), warnIfMissed: false);
    await tester.pump();
    expect(screen.harness.controller.nowPlaying, isNull);

    handle.dispose();
  });

  testWidgets('an entry with no file behind it cannot be played',
      (tester) async {
    final screen = await _open(tester, withFile: false);

    expect(find.text('This recording has no file to play.'), findsOneWidget);
    verifyNever(() => screen.player.load(any()));
    verifyNever(() => screen.player.play());
  });

  // The chip used to cycle its own label and nothing else: there was no
  // speed on the controller and none on the driver interface, so every
  // rate but 1.0x was a lie told by a button. These assert it reaches the
  // player, which is the part that was missing.
  testWidgets('the speed chip cycles AND drives the player', (tester) async {
    final fake = FakePlayback();
    final screen = await _open(tester, fake: fake);

    await tester.tap(find.text('1.0×'));
    await tester.pump();
    expect(find.text('1.5×'), findsOneWidget);
    verify(() => fake.player.setSpeed(1.5)).called(1);
    expect(screen.harness.controller.playbackSpeed, 1.5);

    await tester.tap(find.text('1.5×'));
    await tester.pump();
    expect(find.text('2.0×'), findsOneWidget);
    verify(() => fake.player.setSpeed(2.0)).called(1);

    // Wraps past the end of the list to the slow option.
    await tester.tap(find.text('2.0×'));
    await tester.pump();
    expect(find.text('0.5×'), findsOneWidget);
    verify(() => fake.player.setSpeed(0.5)).called(1);
  });

  testWidgets('the chosen rate survives opening another recording',
      (tester) async {
    final fake = FakePlayback();
    final screen = await _open(tester, fake: fake);

    await tester.tap(find.text('1.0×'));
    await tester.pump();
    expect(screen.harness.controller.playbackSpeed, 1.5);

    // A different file: the rate must be re-applied, not quietly reset.
    final other = RecordingInfo(
      path: '/tmp/another.wav',
      name: 'Another note',
      recordedAt: DateTime.now(),
      duration: const Duration(seconds: 30),
      sizeBytes: 1000,
    );
    await screen.harness.controller.playRecording(other);
    await tester.pump();

    verify(() => fake.player.setSpeed(1.5)).called(greaterThanOrEqualTo(1));
    expect(screen.harness.controller.playbackSpeed, 1.5);
  });

  testWidgets('a build without a speech engine says transcription is not '
      'available', (tester) async {
    await _open(tester);

    await tester.tap(find.text('Transcribe'));
    await tester.pump();

    expect(find.text('Transcription is not available yet.'), findsOneWidget);
  });

  testWidgets('every transport control clears the 44px minimum',
      (tester) async {
    await _open(tester);

    for (final label in <String>[
      'Skip back 15 seconds',
      'Play',
      'Skip forward 30 seconds',
      'Playback speed',
      'Transcribe',
      'Back to recordings',
    ]) {
      final size = tester.getSize(find.bySemanticsLabel(label));
      expect(size.width, greaterThanOrEqualTo(44), reason: label);
      expect(size.height, greaterThanOrEqualTo(44), reason: label);
    }
  });

  group('deleting from the playback screen', () {
    testWidgets('the action is offered for a recording with a file',
        (tester) async {
      await _open(tester);

      expect(find.bySemanticsLabel('Delete recording'), findsOneWidget);
      expect(find.bySemanticsLabel('More'), findsNothing);

      final size = tester.getSize(find.bySemanticsLabel('Delete recording'));
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));
    });

    testWidgets('an entry with no file behind it offers no delete',
        (tester) async {
      await _open(tester, withFile: false);

      expect(find.bySemanticsLabel('Delete recording'), findsNothing);
      expect(find.bySemanticsLabel('More'), findsOneWidget);
    });

    testWidgets('it confirms first, naming the recording', (tester) async {
      final playback = await _open(tester);

      await tester.tap(find.bySemanticsLabel('Delete recording'));
      await tester.pumpAndSettle();

      expect(find.text('Delete recording?'), findsOneWidget);
      expect(find.textContaining('Voice note 09:14'), findsWidgets);

      // Still there: the dialog has not been answered.
      expect(playback.harness.fileStore.files, contains(playback.info.path));
    });

    testWidgets('Cancel deletes nothing and stays on the screen',
        (tester) async {
      final playback = await _open(tester);

      await tester.tap(find.bySemanticsLabel('Delete recording'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(playback.harness.fileStore.files, contains(playback.info.path));
      expect(playback.harness.controller.recordings, hasLength(1));
      expect(find.bySemanticsLabel('Delete recording'), findsOneWidget);
    });

    testWidgets(
        'Delete stops playback BEFORE unlinking, removes the file and leaves',
        (tester) async {
      var left = false;
      final playback = await _open(tester, onDeleted: () => left = true);

      // Actually playing, which is the case that would crash the player if the
      // file went out from under it.
      await playback.emit(
        tester,
        isPlaying: true,
        position: const Duration(seconds: 30),
      );
      expect(playback.harness.controller.isPlaying, isTrue);

      await tester.tap(find.bySemanticsLabel('Delete recording'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await flush(tester);
      await tester.pumpAndSettle();

      // The player was stopped, not merely paused.
      verify(() => playback.player.stop()).called(greaterThanOrEqualTo(1));
      // The file is gone, and so is the library entry - no orphan.
      expect(
        playback.harness.fileStore.files,
        isNot(contains(playback.info.path)),
      );
      expect(playback.harness.controller.recordings, isEmpty);
      // And nothing still claims to be playing it.
      expect(playback.harness.controller.nowPlaying, isNull);
      expect(playback.harness.controller.isPlaying, isFalse);
      // The screen has nothing left to show, so it left.
      expect(left, isTrue);
    });
  });

  group('transcript', () {
    /// Pumps frames until the job is over, or [frames] have passed.
    Future<void> runJob(
      WidgetTester tester,
      _Playback screen, {
      int frames = 200,
    }) async {
      for (var i = 0; i < frames; i++) {
        await tester.pump();
        if (!screen.harness.controller.isTranscribing) break;
      }
      await tester.pump();
    }

    /// Raw failure text must never reach the screen.
    void expectNoRawErrors() {
      for (final raw in <String>[
        'Exception',
        'Error',
        'boom',
        'native',
        'onnx',
        '/tmp/',
      ]) {
        expect(find.textContaining(raw), findsNothing, reason: raw);
      }
    }

    const caption = 'HINDI TRANSCRIPT';

    testWidgets('idle: offers Transcribe and runs nothing by itself',
        (tester) async {
      final recognizer = ScriptedRecognizer();
      await _open(tester, recognizer: recognizer);
      await tester.pump();

      expect(find.bySemanticsLabel('Transcribe'), findsOneWidget);
      expect(find.text(caption), findsNothing);
      expect(recognizer.calls, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('running: shows progress and can be cancelled',
        (tester) async {
      // 4:12 is 32 windows; holding before window 8 is 25%.
      final recognizer = ScriptedRecognizer()
        ..gate = Completer<void>()
        ..holdBefore = 8;
      final screen = await _open(tester, recognizer: recognizer);

      await tester.tap(find.bySemanticsLabel('Transcribe'));
      for (var i = 0; i < 40; i++) {
        await tester.pump();
      }

      expect(find.text(caption), findsOneWidget);
      expect(find.text('Transcribing…'), findsOneWidget);
      expect(find.text('25%'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.bySemanticsLabel('Cancel'), findsOneWidget);
      // The chip has done its job; the card is where the transcript lives.
      expect(find.bySemanticsLabel('Transcribe'), findsNothing);
      expect(tester.takeException(), isNull);

      final cancel = tester.getSize(find.bySemanticsLabel('Cancel'));
      expect(cancel.height, greaterThanOrEqualTo(44));

      await tester.tap(find.bySemanticsLabel('Cancel'));
      // Cancelling a stream subscription completes on the real event loop,
      // not the tester's clock - the same as stopping a scan.
      await flush(tester);
      await runJob(tester, screen);

      expect(recognizer.cancelled, isTrue);
      expect(find.text(caption), findsNothing);
      expect(find.bySemanticsLabel('Transcribe'), findsOneWidget);
      expectNoRawErrors();
    });

    testWidgets('done: the Devanagari transcript is selectable and copyable',
        (tester) async {
      final recognizer = ScriptedRecognizer()
        ..texts = <int, String>{0: 'चेक चेक', 1: 'ठीक है'};
      final screen = await _open(tester, recognizer: recognizer);

      await tester.tap(find.bySemanticsLabel('Transcribe'));
      await runJob(tester, screen);

      expect(find.text(caption), findsOneWidget);
      final text = tester.widget<SelectableText>(find.byType(SelectableText));
      expect(text.data, 'चेक चेक ठीक है');
      expect(find.bySemanticsLabel('Transcribe'), findsNothing);

      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );

      await tester.tap(find.bySemanticsLabel('Copy'));
      await tester.pump();
      await tester.pump();

      expect(copied, 'चेक चेक ठीक है');
      expect(find.text('Copied.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a saved transcript is shown when the recording is opened '
        'again, without transcribing', (tester) async {
      final recognizer = ScriptedRecognizer();
      await _open(
        tester,
        recognizer: recognizer,
        savedTranscript: Transcript(
          languageCode: 'hi',
          modelId: SpeechModels.indicConformerHindiInt8.id,
          createdAt: DateTime(2026, 9, 14),
          audioDuration: _length,
          segments: const <TranscriptSegment>[
            TranscriptSegment(
              start: Duration.zero,
              end: Duration(seconds: 8),
              text: 'हैलो ओन टू थ्री',
            ),
          ],
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).data,
        'हैलो ओन टू थ्री',
      );
      expect(recognizer.calls, 0);
    });

    testWidgets('a short transcript leaves the speed row at the bottom',
        (tester) async {
      final recognizer = ScriptedRecognizer()..texts = <int, String>{0: 'हैलो'};
      final screen = await _open(tester, recognizer: recognizer);
      final before = tester.getRect(find.bySemanticsLabel('Playback speed'));

      await tester.tap(find.bySemanticsLabel('Transcribe'));
      await runJob(tester, screen);

      expect(find.byType(SelectableText), findsOneWidget);
      // The card takes room from the transport, never from the bottom row:
      // on the phone an earlier layout left half the screen empty below it.
      expect(
        tester.getRect(find.bySemanticsLabel('Playback speed')),
        before,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('empty: a recording with no speech says so', (tester) async {
      final screen = await _open(tester, recognizer: ScriptedRecognizer());

      await tester.tap(find.bySemanticsLabel('Transcribe'));
      await runJob(tester, screen);

      expect(find.text(caption), findsOneWidget);
      expect(find.text('No speech found.'), findsOneWidget);
      expect(find.byType(SelectableText), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('failed: a plain message and a way to try again',
        (tester) async {
      final recognizer = ScriptedRecognizer()
        ..failWith = StateError('native onnx boom');
      final screen = await _open(tester, recognizer: recognizer);

      await tester.tap(find.bySemanticsLabel('Transcribe'));
      await runJob(tester, screen);

      expect(find.text('Could not transcribe this recording.'), findsOneWidget);
      expect(find.bySemanticsLabel('Try again'), findsOneWidget);
      expectNoRawErrors();

      recognizer
        ..failWith = null
        ..texts = <int, String>{0: 'हैलो'};
      await tester.tap(find.bySemanticsLabel('Try again'));
      await runJob(tester, screen);

      expect(find.text('Could not transcribe this recording.'), findsNothing);
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).data,
        'हैलो',
      );
    });

    testWidgets('model missing: says so plainly and loads nothing',
        (tester) async {
      final recognizer = ScriptedRecognizer();
      final screen = await _open(
        tester,
        recognizer: recognizer,
        speechModelInstalled: false,
      );

      await tester.tap(find.bySemanticsLabel('Transcribe'));
      await runJob(tester, screen);

      expect(find.text('The Hindi model is not on this phone.'), findsOneWidget);
      expect(recognizer.calls, 0);
      expectNoRawErrors();
      expect(tester.takeException(), isNull);
    });

    testWidgets('a long transcript scrolls in its card and leaves the '
        'transport on screen', (tester) async {
      final recognizer = ScriptedRecognizer()
        ..texts = <int, String>{
          for (var i = 0; i < 32; i++)
            i: 'नमस्ते दोस्त मैं हूँ गुरु तुम्हारा नया दोस्त चलो आज हम कुछ नया सीखते हैं',
        };
      final screen = await _open(tester, recognizer: recognizer);

      await tester.tap(find.bySemanticsLabel('Transcribe'));
      await runJob(tester, screen);

      expect(tester.takeException(), isNull);
      final play = tester.getRect(find.bySemanticsLabel('Play'));
      expect(play.bottom, lessThanOrEqualTo(844));
      final card = tester.getRect(find.byType(SingleChildScrollView));
      expect(card.bottom, lessThanOrEqualTo(play.top));
    });

    testWidgets('while another recording is being transcribed, Transcribe '
        'says so instead of starting a second job', (tester) async {
      final recognizer = ScriptedRecognizer()..gate = Completer<void>();
      final screen = await _open(tester, recognizer: recognizer);
      final other = await screen.harness
          .seedRecording(at: DateTime(2026, 9, 1, 8, 0));
      final otherInfo = screen.harness.controller.recordings
          .firstWhere((r) => r.path == other);
      unawaited(screen.harness.controller.transcribe(otherInfo));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.bySemanticsLabel('Transcribe'));
      await tester.pump();

      expect(find.text('Another recording is being transcribed.'),
          findsOneWidget);
      expect(recognizer.calls, 1);

      final cancelled = screen.harness.controller.cancelTranscription();
      await flush(tester);
      await cancelled;
    });
  });
}
