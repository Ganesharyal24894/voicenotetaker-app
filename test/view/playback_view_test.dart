import 'dart:async';

import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/drivers/audio_player.dart';
import 'package:voicenotetaker_app/model/recording_info.dart';
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
}) async {
  final playback = fake ?? FakePlayback();
  addTearDown(playback.close);
  final harness = ViewHarness(audioPlayer: withPlayer ? playback.player : null);
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

  testWidgets('the speed chip cycles', (tester) async {
    await _open(tester);

    await tester.tap(find.text('1.0×'));
    await tester.pump();
    expect(find.text('1.5×'), findsOneWidget);
  });

  testWidgets('transcription is a placeholder and says so', (tester) async {
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
}
