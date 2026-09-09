import 'dart:typed_data';

import '../model/audio_frame.dart';
import '../model/device_profile.dart';
import '../model/recording_metadata.dart';

/// Strips the 2-byte little-endian sequence header from each notification and
/// turns gaps in that sequence into a packet-loss count.
///
/// The sequence number is 16-bit and wraps: after 0xFFFF the device sends
/// 0x0000. Gap arithmetic is therefore done modulo 0x10000, so a wrap is a gap
/// of zero, not a gap of 65535.
///
/// Loss counted here is loss on the *link*. It is reported separately from
/// audio quality so a bad radio environment is never mistaken for a bad codec.
class FrameReassembler {
  FrameReassembler();

  static const int _sequenceModulus = 0x10000;

  int? _expected;
  int _received = 0;
  int _lost = 0;
  int _malformed = 0;
  int _wireBytes = 0;

  /// Sequence number the next in-order notification should carry, or `null`
  /// before the first valid notification has arrived.
  int? get expectedSequence => _expected;

  int get framesReceived => _received;
  int get framesLost => _lost;
  int get malformedFrames => _malformed;
  int get wireBytes => _wireBytes;

  /// Total packets the device is believed to have sent.
  int get framesExpected => _received + _lost;

  /// Fraction of expected packets that never arrived, in `0.0 .. 1.0`.
  double get lossRatio => framesExpected == 0 ? 0.0 : _lost / framesExpected;

  /// Snapshot of the counters, minus the decoded-byte total which only the
  /// recording service knows.
  CaptureStats get stats => CaptureStats(
        framesReceived: _received,
        framesLost: _lost,
        malformedFrames: _malformed,
        wireBytes: _wireBytes,
      );

  /// Accepts one raw notification.
  ///
  /// Returns the frame with its header stripped, or `null` when the
  /// notification was too short to carry a sequence header (counted in
  /// [malformedFrames] and otherwise ignored - it must not be allowed to
  /// poison the expected-sequence tracking).
  AudioFrame? accept(Uint8List notification) {
    _wireBytes += notification.length;

    if (notification.length < DeviceProfile.sequenceHeaderBytes) {
      _malformed++;
      return null;
    }

    final sequence = ByteData.sublistView(
      notification,
      0,
      DeviceProfile.sequenceHeaderBytes,
    ).getUint16(0, Endian.little);

    var droppedBefore = 0;
    final expected = _expected;
    if (expected != null && sequence != expected) {
      // Wrap-aware difference: (seq - expected) mod 65536.
      droppedBefore = (sequence - expected) % _sequenceModulus;
      _lost += droppedBefore;
    }
    _expected = (sequence + 1) % _sequenceModulus;
    _received++;

    return AudioFrame(
      sequence: sequence,
      payload: Uint8List.sublistView(
        notification,
        DeviceProfile.sequenceHeaderBytes,
      ),
      droppedBefore: droppedBefore,
    );
  }

  /// Clears counters and sequence tracking, ready for a new capture.
  void reset() {
    _expected = null;
    _received = 0;
    _lost = 0;
    _malformed = 0;
    _wireBytes = 0;
  }
}
