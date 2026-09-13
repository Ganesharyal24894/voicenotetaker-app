import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'view/harness.dart';

/// Deleting a recording, at the layer that actually does it.
///
/// Two things here are not merely tidiness. Playback must stop BEFORE the file
/// is unlinked, because deleting a file out from under an open player is a
/// platform-level crash. And every in-memory reference to the deleted path has
/// to go with it: the app stores no sidecar metadata, so an orphan is a
/// controller field still pointing at a file that is no longer there.
void main() {
  setUpAll(registerViewFallbacks);

  test('the file and the library entry both go', () async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    final path = await harness.seedRecording();
    final info = harness.controller.recordings.single;

    await harness.controller.deleteRecording(info);

    expect(harness.fileStore.files, isNot(contains(path)));
    expect(harness.controller.recordings, isEmpty);
    expect(harness.controller.errorMessage, isNull);
  });

  test('only the recording asked for is deleted', () async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    await harness.seedRecording(at: DateTime(2026, 9, 10, 9, 14));
    final keep = await harness.seedRecording(at: DateTime(2026, 9, 10, 11, 30));
    final drop = harness.controller.recordings
        .firstWhere((r) => r.recordedAt.hour == 9);

    await harness.controller.deleteRecording(drop);

    expect(harness.controller.recordings.single.path, keep);
    expect(harness.fileStore.files.keys, <String>[keep]);
  });

  test('the list is republished at once, not on the next refresh', () async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    await harness.seedRecording();
    final info = harness.controller.recordings.single;

    var notifications = 0;
    harness.controller.addListener(() => notifications++);

    await harness.controller.deleteRecording(info);

    expect(notifications, greaterThan(0));
    // Read straight off the controller, with no refreshLibrary() in between.
    expect(harness.controller.recordings, isEmpty);
  });

  test('deleting the recording being played stops the player FIRST', () async {
    final playback = FakePlayback();
    addTearDown(playback.close);
    final harness = ViewHarness(audioPlayer: playback.player);
    addTearDown(harness.dispose);
    await harness.controller.initialise();
    final path = await harness.seedRecording();
    final info = harness.controller.recordings.single;

    await harness.controller.playRecording(info);
    expect(harness.controller.nowPlaying?.path, path);

    await harness.controller.deleteRecording(info);

    verifyInOrder(<Future<void> Function()>[
      () => playback.player.load(path),
      () => playback.player.play(),
      () => playback.player.stop(),
    ]);
    // Nothing is left claiming to be playing a file that no longer exists.
    expect(harness.controller.nowPlaying, isNull);
    expect(harness.controller.isPlaying, isFalse);
    expect(harness.controller.playbackState.position, Duration.zero);
    expect(harness.controller.playbackError, isNull);
    expect(harness.fileStore.files, isNot(contains(path)));
  });

  test('deleting a recording that is NOT playing leaves the player alone',
      () async {
    final playback = FakePlayback();
    addTearDown(playback.close);
    final harness = ViewHarness(audioPlayer: playback.player);
    addTearDown(harness.dispose);
    await harness.controller.initialise();
    final playing = await harness.seedRecording(at: DateTime(2026, 9, 10, 9, 14));
    await harness.seedRecording(at: DateTime(2026, 9, 10, 11, 30));

    final keep =
        harness.controller.recordings.firstWhere((r) => r.path == playing);
    final drop =
        harness.controller.recordings.firstWhere((r) => r.path != playing);

    await harness.controller.playRecording(keep);
    await harness.controller.deleteRecording(drop);

    verifyNever(() => playback.player.stop());
    expect(harness.controller.nowPlaying?.path, playing);
  });

  test('a deleted capture is dropped from lastRecording too', () async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    await harness.controller.connect(knownDevice);
    await harness.controller.startRecording();
    await harness.controller.stopRecording();

    final last = harness.controller.lastRecording;
    expect(last, isNotNull, reason: 'the capture should have been recorded');
    final info = harness.controller.recordings
        .firstWhere((r) => r.path == last!.path);

    await harness.controller.deleteRecording(info);

    // The orphan this prevents: `lastRecording` still describing a file that
    // has been unlinked, which the developer screen and RecordingEntry read.
    expect(harness.controller.lastRecording, isNull);
    expect(harness.controller.recordings, isEmpty);
  });

  test('a capture that was NOT deleted stays in lastRecording', () async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    await harness.seedRecording(at: DateTime(2026, 9, 10, 9, 14));
    await harness.controller.connect(knownDevice);
    await harness.controller.startRecording();
    await harness.controller.stopRecording();

    final last = harness.controller.lastRecording;
    final other = harness.controller.recordings
        .firstWhere((r) => r.path != last!.path);

    await harness.controller.deleteRecording(other);

    expect(harness.controller.lastRecording?.path, last?.path);
  });

  test('a delete that fails says so, names the recording, and keeps the list',
      () async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    final path = await harness.seedRecording();
    final info = harness.controller.recordings.single;
    harness.fileStore.undeletable.add(path);

    await harness.controller.deleteRecording(info);

    expect(harness.controller.errorMessage, isNotNull);
    expect(harness.controller.errorMessage, contains(info.name));
    // The file is still there, so the row must be too - the list may not claim
    // a deletion that did not happen.
    expect(harness.fileStore.files, contains(path));
    expect(harness.controller.recordings, hasLength(1));
  });
}
