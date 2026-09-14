import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/recording_info.dart';
import 'package:voicenotetaker_app/model/transcript.dart';
import 'package:voicenotetaker_app/view/recording_entry.dart';

/// The word after a library row's size: writing, and where its transcript is.
void main() {
  test('writing wins over any transcript state', () {
    expect(
      RecordingEntry.statusLabelFor(
        isWriting: true,
        transcript: TranscriptStatus.done,
      ),
      'Writing…',
    );
  });

  test('each transcript state has a short word, or none', () {
    String? label(TranscriptStatus? status) =>
        RecordingEntry.statusLabelFor(isWriting: false, transcript: status);

    expect(label(TranscriptStatus.done), 'Transcribed');
    expect(label(TranscriptStatus.noSpeech), 'No speech');
    expect(label(TranscriptStatus.running), 'Transcribing');
    expect(label(TranscriptStatus.queued), 'Waiting');
    expect(label(TranscriptStatus.failed), 'Not transcribed');
    expect(label(TranscriptStatus.unsupported), 'Not transcribed');
    expect(label(TranscriptStatus.none), isNull);
    expect(label(TranscriptStatus.checking), isNull);
    expect(label(TranscriptStatus.modelMissing), isNull);
    expect(label(null), isNull);
  });

  test('the library row carries the word only when there is one', () {
    final info = RecordingInfo(
      path: '/r/voicenote-20260914-091400.wav',
      name: 'voicenote-20260914-091400.wav',
      recordedAt: DateTime(2026, 9, 14, 9, 14),
      sizeBytes: 1000044,
      duration: const Duration(minutes: 4, seconds: 12),
    );

    final plain = RecordingEntry.fromInfo(info);
    final writing = RecordingEntry.fromInfo(info, isWriting: true);

    expect(plain.libraryLabel(), isNot(contains('Writing')));
    expect(plain.isWriting, isFalse);
    expect(writing.libraryLabel(), endsWith(' · Writing…'));
    expect(writing.isWriting, isTrue);
  });
}
