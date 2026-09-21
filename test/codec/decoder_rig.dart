import 'dart:async';
import 'dart:typed_data';

import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/drivers/file_store.dart';
import 'package:voicenotetaker_app/model/audio_codec.dart';
import 'package:voicenotetaker_app/model/capture_flags.dart';
import 'package:voicenotetaker_app/model/die_temperature.dart';
import 'package:voicenotetaker_app/model/stream_info.dart';
import 'package:voicenotetaker_app/services/codec/frame_decoder.dart';

import '../view/harness.dart';
import 'fake_opus.dart';

/// A fake recorder that reports whichever codec was last selected (Opus until
/// told otherwise), an in-memory disk, and a libopus that counts what it
/// opened - for the tests of who opens a stream's decoder and who closes it.
class DecoderRig {
  DecoderRig() {
    when(() => transport.selectCodec(any(), any())).thenAnswer((call) async {
      reported = call.positionalArguments[1] as AudioCodec;
    });
    when(() => transport.readStreamInfo(any())).thenAnswer(
      (_) async => StreamInfo(
        sampleRateHz: 16000,
        bitsPerSample: 16,
        channels: 1,
        codec: reported,
        rawCodec: reported.wireValue,
      ),
    );
    when(() => transport.subscribeFrames(any()))
        .thenAnswer((_) => frames.stream);
    when(() => transport.unsubscribeFrames(any())).thenAnswer((_) async {});
    when(() => transport.writeCapture(any(), any())).thenAnswer((_) async {});
    when(() => transport.readCapture(any())).thenAnswer(
      (_) async => const CaptureFlags(
        privacyMode: false,
        speechOpen: false,
        gateEnabled: true,
      ),
    );
    when(() => transport.subscribeCapture(any()))
        .thenAnswer((_) => const Stream<CaptureFlags>.empty());
    when(() => transport.unsubscribeCapture(any())).thenAnswer((_) async {});
    when(() => transport.readDieTemperature(any()))
        .thenAnswer((_) async => const DieTemperature(deciCelsius: 312));
  }

  final String deviceId = 'EB:6B:5E:4C:33:A3';

  final MockBleTransport transport = MockBleTransport();
  final MemoryFileStore files = MemoryFileStore();
  final StreamController<Uint8List> frames =
      StreamController<Uint8List>.broadcast();
  final FakeOpusLibrary opus = FakeOpusLibrary();
  late final FrameDecoders decoders = FrameDecoders(opus: opus);
  AudioCodec reported = AudioCodec.opusCelt;

  /// One notification: the 2-byte sequence header, then a fake Opus packet
  /// whose first byte the fake decoder turns into every sample.
  Uint8List packet(int sequence, int fill) =>
      Uint8List.fromList([sequence & 0xFF, sequence >> 8, fill, 0, 0]);

  Future<void> dispose() => frames.close();
}

/// A disk that will not open a file for writing.
class RefusingFileStore extends MemoryFileStore {
  @override
  Future<FileSink> openWrite(String path) async =>
      throw StateError('disk full');
}
