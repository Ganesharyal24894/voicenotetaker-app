import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/audio_codec.dart';
import 'package:voicenotetaker_app/services/continuous/continuous_session.dart';
import 'package:voicenotetaker_app/services/recording_service.dart';

import '../view/harness.dart';
import 'decoder_rig.dart';

/// Who opens a decoder, and who closes it. An Opus decoder holds native memory
/// and the previous frame's state, so each of the places that read `fe01` must
/// open one per stream and release it when the stream ends - and a new stream,
/// possibly in a different codec, must never inherit the old one. When opening
/// or starting fails, and the mic check: `decoder_refusal_test.dart`.
void main() {
  setUpAll(registerViewFallbacks);

  late DecoderRig rig;
  setUp(() => rig = DecoderRig());
  tearDown(() => rig.dispose());

  group('the manual recorder', () {
    late RecordingService recorder;

    setUp(() {
      recorder = RecordingService(
        transport: rig.transport,
        fileStore: rig.files,
        decoders: rig.decoders,
      );
    });
    tearDown(() => recorder.dispose());

    test('opens one decoder per capture and closes it on stop', () async {
      await recorder.start(deviceId: rig.deviceId, path: '/r/a.wav');
      expect(rig.opus.opened, hasLength(1));
      expect(rig.opus.leaked, hasLength(1));
      await recorder.stop();
      expect(rig.opus.leaked, isEmpty);
    });

    test('closes it on abort as well', () async {
      await recorder.start(deviceId: rig.deviceId, path: '/r/a.wav');
      await recorder.abort();
      expect(rig.opus.leaked, isEmpty);
    });

    test('decodes Opus into the WAV, 640 bytes a frame', () async {
      await recorder.start(deviceId: rig.deviceId, path: '/r/a.wav');
      rig.frames.add(rig.packet(0, 3));
      rig.frames.add(rig.packet(1, 4));
      await pumpEventQueue();
      final meta = await recorder.stop();
      expect(meta.stats.decodedBytes, 2 * 640);
    });

    test('a sequence gap is concealed, so the note keeps its length', () async {
      await recorder.start(deviceId: rig.deviceId, path: '/r/a.wav');
      rig.frames.add(rig.packet(0, 3));
      rig.frames.add(rig.packet(2, 4)); // packet 1 was lost on the link
      await pumpEventQueue();
      final meta = await recorder.stop();
      expect(meta.stats.decodedBytes, 3 * 640);
    });

    test('switching codec between captures gets a fresh decoder, never the '
        'old one', () async {
      await recorder.start(deviceId: rig.deviceId, path: '/r/a.wav');
      await recorder.stop();
      await recorder.start(
        deviceId: rig.deviceId,
        path: '/r/b.wav',
        requestCodec: AudioCodec.imaAdpcm,
      );
      // ADPCM needs no native decoder; the Opus one is closed, not reused.
      expect(rig.opus.opened, hasLength(1));
      expect(rig.opus.leaked, isEmpty);
      await recorder.stop();

      await recorder.start(
        deviceId: rig.deviceId,
        path: '/r/c.wav',
        requestCodec: AudioCodec.opusCelt,
      );
      expect(rig.opus.opened, hasLength(2));
      expect(identical(rig.opus.opened[0], rig.opus.opened[1]), isFalse);
      await recorder.stop();
      expect(rig.opus.leaked, isEmpty);
    });

    test(
      'a build without libopus refuses Opus rather than record silence',
      () async {
        final bare = RecordingService(
          transport: rig.transport,
          fileStore: rig.files,
        );
        addTearDown(bare.dispose);
        await expectLater(
          bare.start(deviceId: rig.deviceId, path: '/r/a.wav'),
          throwsA(isA<RecordingException>()),
        );
        expect(bare.isRecording, isFalse);
      },
    );
  });

  group('always listening', () {
    late ContinuousSession session;

    setUp(() {
      session = ContinuousSession(
        transport: rig.transport,
        fileStore: rig.files,
        directory: '/r',
        keepaliveInterval: const Duration(hours: 1),
        decoders: rig.decoders,
      );
    });
    tearDown(() => session.dispose());

    test('opens one decoder per session and closes it on stop', () async {
      await session.start(rig.deviceId);
      expect(rig.opus.leaked, hasLength(1));
      await session.stop(linkUp: true);
      expect(rig.opus.leaked, isEmpty);
    });

    test('a dropped link closes it too', () async {
      await session.start(rig.deviceId);
      await session.stop(linkUp: false);
      expect(rig.opus.leaked, isEmpty);
    });

    test('decodes Opus and hands the PCM to the note', () async {
      await session.start(rig.deviceId);
      rig.frames.add(rig.packet(0, 3));
      await pumpEventQueue();
      await session.idle;
      expect(rig.opus.opened.single.calls, hasLength(1));
      // 640 bytes of PCM - the packet's 320 samples - landed in the note.
      final note = rig.files.files.entries.singleWhere(
        (e) => e.key.startsWith('/r/') && e.key.endsWith('.wav'),
      );
      expect(note.value.length, 44 + 640);
    });

    test(
      'a new session in another codec does not inherit the old decoder',
      () async {
        await session.start(rig.deviceId);
        await session.stop(linkUp: true);
        await session.start(rig.deviceId, requestCodec: AudioCodec.imaAdpcm);
        expect(rig.opus.opened, hasLength(1));
        expect(rig.opus.leaked, isEmpty);
        await session.stop(linkUp: true);
      },
    );

    test('a build without libopus refuses to start rather than record an '
        'empty day', () async {
      final bare = ContinuousSession(
        transport: rig.transport,
        fileStore: rig.files,
        directory: '/r',
      );
      addTearDown(bare.dispose);
      await expectLater(
        bare.start(rig.deviceId),
        throwsA(isA<ContinuousSessionException>()),
      );
      expect(bare.isRunning, isFalse);
    });
  });
}
