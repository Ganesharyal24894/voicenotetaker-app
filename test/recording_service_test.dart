import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/drivers/ble_transport.dart';
import 'package:voicenotetaker_app/drivers/file_store.dart';
import 'package:voicenotetaker_app/model/audio_codec.dart';
import 'package:voicenotetaker_app/model/stream_info.dart';
import 'package:voicenotetaker_app/services/codec/adpcm_decoder.dart';
import 'package:voicenotetaker_app/services/recording_service.dart';

class MockBleTransport extends Mock implements BleTransport {}

/// In-memory [FileStore]. Hand-written rather than mocked because these tests
/// care about the bytes that land in the file, header patches included.
class InMemoryFileStore implements FileStore {
  final Map<String, MemoryFileSink> sinks = <String, MemoryFileSink>{};
  final Map<String, Uint8List> files = <String, Uint8List>{};

  @override
  Future<FileSink> openWrite(String path) async {
    final sink = MemoryFileSink();
    sinks[path] = sink;
    files.remove(path);
    return sink;
  }

  @override
  Future<FileSink> openAppend(String path) async =>
      throw UnimplementedError('the recorder never appends');

  @override
  Future<void> move(String from, String to) async =>
      throw UnimplementedError('the recorder never moves a file');

  @override
  Future<Uint8List> read(String path) async {
    final sink = sinks[path];
    if (sink != null) return sink.snapshot();
    final file = files[path];
    if (file != null) return file;
    throw StateError('no such file: $path');
  }

  @override
  Future<Uint8List> readRange(String path, int start, int end) async {
    final bytes = await read(path);
    final from = start.clamp(0, bytes.length);
    final to = end.clamp(from, bytes.length);
    return Uint8List.sublistView(bytes, from, to);
  }

  @override
  Future<FileInfo?> stat(String path) async {
    if (!await exists(path)) return null;
    return FileInfo(
      path: path,
      sizeBytes: (await read(path)).length,
      modifiedAt: DateTime(2026, 9, 10, 14, 30),
    );
  }

  @override
  Future<void> writeBytes(String path, List<int> bytes) async {
    files[path] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> patchBytes(String path, int offset, List<int> bytes) async =>
      files[path]!.setRange(offset, offset + bytes.length, bytes);

  @override
  Future<bool> exists(String path) async =>
      files.containsKey(path) || sinks.containsKey(path);

  @override
  Future<void> delete(String path) async {
    files.remove(path);
    sinks.remove(path);
  }

  @override
  Future<List<String>> list(String directory) async =>
      <String>{...files.keys, ...sinks.keys}
          .where((p) => p.startsWith('$directory/'))
          .toList()
        ..sort();

  @override
  String join(String directory, String name) => '$directory/$name';
}

/// Mirrors the real sink contract: [add] appends, [patch] overwrites bytes
/// already appended without moving the append cursor.
class MemoryFileSink implements FileSink {
  final List<int> _bytes = <int>[];
  bool closed = false;

  @override
  int get bytesWritten => _bytes.length;

  Uint8List snapshot() => Uint8List.fromList(_bytes);

  @override
  Future<void> add(List<int> bytes) async => _bytes.addAll(bytes);

  @override
  Future<void> patch(int offset, List<int> bytes) async {
    while (_bytes.length < offset + bytes.length) {
      _bytes.add(0);
    }
    for (var i = 0; i < bytes.length; i++) {
      _bytes[offset + i] = bytes[i];
    }
  }

