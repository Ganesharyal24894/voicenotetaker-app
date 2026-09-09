import 'stream_info.dart';

/// Link-level counters for a capture in progress or just finished.
///
/// Packet loss is tracked separately from audio quality so the two are never
/// confused: a gap here is a dropped BLE packet, not a codec artefact.
class CaptureStats {
  const CaptureStats({
    this.framesReceived = 0,
    this.framesLost = 0,
    this.malformedFrames = 0,
    this.wireBytes = 0,
    this.decodedBytes = 0,
  });

  final int framesReceived;
  final int framesLost;

  /// Notifications too short to carry a sequence header.
  final int malformedFrames;

  /// Bytes actually received over the air, sequence headers included.
  final int wireBytes;

  /// Bytes of decoded PCM handed to the file store.
  final int decodedBytes;

  int get framesExpected => framesReceived + framesLost;

  /// Fraction of expected packets that never arrived, in `0.0 .. 1.0`.
  double get lossRatio =>
      framesExpected == 0 ? 0.0 : framesLost / framesExpected;

  CaptureStats copyWith({
    int? framesReceived,
    int? framesLost,
    int? malformedFrames,
    int? wireBytes,
    int? decodedBytes,
  }) =>
      CaptureStats(
        framesReceived: framesReceived ?? this.framesReceived,
        framesLost: framesLost ?? this.framesLost,
        malformedFrames: malformedFrames ?? this.malformedFrames,
        wireBytes: wireBytes ?? this.wireBytes,
        decodedBytes: decodedBytes ?? this.decodedBytes,
      );

  @override
  String toString() => 'CaptureStats(received: $framesReceived, '
      'lost: $framesLost, malformed: $malformedFrames, '
      'wire: $wireBytes B, decoded: $decodedBytes B)';
}

/// Everything known about a finished recording.
class RecordingMetadata {
  const RecordingMetadata({
    required this.path,
    required this.startedAt,
    required this.endedAt,
    required this.streamInfo,
    required this.stats,
  });

  /// Path of the written WAV file.
  final String path;
  final DateTime startedAt;
  final DateTime endedAt;
  final StreamInfo streamInfo;
  final CaptureStats stats;

  /// Wall-clock length of the capture session.
  Duration get wallClockDuration => endedAt.difference(startedAt);

  /// Length of the audio actually written, derived from the decoded byte count.
  Duration get audioDuration {
    final byteRate = streamInfo.decodedByteRate;
    if (byteRate <= 0) return Duration.zero;
    return Duration(
      microseconds: (stats.decodedBytes * 1000000 / byteRate).round(),
    );
  }

  @override
  String toString() =>
      'RecordingMetadata($path, ${audioDuration.inMilliseconds} ms, $stats)';
}
