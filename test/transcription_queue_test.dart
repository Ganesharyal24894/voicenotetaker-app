import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/recording_info.dart';
import 'package:voicenotetaker_app/services/transcription/transcription_queue.dart';

/// Which recordings the background queue transcribes, and in what order.
void main() {
  RecordingInfo rec(
    String name,
    int hour, {
    bool transcribed = false,
    bool failed = false,
    bool hasAudio = true,
  }) =>
      RecordingInfo(
        path: '/r/$name.wav',
        name: '$name.wav',
        recordedAt: DateTime(2026, 9, 14, hour),
        sizeBytes: 100,
        hasTranscript: transcribed,
        transcriptFailed: failed,
        hasAudio: hasAudio,
      );

  group('plan', () {
    test('newest first, transcribed and failed ones skipped', () {
      final plan = TranscriptionQueue.plan(
        recordings: <RecordingInfo>[
          rec('a', 8),
          rec('b', 11, transcribed: true),
          rec('c', 10),
          rec('d', 9, failed: true),
          rec('e', 12),
        ],
      );
      expect(plan, <String>['/r/e.wav', '/r/c.wav', '/r/a.wav']);
    });

    test('a note whose audio was removed is never queued', () {
      final plan = TranscriptionQueue.plan(
        recordings: <RecordingInfo>[rec('a', 8), rec('b', 9, hasAudio: false)],
      );
      expect(plan, <String>['/r/a.wav']);
    });

    test('the note being written and the job running are left out', () {
      final plan = TranscriptionQueue.plan(
        recordings: <RecordingInfo>[rec('a', 8), rec('b', 9), rec('c', 10)],
        writing: '/r/c.wav',
        running: '/r/b.wav',
      );
      expect(plan, <String>['/r/a.wav']);
    });

    test('failures known only in memory are left out too', () {
      final plan = TranscriptionQueue.plan(
        recordings: <RecordingInfo>[rec('a', 8), rec('b', 9)],
        failed: <String>{'/r/b.wav'},
      );
      expect(plan, <String>['/r/a.wav']);
    });
  });

  test('prioritise moves a waiting recording to the front only', () {
    final queue = TranscriptionQueue()..replace(<String>['x', 'y', 'z']);

    expect(queue.prioritise('z'), isTrue);
    expect(queue.pending, <String>['z', 'x', 'y']);
    expect(queue.prioritise('nope'), isFalse);
    expect(queue.pending, <String>['z', 'x', 'y']);
  });

  test('replacing keeps what the user put at the front there', () {
    final queue = TranscriptionQueue()
      ..replace(<String>['x', 'y', 'z'])
      ..prioritise('y');

    queue.replace(<String>['w', 'x', 'y', 'z']);

    expect(queue.pending, <String>['y', 'w', 'x', 'z']);
  });

  test('addFront adds or moves', () {
    final queue = TranscriptionQueue()..replace(<String>['x', 'y']);
    queue
      ..addFront('new')
      ..addFront('y');
    expect(queue.pending, <String>['y', 'new', 'x']);
  });

  test('takeNext passes over the note being written without dropping it', () {
    final queue = TranscriptionQueue()..replace(<String>['w', 'x']);

    expect(queue.takeNext(skip: 'w'), 'x');
    expect(queue.pending, <String>['w']);
    expect(queue.takeNext(skip: 'w'), isNull);
    expect(queue.takeNext(), 'w');
    expect(queue.isEmpty, isTrue);
  });
}
