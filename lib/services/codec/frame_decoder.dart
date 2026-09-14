import 'dart:typed_data';

import '../../model/audio_codec.dart';
import '../../model/audio_frame.dart';
import 'adpcm_decoder.dart';

/// One `fe01` frame to s16le PCM, for whichever codec the device reported.
///
/// Shared by the manual recorder and always-listening, so the two can never
/// decode the same stream two different ways.
abstract final class FrameDecoder {
  static Uint8List decode(AudioCodec codec, AudioFrame frame) {
    switch (codec) {
      case AudioCodec.pcmS16le:
        // Already s16le on the wire, merely split across notifications.
        return frame.payload;
      case AudioCodec.imaAdpcm:
        // One self-contained block per notification, so a dropped packet costs
        // exactly one block and never desyncs the decoder.
        return AdpcmDecoder.decodeBlockToPcmBytes(frame.payload);
    }
  }
}
