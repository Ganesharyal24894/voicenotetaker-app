/// One saved recording, as the library describes it.
///
/// Pure data. Everything here is read from the filesystem and the file's own
/// WAV header by `services/library_service.dart`; nothing is inferred.
class RecordingInfo {
  const RecordingInfo({
    required this.path,
    required this.name,
    required this.recordedAt,
    required this.sizeBytes,
    this.duration,
    this.sampleRateHz,
    this.channels,
    this.hasTranscript = false,
    this.transcriptFailed = false,
  });

  /// Absolute path of the WAV file.
  final String path;

  /// File name, extension included.
  final String name;

  /// When the recording was made.
  final DateTime recordedAt;

  /// Size of the file on disk, header included.
  final int sizeBytes;

  /// Length of the audio, read from the WAV header.
  ///
  /// `null` when the header is missing, truncated or malformed - a length is
  /// never estimated from the file size.
  final Duration? duration;

  /// Sample rate from the header, `null` when it could not be read.
  final int? sampleRateHz;

  /// Channel count from the header, `null` when it could not be read.
  final int? channels;

  /// Whether a saved transcript sits beside the file.
  final bool hasTranscript;

  /// Whether a transcription was tried and failed, and the failure was saved
  /// so the background queue passes this recording over.
  final bool transcriptFailed;

  @override
  String toString() => 'RecordingInfo($name, $sizeBytes B, '
      '${duration == null ? 'unknown' : '${duration!.inMilliseconds} ms'})';

  @override
  bool operator ==(Object other) =>
      other is RecordingInfo &&
      other.path == path &&
      other.name == name &&
      other.recordedAt == recordedAt &&
      other.sizeBytes == sizeBytes &&
      other.duration == duration &&
      other.sampleRateHz == sampleRateHz &&
      other.channels == channels &&
      other.hasTranscript == hasTranscript &&
      other.transcriptFailed == transcriptFailed;

  @override
  int get hashCode => Object.hash(
        path,
        name,
        recordedAt,
        sizeBytes,
        duration,
        sampleRateHz,
        channels,
        hasTranscript,
        transcriptFailed,
      );
}
