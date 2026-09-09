import 'dart:typed_data';

/// One BLE notification after its 2-byte sequence header has been stripped.
class AudioFrame {
  const AudioFrame({
    required this.sequence,
    required this.payload,
    required this.droppedBefore,
  });

  /// Little-endian uint16 sequence number carried by the notification.
  final int sequence;

  /// Notification bytes after the sequence header.
  final Uint8List payload;

  /// How many packets the link dropped immediately before this one, derived
  /// from the (wrap-aware) sequence gap. Zero when the stream is contiguous.
  final int droppedBefore;

  bool get hasGap => droppedBefore > 0;

  @override
  String toString() => 'AudioFrame(seq: $sequence, '
      '${payload.length} bytes, droppedBefore: $droppedBefore)';
}
