import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/drivers/ble_transport.dart';
import 'package:voicenotetaker_app/model/audio_codec.dart';
import 'package:voicenotetaker_app/model/capture_flags.dart';
import 'package:voicenotetaker_app/model/stream_info.dart';
import 'package:voicenotetaker_app/services/continuous/continuous_session.dart';
import 'package:voicenotetaker_app/services/continuous/note_writer.dart';
import 'package:voicenotetaker_app/services/wav_reader.dart';

import '../view/harness.dart';

/// Always-listening on one link, against the fake radio: what is written to
/// the device, what is kept alive, and what reaches the disk.
void main() {
  setUpAll(registerViewFallbacks);

  const deviceId = 'EB:6B:5E:4C:33:A3';
  const dir = ViewHarness.recordingsDirectory;

  late ViewHarness harness;
  late ContinuousSession session;
  var sequence = 0;

  setUp(() {
    harness = ViewHarness();
    sequence = 0;
    session = ContinuousSession(
      transport: harness.transport,
      fileStore: harness.fileStore,
      directory: dir,
      keepaliveInterval: const Duration(milliseconds: 20),
    );
  });

  tearDown(() async {
    await session.dispose();
    await harness.dispose();
  });

  /// [seconds] of raw PCM in 20 ms notifications, as the device streams it.
  Future<void> speak(double seconds) async {
    for (var i = 0; i < (seconds * 50).round(); i++) {
      final notification = Uint8List(2 + 640)..fillRange(2, 642, 5);
      notification[0] = sequence & 0xFF;
      notification[1] = (sequence >> 8) & 0xFF;
      sequence++;
      harness.frames.add(notification);
    }
    await pumpEventQueue();
    await session.idle;
  }

  List<String> notes() => harness.fileStore.files.keys
      .where((p) => p.startsWith('$dir/') && p.endsWith('.wav'))
      .toList();

  test('starting asks for speech only and follows fe01 and fe08', () async {
    await session.start(deviceId, requestCodec: AudioCodec.imaAdpcm);

    verifyInOrder(<void Function()>[
      () => harness.transport.selectCodec(deviceId, AudioCodec.imaAdpcm),
      () => harness.transport.readStreamInfo(deviceId),
      () => harness.transport.writeCapture(deviceId, CaptureCommand.gateEnabled),
      () => harness.transport.readCapture(deviceId),
    ]);
    verify(() => harness.transport.subscribeCapture(deviceId)).called(1);
    verify(() => harness.transport.subscribeFrames(deviceId)).called(1);
    expect(session.isRunning, isTrue);
    expect(session.flags, harness.captureFlags);
  });

  test('speech becomes a note, closed and kept when the session stops',
      () async {
    final changes = <NoteChange>[];
    session.notes.listen(changes.add);
    await session.start(deviceId);

    await speak(3);
    expect(session.currentNotePath, isNotNull);

    await session.stop(linkUp: true);
    await pumpEventQueue();

    final path = notes().single;
    final header =
        WavReader.parse(Uint8List.fromList(harness.fileStore.files[path]!))!;
    expect(header.dataLength, 3 * 32000);
    expect(changes.map((c) => c.kind),
        <NoteChangeKind>[NoteChangeKind.started, NoteChangeKind.finished]);
    expect(session.currentNotePath, isNull);
  });

  test('a double tap into privacy mode ends the note there', () async {
    await session.start(deviceId);
    await speak(3);

    // Both the notification AND the fe08 read, because a real device answers
    // the keep-alive with the state it just announced. Setting only the
    // notification leaves the next keep-alive tick -- 20 ms away here --
    // reading the old flags back over the new ones, which is a race
    // this test loses on a busy machine and wins on an idle one.
    const privacyMode =
        CaptureFlags(privacyMode: true, speechOpen: false, gateEnabled: true);
    harness.captureFlags = privacyMode;
    harness.capture.add(privacyMode);
    await pumpEventQueue();
    await session.idle;

    expect(session.currentNotePath, isNull);
    expect(session.flags!.privacyMode, isTrue);
    expect(notes(), hasLength(1));
  });

  test('the recorder deciding it is worn neither ends the note nor hides '
      'a double tap into privacy mode', () async {
    await session.start(deviceId);
    await speak(3);

    const worn = CaptureFlags(
      privacyMode: false,
      speechOpen: true,
      gateEnabled: true,
      wear: WearState.worn,
    );
    harness.captureFlags = worn;
    harness.capture.add(worn);
    await pumpEventQueue();
    await session.idle;
    expect(session.flags, worn);
    expect(session.currentNotePath, isNotNull);

    const privacyMode = CaptureFlags(
      privacyMode: true,
      speechOpen: false,
      gateEnabled: true,
      wear: WearState.worn,
    );
    harness.captureFlags = privacyMode;
    harness.capture.add(privacyMode);
    await pumpEventQueue();
    await session.idle;

    expect(session.currentNotePath, isNull);
    expect(session.flags!.privacyMode, isTrue);
    expect(notes(), hasLength(1));
  });

  test('the keep-alive reads fe08 every interval', () async {
    await session.start(deviceId);
    clearInteractions(harness.transport);

    await Future<void>.delayed(const Duration(milliseconds: 90));

    verify(() => harness.transport.readCapture(deviceId))
        .called(greaterThanOrEqualTo(3));
  });

  test('stopping with the link up restores the device default', () async {
    await session.start(deviceId);
    await session.stop(linkUp: true);

    verify(() => harness.transport.unsubscribeFrames(deviceId)).called(1);
    verify(() => harness.transport.unsubscribeCapture(deviceId)).called(1);
    verify(() =>
            harness.transport.writeCapture(deviceId, CaptureCommand.gateDisabled))
        .called(1);
    clearInteractions(harness.transport);

    // Nothing keeps running afterwards.
    await Future<void>.delayed(const Duration(milliseconds: 60));
    verifyNever(() => harness.transport.readCapture(any()));
  });

  test('stopping after the link dropped says nothing to the radio', () async {
    await session.start(deviceId);
    clearInteractions(harness.transport);

    await session.stop(linkUp: false);

    verifyNever(() => harness.transport.writeCapture(any(), any()));
    verifyNever(() => harness.transport.unsubscribeFrames(any()));
  });

  test('a device that refuses speech-only leaves nothing running', () async {
    when(() => harness.transport.writeCapture(any(), any()))
        .thenThrow(const BleTransportException('no fe08'));

    await expectLater(
      session.start(deviceId),
      throwsA(isA<ContinuousSessionException>()),
    );
    expect(session.isRunning, isFalse);
    verifyNever(() => harness.transport.subscribeFrames(any()));
  });

  test('audio this app cannot write is refused before anything starts',
      () async {
    when(() => harness.transport.readStreamInfo(any())).thenAnswer(
      (_) async => const StreamInfo(
        sampleRateHz: 16000,
        bitsPerSample: 24,
        channels: 1,
        codec: AudioCodec.pcmS16le,
      ),
    );

    await expectLater(
      session.start(deviceId),
      throwsA(isA<ContinuousSessionException>()),
    );
    verifyNever(() => harness.transport.writeCapture(any(), any()));
  });
}
