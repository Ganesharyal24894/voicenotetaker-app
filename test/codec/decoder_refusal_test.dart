import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/drivers/ble_transport.dart';
import 'package:voicenotetaker_app/drivers/opus_library.dart';
import 'package:voicenotetaker_app/model/audio_codec.dart';
import 'package:voicenotetaker_app/services/codec/frame_decoder.dart';
import 'package:voicenotetaker_app/services/continuous/continuous_session.dart';
import 'package:voicenotetaker_app/services/device_test_service.dart';
import 'package:voicenotetaker_app/services/device_test_store.dart';
import 'package:voicenotetaker_app/services/recording_service.dart';

import '../view/harness.dart';
import 'decoder_rig.dart';

/// A stream that never properly starts must still give its decoder back, and a
/// codec this build cannot decode must be refused in each service's own terms
/// rather than recorded as silence. Plus the mic check, whose samples each
/// open and close a decoder of their own.
void main() {
  setUpAll(registerViewFallbacks);

  late DecoderRig rig;
  setUp(() => rig = DecoderRig());
  tearDown(() => rig.dispose());

  group('the manual recorder, when opening fails', () {
    test(
      'a file that cannot be opened closes the decoder it had opened',
      () async {
        final recorder = RecordingService(
          transport: rig.transport,
          fileStore: RefusingFileStore(),
          decoders: rig.decoders,
        );
        addTearDown(recorder.dispose);
        await expectLater(
          recorder.start(deviceId: rig.deviceId, path: '/r/a.wav'),
          throwsA(isA<StateError>()),
        );
        expect(rig.opus.opened, hasLength(1));
        expect(rig.opus.leaked, isEmpty);
      },
    );

    test('a format libopus refuses is a RecordingException', () async {
      rig.opus.refuseWith = const OpusException('bad arg', -1);
      final recorder = RecordingService(
        transport: rig.transport,
        fileStore: rig.files,
        decoders: rig.decoders,
      );
      addTearDown(recorder.dispose);
      await expectLater(
        recorder.start(deviceId: rig.deviceId, path: '/r/a.wav'),
        throwsA(isA<RecordingException>()),
      );
      expect(recorder.isRecording, isFalse);
    });
  });

  group('always listening, when starting fails', () {
    test(
      'a device refusing speech-only closes the decoder already opened',
      () async {
        when(() => rig.transport.writeCapture(any(), any()))
            .thenThrow(const BleTransportException('write failed'));
        final session = ContinuousSession(
          transport: rig.transport,
          fileStore: rig.files,
          directory: '/r',
          keepaliveInterval: const Duration(hours: 1),
          decoders: rig.decoders,
        );
        addTearDown(session.dispose);
        await expectLater(
          session.start(rig.deviceId),
          throwsA(isA<ContinuousSessionException>()),
        );
        expect(rig.opus.opened, hasLength(1));
        expect(rig.opus.leaked, isEmpty);
      },
    );
  });

  group('the mic check', () {
    DeviceTestService build(FrameDecoders with_) => DeviceTestService(
      transport: rig.transport,
      store: DeviceTestStore(fileStore: rig.files, directory: '/r'),
      noiseFloorWindow: const Duration(milliseconds: 30),
      sensitivityWindow: const Duration(milliseconds: 30),
      tick: const Duration(milliseconds: 10),
      decoders: with_,
    );

    test('each sample opens a decoder and closes it', () async {
      final tests = build(rig.decoders);
      addTearDown(tests.dispose);
      await tests.runNoiseFloor(
        deviceId: rig.deviceId,
        requestCodec: AudioCodec.opusCelt,
        repeats: 2,
      );
      expect(rig.opus.opened, isNotEmpty);
      expect(rig.opus.leaked, isEmpty);
    });

    test(
      'a refused frame subscription closes the decoder it had opened',
      () async {
        when(() => rig.transport.subscribeFrames(any()))
            .thenThrow(const BleTransportException('already subscribed'));
        final tests = build(rig.decoders);
        addTearDown(tests.dispose);
        await tests.runNoiseFloor(
          deviceId: rig.deviceId,
          requestCodec: AudioCodec.opusCelt,
        );
        expect(rig.opus.opened, hasLength(1));
        expect(rig.opus.leaked, isEmpty);
      },
    );

    test('a format libopus refuses is reported, not thrown', () async {
      rig.opus.refuseWith = const OpusException('bad arg', -1);
      final tests = build(rig.decoders);
      addTearDown(tests.dispose);
      final result = await tests.runNoiseFloor(
        deviceId: rig.deviceId,
        requestCodec: AudioCodec.opusCelt,
      );
      expect(result?.note, contains('cannot decode'));
    });

    test(
      'without libopus, Opus is reported undecodable, not measured',
      () async {
        final tests = build(const FrameDecoders());
        addTearDown(tests.dispose);
        final result = await tests.runNoiseFloor(
          deviceId: rig.deviceId,
          requestCodec: AudioCodec.opusCelt,
        );
        expect(result?.note, contains('cannot decode'));
        expect(rig.opus.opened, isEmpty);
      },
    );
  });
}