  @override
  Future<void> close() async => closed = true;
}

/// One BLE notification: 2-byte little-endian sequence header + payload.
Uint8List notification(int sequence, List<int> payload) {
  final bytes = Uint8List(2 + payload.length);
  ByteData.sublistView(bytes).setUint16(0, sequence, Endian.little);
  bytes.setRange(2, bytes.length, payload);
  return bytes;
}

/// A minimal but real ADPCM block: header + one payload byte.
Uint8List adpcmBlock(int predictor, int index, List<int> payloadBytes) {
  final bytes = Uint8List(4 + payloadBytes.length);
  ByteData.sublistView(bytes)
    ..setInt16(0, predictor, Endian.little)
    ..setUint8(2, index)
    ..setUint8(3, 0);
  bytes.setRange(4, bytes.length, payloadBytes);
  return bytes;
}

const StreamInfo adpcmInfo = StreamInfo(
  sampleRateHz: 16000,
  bitsPerSample: 16,
  channels: 1,
  codec: AudioCodec.imaAdpcm,
  rawCodec: 1,
);

const StreamInfo pcmInfo = StreamInfo(
  sampleRateHz: 16000,
  bitsPerSample: 16,
  channels: 1,
  codec: AudioCodec.pcmS16le,
  rawCodec: 0,
);

void main() {
  setUpAllForMocktail();

  late MockBleTransport transport;
  late InMemoryFileStore fileStore;
  late StreamController<Uint8List> frames;
  late RecordingService service;

  const deviceId = 'AA:BB:CC:DD:EE:FF';
  const path = '/recordings/voicenote.wav';

  void stubTransport({StreamInfo info = adpcmInfo}) {
    when(() => transport.readStreamInfo(deviceId)).thenAnswer((_) async => info);
    when(() => transport.selectCodec(any(), any())).thenAnswer((_) async {});
    when(() => transport.subscribeFrames(deviceId))
        .thenAnswer((_) => frames.stream);
    when(() => transport.unsubscribeFrames(deviceId)).thenAnswer((_) async {});
  }

  setUp(() {
    transport = MockBleTransport();
    fileStore = InMemoryFileStore();
    frames = StreamController<Uint8List>();
    service = RecordingService(transport: transport, fileStore: fileStore);
    stubTransport();
  });

  tearDown(() async {
    await service.dispose();
    // Not awaited: closing a single-subscription controller that was never
    // listened to (the tests where start() throws) never completes.
    if (!frames.isClosed) unawaited(frames.close());
  });

  /// Lets the notification handler's queued writes settle.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('start', () {
    test('writes a provisional 44-byte WAV header immediately', () async {
      await service.start(deviceId: deviceId, path: path);
      expect(service.isRecording, isTrue);
      expect(fileStore.sinks[path]!.bytesWritten, 44);
    });

    test('requests the codec before reading the stream info back', () async {
      await service.start(
        deviceId: deviceId,
        path: path,
        requestCodec: AudioCodec.imaAdpcm,
      );
      verifyInOrder([
        () => transport.selectCodec(deviceId, AudioCodec.imaAdpcm),
        () => transport.readStreamInfo(deviceId),
      ]);
    });

    test('does not touch the control characteristic when no codec is asked for',
        () async {
      await service.start(deviceId: deviceId, path: path);
      verifyNever(() => transport.selectCodec(any(), any()));
    });

    test('the device-reported codec wins over the requested one', () async {
      // Request ADPCM, device answers PCM: the payload must be passed through
      // untouched rather than run through the ADPCM decoder.
      stubTransport(info: pcmInfo);
      await service.start(
        deviceId: deviceId,
        path: path,
        requestCodec: AudioCodec.imaAdpcm,
      );
      frames.add(notification(0, const [0x11, 0x22, 0x33, 0x44]));
      await settle();
      final meta = await service.stop();

      expect(meta.streamInfo.codec, AudioCodec.pcmS16le);
      final file = await fileStore.read(path);
      expect(file.sublist(44), equals(Uint8List.fromList([0x11, 0x22, 0x33, 0x44])));
    });

    test('falls back to 16k/16/mono when the info read fails', () async {
      when(() => transport.readStreamInfo(deviceId))
          .thenThrow(const BleTransportException('read failed'));
      await service.start(deviceId: deviceId, path: path);
      expect(service.streamInfo, StreamInfo.fallback);
      expect(service.streamInfo!.codec, AudioCodec.pcmS16le);
    });

    test('rejects a codec this build does not know', () async {
      stubTransport(
        info: const StreamInfo(
          sampleRateHz: 16000,
          bitsPerSample: 16,
          channels: 1,
          codec: null,
          rawCodec: 9,
        ),
      );
      await expectLater(
        service.start(deviceId: deviceId, path: path),
        throwsA(isA<RecordingException>()),
      );
      expect(service.isRecording, isFalse);
    });

    test('rejects a bit depth other than 16', () async {
      stubTransport(
        info: const StreamInfo(
          sampleRateHz: 16000,
          bitsPerSample: 8,
          channels: 1,
          codec: AudioCodec.pcmS16le,
          rawCodec: 0,
        ),
      );
      await expectLater(
        service.start(deviceId: deviceId, path: path),
        throwsA(isA<RecordingException>()),
      );
    });

    test('refuses to start twice', () async {
      await service.start(deviceId: deviceId, path: path);
      await expectLater(
        service.start(deviceId: deviceId, path: path),
        throwsA(isA<RecordingException>()),
      );
    });
  });

  group('capture and decode', () {
    test('ADPCM notifications are decoded into the file', () async {
      final block = adpcmBlock(0, 0, const [0x71, 0x35]);
      await service.start(deviceId: deviceId, path: path);
      frames.add(notification(0, block));
      await settle();
      await service.stop();

      final file = await fileStore.read(path);
      expect(
        file.sublist(44),
        equals(AdpcmDecoder.decodeBlockToPcmBytes(block)),
      );
    });

    test('each ADPCM notification decodes from its own header', () async {
      // Same nibbles, different headers: if the decoder carried state across
      // notifications the second block would come out wrong.
      final a = adpcmBlock(0, 0, const [0x5A, 0x3C]);
      final b = adpcmBlock(-5000, 40, const [0x5A, 0x3C]);
      await service.start(deviceId: deviceId, path: path);
      frames..add(notification(0, a))..add(notification(1, b));
      await settle();
      await service.stop();

      final expected = <int>[
        ...AdpcmDecoder.decodeBlockToPcmBytes(a),
        ...AdpcmDecoder.decodeBlockToPcmBytes(b),
      ];
      expect((await fileStore.read(path)).sublist(44), equals(expected));
    });

    test('raw PCM notifications are concatenated verbatim', () async {
      stubTransport(info: pcmInfo);
      await service.start(deviceId: deviceId, path: path);
      frames
        ..add(notification(0, const [1, 2, 3, 4]))
        ..add(notification(1, const [5, 6, 7, 8]));
      await settle();
      await service.stop();

      expect(
        (await fileStore.read(path)).sublist(44),
        equals(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8])),
      );
    });

    test('a dropped packet costs one block, not the rest of the stream',
        () async {
      final block = adpcmBlock(0, 0, const [0x71]);
      await service.start(deviceId: deviceId, path: path);
      // seq 0, then seq 2: packet 1 never arrived.
      frames..add(notification(0, block))..add(notification(2, block));
      await settle();
      final meta = await service.stop();

      expect(meta.stats.framesReceived, 2);
      expect(meta.stats.framesLost, 1);
      expect(meta.stats.lossRatio, closeTo(1 / 3, 1e-12));
      // Both surviving blocks still decoded, and identically.
      final audio = (await fileStore.read(path)).sublist(44);
      expect(audio.sublist(0, 4), equals(audio.sublist(4, 8)));
    });

    test('a malformed notification is counted and skipped', () async {
      await service.start(deviceId: deviceId, path: path);
      frames
        ..add(notification(0, adpcmBlock(0, 0, const [0x71])))
        ..add(Uint8List.fromList([0x01]));
      await settle();
      final meta = await service.stop();

      expect(meta.stats.malformedFrames, 1);
      expect(meta.stats.framesReceived, 1);
    });

    test('stats are pushed as frames arrive', () async {
      final seen = <int>[];
      final sub = service.stats.listen((s) => seen.add(s.framesReceived));
      await service.start(deviceId: deviceId, path: path);
      frames
        ..add(notification(0, adpcmBlock(0, 0, const [0x71])))
        ..add(notification(1, adpcmBlock(0, 0, const [0x71])));
      await settle();
      await sub.cancel();
      expect(seen, containsAllInOrder(<int>[1, 2]));
    });
  });

  group('stop', () {
    test('patches both WAV length fields with the decoded byte count',
        () async {
      stubTransport(info: pcmInfo);
      await service.start(deviceId: deviceId, path: path);
      frames.add(notification(0, List<int>.filled(100, 0x7F)));
      await settle();
      final meta = await service.stop();

      final file = await fileStore.read(path);
      final view = ByteData.sublistView(file);
      expect(file.length, 144);
      expect(view.getUint32(40, Endian.little), 100);
      expect(view.getUint32(4, Endian.little), 136);
      expect(meta.stats.decodedBytes, 100);
    });

    test('the file is a valid RIFF/WAVE with the device format', () async {
      await service.start(deviceId: deviceId, path: path);
      frames.add(notification(0, adpcmBlock(0, 0, const [0x71])));
      await settle();
      await service.stop();

      final file = await fileStore.read(path);
      final view = ByteData.sublistView(file);
      expect(const AsciiDecoder().convert(file.sublist(0, 4)), 'RIFF');
      expect(const AsciiDecoder().convert(file.sublist(8, 12)), 'WAVE');
      expect(view.getUint32(24, Endian.little), 16000);
      expect(view.getUint16(22, Endian.little), 1);
      expect(view.getUint16(34, Endian.little), 16);
    });

    test('unsubscribes from the characteristic', () async {
      await service.start(deviceId: deviceId, path: path);
      await service.stop();
      verify(() => transport.unsubscribeFrames(deviceId)).called(1);
      expect(fileStore.sinks[path]!.closed, isTrue);
    });

    test('returns metadata with a duration derived from the byte count',
        () async {
      stubTransport(info: pcmInfo);
      await service.start(deviceId: deviceId, path: path);
      // 32000 bytes at 16 kHz / 16-bit / mono is exactly one second.
      frames.add(notification(0, List<int>.filled(32000, 0)));
      await settle();
      final meta = await service.stop();

      expect(meta.path, path);
      expect(meta.audioDuration, const Duration(seconds: 1));
      expect(meta.streamInfo, pcmInfo);
    });

    test('finishes the file even when unsubscribing fails', () async {
      stubTransport(info: pcmInfo);
      when(() => transport.unsubscribeFrames(deviceId))
          .thenThrow(const BleTransportException('link already gone'));

      await service.start(deviceId: deviceId, path: path);
      frames.add(notification(0, const [1, 2]));
      await settle();
      final meta = await service.stop();

      expect(meta.stats.decodedBytes, 2);
      expect((await fileStore.read(path)).length, 46);
    });

    test('surfaces a stream error raised during capture', () async {
      await service.start(deviceId: deviceId, path: path);
      frames.addError(const BleTransportException('notification failed'));
      await settle();
      await expectLater(service.stop(), throwsA(isA<RecordingException>()));
      // The file was still finalised before the error was rethrown.
      expect(fileStore.sinks[path]!.closed, isTrue);
    });

    test('surfaces a file write failure', () async {
      // A failed disk write must not be swallowed: writes are fired without
      // awaiting, so the error has to be captured and reported from stop().
      final failing = FailingFileStore();
      final svc = RecordingService(transport: transport, fileStore: failing);
      await svc.start(deviceId: deviceId, path: path);
      frames.add(notification(0, adpcmBlock(0, 0, const [0x71])));
      await settle();
      await expectLater(svc.stop(), throwsA(isA<RecordingException>()));
      await svc.dispose();
    });

    test('refuses to stop when nothing is running', () async {
      await expectLater(service.stop(), throwsA(isA<RecordingException>()));
    });

    test('a second start after stop resets the counters', () async {
      await service.start(deviceId: deviceId, path: path);
      frames.add(notification(5, adpcmBlock(0, 0, const [0x71])));
      await settle();
      await service.stop();

      final frames2 = StreamController<Uint8List>();
      when(() => transport.subscribeFrames(deviceId))
          .thenAnswer((_) => frames2.stream);
      await service.start(deviceId: deviceId, path: '/recordings/second.wav');
      expect(service.currentStats.framesReceived, 0);
      expect(service.currentStats.decodedBytes, 0);
      await service.stop();
      unawaited(frames2.close());
    });
  });

  group('the live level meter', () {
    /// PCM samples as one notification, the way codec 0 arrives on the wire.
    Uint8List pcmNotification(int sequence, List<int> samples) {
      final payload = Uint8List(samples.length * 2);
      final view = ByteData.sublistView(payload);
      for (var i = 0; i < samples.length; i++) {
        view.setInt16(i * 2, samples[i], Endian.little);
      }
      return notification(sequence, payload);
    }

    test('no audio means no level', () async {
      stubTransport(info: pcmInfo);
      await service.start(deviceId: deviceId, path: path);
      expect(service.level, isNull);
    });

    test('each decoded block is measured on its way to the file', () async {
      stubTransport(info: pcmInfo);
      final readings = <double>[];
      final subscription =
          service.levels.listen((r) => readings.add(r.peakDbfs));
      await service.start(deviceId: deviceId, path: path);

      frames.add(pcmNotification(0, <int>[32767, -32767, 32767, -32767]));
      await settle();
      expect(readings.single, closeTo(0, 0.01));
      expect(service.level!.peakSample, 32767);

      frames.add(pcmNotification(1, <int>[100, -100, 100, -100]));
      await settle();
      expect(readings, hasLength(2));
      expect(readings.last, lessThan(readings.first));

      await service.stop();
      await subscription.cancel();
    });

    test('silence reads the floor rather than nothing at all', () async {
      stubTransport(info: pcmInfo);
      await service.start(deviceId: deviceId, path: path);

      frames.add(pcmNotification(0, List<int>.filled(160, 0)));
      await settle();

      expect(service.level!.peakDbfs, -96);
      await service.stop();
    });

    test('a decoded ADPCM block is measured too', () async {
      await service.start(deviceId: deviceId, path: path);

      frames.add(notification(0, adpcmBlock(0, 0, <int>[0x77, 0x77])));
      await settle();

      expect(service.level, isNotNull);
      expect(service.level!.sampleCount, 4);
      await service.stop();
    });

    test('a malformed notification never reaches the meter', () async {
      await service.start(deviceId: deviceId, path: path);

      // One byte: too short to carry a sequence header, so no frame and no
      // samples - and above all no division by an empty block.
      frames.add(Uint8List.fromList(<int>[0x01]));
      await settle();

      expect(service.level, isNull);
      await service.stop();
    });

    test('a new capture starts from no level', () async {
      stubTransport(info: pcmInfo);
      await service.start(deviceId: deviceId, path: path);
      frames.add(pcmNotification(0, <int>[1000, -1000]));
      await settle();
      expect(service.level, isNotNull);
      await service.stop();

      final frames2 = StreamController<Uint8List>();
      when(() => transport.subscribeFrames(deviceId))
          .thenAnswer((_) => frames2.stream);
      await service.start(deviceId: deviceId, path: '/recordings/second.wav');
      expect(service.level, isNull);
      await service.stop();
      unawaited(frames2.close());
    });
  });

  group('abort', () {
    test('stops capture without throwing and never finalises', () async {
      await service.start(deviceId: deviceId, path: path);
      await service.abort();
      expect(service.isRecording, isFalse);
      await expectLater(service.stop(), throwsA(isA<RecordingException>()));
    });

    test('is safe when nothing is running', () async {
      await expectLater(service.abort(), completes);
    });
  });
}

/// Store whose sink fails on the first payload write (the WAV header goes
/// through so the capture can start).
class FailingFileStore extends InMemoryFileStore {
  @override
  Future<FileSink> openWrite(String path) async => FailingFileSink();
}

class FailingFileSink extends MemoryFileSink {
  int _adds = 0;

  @override
  Future<void> add(List<int> bytes) async {
    if (_adds++ > 0) throw StateError('disk full');
    return super.add(bytes);
  }
}

/// Mocktail needs a fallback instance for any enum used with `any()`.
void setUpAllForMocktail() {
  setUpAll(() {
    registerFallbackValue(AudioCodec.pcmS16le);
  });
}
