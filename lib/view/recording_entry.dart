import '../model/recording_metadata.dart';
import 'format.dart';

/// One row in the recordings lists, and the subject of the playback screen.
///
/// A view-layer projection: the library and playback screens need a title, a
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
  String libraryLabel() =>
      '$timeLabel · $durationLabel · $sizeLabel';

  /// `Today, 09:14 - 16 kHz mono - 7.9 MB` for the playback header.
  String playbackLabel({DateTime? now}) =>
      '${Fmt.dayAndTime(recordedAt, now: now)} · '
      '${Fmt.streamSummary(sampleRateHz, channels)} · $sizeLabel';
}
