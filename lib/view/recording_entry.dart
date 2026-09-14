import '../model/recording_info.dart';
import '../model/recording_metadata.dart';
import '../model/transcript.dart';
import 'format.dart';

/// One row in the recordings lists, as Home hands it to the note screen.
///
/// A view-layer projection: the lists need a title, a
/// timestamp, a length and a size in one object, and no service produces that
/// shape yet. [RecordingEntry.fromMetadata] maps the one real thing the app
/// can produce today - the recording the controller just finished - into it.
class RecordingEntry {
  const RecordingEntry({
    required this.title,
    required this.recordedAt,
    required this.duration,
    required this.sizeBytes,
    this.path,
    this.sampleRateHz = 16000,
    this.channels = 1,
    this.isPlaceholder = false,
    this.isWriting = false,
    this.statusLabel,
  });

  /// Built from a real, finished capture.
  factory RecordingEntry.fromMetadata(RecordingMetadata metadata) {
    return RecordingEntry(
      title: 'Voice note ${Fmt.timeOfDay(metadata.startedAt)}',
      recordedAt: metadata.startedAt,
      duration: metadata.audioDuration,
      // 44 bytes of RIFF header on top of the decoded payload.
      sizeBytes: metadata.stats.decodedBytes + 44,
      path: metadata.path,
      sampleRateHz: metadata.streamInfo.sampleRateHz,
      channels: metadata.streamInfo.channels,
    );
  }

  /// Built from a saved file the library service described.
  ///
  /// [isWriting] marks the note always-listening is still writing, and
  /// [transcript] is what the list says about its transcript - see
  /// [statusLabelFor].
  factory RecordingEntry.fromInfo(
    RecordingInfo info, {
    bool isWriting = false,
    TranscriptStatus? transcript,
  }) {
    return RecordingEntry(
      title: 'Voice note ${Fmt.timeOfDay(info.recordedAt)}',
      recordedAt: info.recordedAt,
      // A file whose header will not parse has no length; it still has to be
      // listed, so it shows as 0:00 rather than being hidden.
      duration: info.duration ?? Duration.zero,
      sizeBytes: info.sizeBytes,
      path: info.path,
      sampleRateHz: info.sampleRateHz ?? 16000,
      channels: info.channels ?? 1,
      isWriting: isWriting,
      statusLabel: statusLabelFor(isWriting: isWriting, transcript: transcript),
    );
  }

  /// The short word the recordings list puts after a row's size, or null for
  /// nothing.
  ///
  /// "Writing" wins: a note that is still growing has no transcript to speak
  /// of yet. States with nothing useful to say - not looked at, none, no
  /// model - say nothing, so an ordinary list is not a wall of labels.
  static String? statusLabelFor({
    required bool isWriting,
    TranscriptStatus? transcript,
  }) {
    if (isWriting) return 'Writing…';
    return switch (transcript) {
      TranscriptStatus.done => 'Transcribed',
      TranscriptStatus.noSpeech => 'No speech',
      TranscriptStatus.running => 'Transcribing',
      TranscriptStatus.queued => 'Waiting',
      TranscriptStatus.failed ||
      TranscriptStatus.unsupported =>
        'Not transcribed',
      TranscriptStatus.checking ||
      TranscriptStatus.none ||
      TranscriptStatus.modelMissing ||
      null =>
        null,
    };
  }

  final String title;
  final DateTime recordedAt;
  final Duration duration;
  final int sizeBytes;

  /// Absolute path of the WAV file, when this entry describes a real one.
  final String? path;

  final int sampleRateHz;
  final int channels;

  /// True for the sample rows that stand in until a library service exists.
  final bool isPlaceholder;

  /// True while always-listening is still writing this note. It cannot be
  /// deleted until it is finished.
  final bool isWriting;

  /// Writing / transcript state for the list, or null for none.
  final String? statusLabel;

  /// `09:14`.
  String get timeLabel => Fmt.timeOfDay(recordedAt);

  /// `4:12`.
  String get durationLabel => Fmt.duration(duration);

  /// `7.9 MB`.
  String get sizeLabel => Fmt.bytes(sizeBytes);

  /// `Today` / `Yesterday` / `Mon`.
  String dayLabel({DateTime? now}) => Fmt.day(recordedAt, now: now);

  /// `Today, 09:14 - 4:12` for the Home list.
  String recentLabel({DateTime? now}) =>
      '${Fmt.dayAndTime(recordedAt, now: now)} · $durationLabel';

  /// `09:14 - 4:12 - 7.9 MB` for the Library rows.
  String libraryLabel() => statusLabel == null
      ? '$timeLabel · $durationLabel · $sizeLabel'
      : '$timeLabel · $durationLabel · $sizeLabel · $statusLabel';

  /// `Today, 09:14 - 16 kHz mono - 7.9 MB` for the playback header.
  String playbackLabel({DateTime? now}) =>
      '${Fmt.dayAndTime(recordedAt, now: now)} · '
      '${Fmt.streamSummary(sampleRateHz, channels)} · $sizeLabel';
}
