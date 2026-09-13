import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/drivers/ble_transport.dart';
import 'package:voicenotetaker_app/model/audio_codec.dart';
import 'package:voicenotetaker_app/model/device_state.dart';
import 'package:voicenotetaker_app/model/device_test_result.dart';
import 'package:voicenotetaker_app/model/die_temperature.dart';
import 'package:voicenotetaker_app/model/stream_info.dart';
import 'package:voicenotetaker_app/services/device_test_service.dart';
import 'package:voicenotetaker_app/services/device_test_store.dart';

import 'view/harness.dart' show MemoryFileStore, MockBleTransport, knownDevice;

/// The mic check - noise floor and sensitivity - driven against a fake radio.
///
/// These are service tests, not widget tests, and deliberately: the interesting
/// behaviour is a sequence over time - open a notify stream, count for a window,
/// save - and a widget tester's fake clock is the wrong instrument for it. The
/// windows are injected in milliseconds so the whole file runs in a second.
///
/// THE RANGE WALK, THE LINK SOAK AND WAKE-ON-MOTION USED TO BE TESTED HERE. They
/// are gone: the first two are now the live Link view on the diagnostics screen,
/// which measures the same two quantities continuously, and the third reported a
/// figure dominated by the phone's own scan-discovery latency. See the library
/// comment of `model/device_test_result.dart`.
void main() {
  setUpAll(() {
    registerFallbackValue(AudioCodec.imaAdpcm);
  });

  late MockBleTransport transport;
  late MemoryFileStore files;
  late DeviceTestStore store;
  late StreamController<Uint8List> frames;
  late StreamController<BleConnectionStatus> link;
  late List<StreamController<DiscoveredDevice>> scans;
  late int frameSubscriptions;
  DeviceTestService? service;

  setUp(() {
    transport = MockBleTransport();
    files = MemoryFileStore();
    store = DeviceTestStore(fileStore: files, directory: '/recordings');
    frames = StreamController<Uint8List>.broadcast();
    link = StreamController<BleConnectionStatus>.broadcast();
    scans = <StreamController<DiscoveredDevice>>[];
    frameSubscriptions = 0;

    when(() => transport.selectCodec(any(), any())).thenAnswer((_) async {});
    when(() => transport.readStreamInfo(any()))
        .thenAnswer((_) async => StreamInfo.fallback);
    when(() => transport.subscribeFrames(any())).thenAnswer((_) {
      frameSubscriptions++;
      return frames.stream;
    });
    when(() => transport.unsubscribeFrames(any())).thenAnswer((_) async {});
    when(() => transport.connectionState(any())).thenAnswer((_) => link.stream);
    when(() => transport.readRssi(any())).thenAnswer((_) async => -58);
    when(() => transport.readDieTemperature(any()))
        .thenAnswer((_) async => const DieTemperature(deciCelsius: 386));
  });

  tearDown(() async {
    await service?.dispose();
    service = null;
    for (final scan in scans) {
      if (!scan.isClosed) await scan.close();
    }
    if (!frames.isClosed) await frames.close();
    if (!link.isClosed) await link.close();
  });

  DeviceTestService build({
    Duration acoustic = const Duration(milliseconds: 60),
    DeviceTestStore? withStore,
  }) {
    final built = DeviceTestService(
      transport: transport,
      store: withStore ?? store,
      noiseFloorWindow: acoustic,
      sensitivityWindow: acoustic,
      tick: const Duration(milliseconds: 10),
    );
    service = built;
    return built;
  }

  /// One `fe01` notification: a little-endian sequence header, then s16le PCM
  /// all at [amplitude]. `StreamInfo.fallback` is raw PCM, so the payload needs
  /// no decoding.
  Uint8List frame(int sequence, {int amplitude = 0, int samples = 160}) {
    final bytes = Uint8List(2 + samples * 2);
    final view = ByteData.sublistView(bytes);
    view.setUint16(0, sequence, Endian.little);
    for (var i = 0; i < samples; i++) {
      view.setInt16(2 + i * 2, amplitude, Endian.little);
    }
    return bytes;
  }

  /// Lets the real event loop turn until [condition] holds.
  Future<void> until(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('condition was never met');
      }
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  /// Waits until the service has actually attached to the frame stream.
  ///
  /// NOT `phase == measuring`: the phase is set before the subscription is
  /// opened, and frames pushed into a broadcast stream with no listener yet are
  /// simply dropped - which would make every one of these tests silently
  /// measure nothing.
  Future<void> streaming() => until(() => frameSubscriptions > 0);

  Future<void> pushFrames(int count, {int amplitude = 0, int from = 0}) async {
    for (var i = 0; i < count; i++) {
      frames.add(frame(from + i, amplitude: amplitude));
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }

  // -------------------------------------------------------------------------
  group('the noise floor check', () {
    test('reports the RMS of the window it measured', () async {
      final tests = build();
      await tests.load();

      final run = tests.runNoiseFloor(
        deviceId: knownDevice.id,
        requestCodec: AudioCodec.pcmS16le,
      );
      await streaming();
      await pushFrames(4, amplitude: 328);
      final result = await run;

      expect(result!.kind, DeviceTestKind.noiseFloor);
      expect(result.outcome, DeviceTestOutcome.completed);
      final rms = result.reading(DeviceTestReadings.noiseFloorRms);
      expect(rms, isNotNull);
      // 328 / 32767 is -40 dBFS.
      expect(rms!.value, closeTo(-40.0, 0.2));
      expect(rms.unit, 'dBFS');
      // And a peak, because a rattle is a transient and an RMS alone hides it.
      expect(result.reading(DeviceTestReadings.peak)?.value,
          closeTo(-40.0, 0.2));
    });

    test('a silent stream is failed, not reported as a quiet room', () async {
      final tests = build();
      await tests.load();

      // Nothing pushed at all: the microphone may be dead, the device may not
      // be streaming. Either way there is no level, and -96 dBFS would be a lie
      // that reads as an excellent result.
      final result = await tests.runNoiseFloor(
        deviceId: knownDevice.id,
        requestCodec: AudioCodec.pcmS16le,
      );

      expect(result!.outcome, DeviceTestOutcome.failed);
      expect(result.reading(DeviceTestReadings.noiseFloorRms)?.value, isNull);
      expect(result.note, contains('not a quiet room'));
    });

    test('a device that will not report its format is unavailable, not guessed',
        () async {
      when(() => transport.readStreamInfo(any())).thenThrow(
        const BleTransportException('no such characteristic'),
      );
      final tests = build();
      await tests.load();

      final result = await tests.runNoiseFloor(
        deviceId: knownDevice.id,
        requestCodec: AudioCodec.imaAdpcm,
      );

      // Decoding ADPCM bytes as raw PCM would produce a number, and that number
      // would be compared against next week's run as though it meant something.
      expect(result!.outcome, DeviceTestOutcome.unavailable);
      expect(result.note, contains('invented'));
      expect(result.hasReadings, isFalse);
    });

    test('a capture already holding the stream fails the test, not the app',
        () async {
      when(() => transport.subscribeFrames(any()))
          .thenThrow(const BleTransportException('already subscribed to frames'));
      final tests = build();
      await tests.load();

      final result = await tests.runNoiseFloor(
        deviceId: knownDevice.id,
        requestCodec: AudioCodec.pcmS16le,
      );

      expect(result!.outcome, DeviceTestOutcome.failed);
      expect(result.note, contains('already subscribed'));
    });

    test('the result is on disk before the call returns', () async {
      final tests = build();
      await tests.load();

      final run = tests.runNoiseFloor(
        deviceId: knownDevice.id,
        requestCodec: AudioCodec.pcmS16le,
      );
      await streaming();
      await pushFrames(3, amplitude: 1000);
      await run;

      final reopened =
          DeviceTestStore(fileStore: files, directory: '/recordings');
      await reopened.load();
      expect(reopened.latestOf(DeviceTestKind.noiseFloor), isNotNull);
    });

    test('a store that cannot write says so instead of pretending', () async {
      final tests = build(
        withStore: DeviceTestStore(
          fileStore: _UnwritableStore(),
          directory: '/recordings',
        ),
      );
      await tests.load();

      final run = tests.runNoiseFloor(
        deviceId: knownDevice.id,
        requestCodec: AudioCodec.pcmS16le,
      );
      await streaming();
      await pushFrames(2, amplitude: 500);
      await run;

      expect(tests.saveFailure, isNotNull);
      expect(tests.saveFailure, contains('could not be saved'));
    });

    test('the frame stream is released when the test ends', () async {
      final tests = build();
      await tests.load();

      final run = tests.runNoiseFloor(
        deviceId: knownDevice.id,
        requestCodec: AudioCodec.pcmS16le,
      );
      await streaming();
      await pushFrames(2, amplitude: 500);
      await run;

      // Otherwise the next test - or the next recording - is told the stream is
      // already taken.
      verify(() => transport.unsubscribeFrames(knownDevice.id)).called(1);
      expect(tests.isRunning, isFalse);
      expect(tests.phase, DeviceTestPhase.idle);
    });
  });

  group('the sensitivity check', () {
    test('reports peak and RMS, and names the distance it was spoken from',
        () async {
      final tests = build();
      await tests.load();

      final run = tests.runSensitivity(
        deviceId: knownDevice.id,
        requestCodec: AudioCodec.pcmS16le,
      );
      await streaming();
      // A quiet stretch and a louder one, so peak and RMS differ.
      await pushFrames(3, amplitude: 100);
      await pushFrames(1, amplitude: 16000, from: 3);
      final result = await run;

      final peak = result!.reading(DeviceTestReadings.peak)!;
      final rms = result.reading(DeviceTestReadings.rms)!;
      expect(peak.value, isNotNull);
      expect(rms.value, isNotNull);
      expect(peak.value! > rms.value!, isTrue);
      // Comparable between runs only because the distance is fixed, so the
      // figure it was taken at travels with the result.
      expect(
        result.note,
        contains('${DeviceTestReadings.sensitivityDistanceCm} cm'),
      );
    });

    test('cancelling keeps the partial numbers and labels them cancelled',
        () async {
      final tests = build(acoustic: const Duration(seconds: 30));
      await tests.load();

      final run = tests.runSensitivity(
        deviceId: knownDevice.id,
        requestCodec: AudioCodec.pcmS16le,
      );
      await streaming();
      await pushFrames(3, amplitude: 2000);
      tests.cancel();
      final result = await run;

      expect(result!.outcome, DeviceTestOutcome.cancelled);
      // The numbers it did get are kept - they just must not be mistaken for a
      // finished run's.
      expect(result.reading(DeviceTestReadings.rms)?.value, isNotNull);
    });
  });

  // -------------------------------------------------------------------------
  // -------------------------------------------------------------------------
  // THE DIE TEMPERATURE, STAMPED ON EVERY RUN
  //
  // Not a test of its own - a one-shot read has nothing to time and nothing to
  // cancel. It is a number that belongs BESIDE every other number, because the
  // enclosure puts a cell under the board and a worse noise floor at a hotter
  // die is a different finding from a worse noise floor at the same die.
  // -------------------------------------------------------------------------
  group('the die temperature', () {
    test('is recorded with an acoustic run', () async {
      final tests = build();
      await tests.load();

      final run = tests.runNoiseFloor(
        deviceId: knownDevice.id,
        requestCodec: AudioCodec.pcmS16le,
      );
      await streaming();
      await pushFrames(3, amplitude: 500);
      final result = await run;

      final die = result!.reading(DeviceTestReadings.dieTemperature)!;
      expect(die.value, closeTo(38.6, 1e-9));
      expect(die.unit, '°C');
    });

    test('firmware without fe07 records null, never zero degrees', () async {
      when(() => transport.readDieTemperature(any()))
          .thenThrow(const BleTransportException('no such characteristic'));
      final tests = build();
      await tests.load();

      final run = tests.runNoiseFloor(
        deviceId: knownDevice.id,
        requestCodec: AudioCodec.pcmS16le,
      );
      await streaming();
      await pushFrames(3, amplitude: 500);
      final result = await run;

      final die = result!.reading(DeviceTestReadings.dieTemperature)!;
      expect(die.value, isNull);
      // 0 C on a self-heating die is absurd, and absurd numbers get averaged
      // into real ones.
      expect(die.value, isNot(0));
    });

    test('0x8000 records null too', () async {
      when(() => transport.readDieTemperature(any()))
          .thenAnswer((_) async => const DieTemperature(deciCelsius: null));
      final tests = build();
      await tests.load();

      final run = tests.runNoiseFloor(
        deviceId: knownDevice.id,
        requestCodec: AudioCodec.pcmS16le,
      );
      await streaming();
      await pushFrames(3, amplitude: 500);
      final result = await run;

      expect(
        result!.reading(DeviceTestReadings.dieTemperature)?.value,
        isNull,
      );
    });
  });

  group('the service itself', () {
    test('only one check runs at a time', () async {
      final tests = build(acoustic: const Duration(milliseconds: 200));
      await tests.load();

      final first = tests.runNoiseFloor(
        deviceId: knownDevice.id,
        requestCodec: AudioCodec.pcmS16le,
      );
      await until(() => tests.isRunning);
      // The frame subscription is exclusive, so a second concurrent test could
      // only produce nonsense.
      expect(
        await tests.runSensitivity(
          deviceId: knownDevice.id,
          requestCodec: AudioCodec.pcmS16le,
        ),
        isNull,
      );
      await first;
    });

    test('every finished run is published, newest first', () async {
      final tests = build();
      await tests.load();

      for (var i = 0; i < 2; i++) {
        final run = tests.runNoiseFloor(
          deviceId: knownDevice.id,
          requestCodec: AudioCodec.pcmS16le,
        );
        await streaming();
        await pushFrames(2, amplitude: 1000);
        await run;
      }

      expect(tests.history, hasLength(2));
      expect(tests.latestOf(DeviceTestKind.noiseFloor), isNotNull);
      expect(
        tests.history.first.startedAt.isAfter(tests.history[1].startedAt) ||
            tests.history.first.startedAt == tests.history[1].startedAt,
        isTrue,
      );
    });

    test('the elapsed clock moves while a test runs and stops after', () async {
      final tests = build(acoustic: const Duration(milliseconds: 120));
      await tests.load();

      final run = tests.runNoiseFloor(
        deviceId: knownDevice.id,
        requestCodec: AudioCodec.pcmS16le,
      );
      await until(() => tests.elapsed > Duration.zero);
      await pushFrames(2, amplitude: 1000);
      await run;

      final settled = tests.elapsed;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // No ticker left running: the screen must not keep repainting, and a
      // three-minute soak's timer must not outlive a cancel.
      expect(tests.elapsed, settled);
      expect(tests.running, isNull);
    });

    test('changes are published so a screen can follow along', () async {
      final tests = build();
      await tests.load();
      var notifications = 0;
      final subscription = tests.changes.listen((_) => notifications++);

      final run = tests.runNoiseFloor(
        deviceId: knownDevice.id,
        requestCodec: AudioCodec.pcmS16le,
      );
      await streaming();
      await pushFrames(2, amplitude: 1000);
      await run;

      expect(notifications, greaterThan(1));
      await subscription.cancel();
    });

    test('disposing a running test leaves no timer and no subscription',
        () async {
      final tests = build(acoustic: const Duration(seconds: 30));
      await tests.load();

      unawaited(
        tests.runNoiseFloor(
          deviceId: knownDevice.id,
          requestCodec: AudioCodec.pcmS16le,
        ),
      );
      await streaming();
      await tests.dispose();
      service = null;

      verify(() => transport.unsubscribeFrames(knownDevice.id)).called(1);
    });
  });

  // -------------------------------------------------------------------------
  // REPEATED SAMPLES
  //
  // ONE READING CANNOT BE COMPARED AGAINST ONE READING here. Every one of these
  // five measurements is noisy - RF loss depends on who is standing where, the
  // noise floor on the fridge compressor, the wake figure on the phone's own
  // scan latency - so a single number before the enclosure and a single number
  // after would show a difference that is as likely to be noise as anything.
  // Each test therefore takes n samples under one batch id.
  //
  // Two of the five can repeat unattended. The other three ARE the operator, so
  // they wait between samples - and can be stopped early, which keeps every
  // sample already taken.
  // -------------------------------------------------------------------------
  group('a batch of samples', () {
    /// Feeds audio into each sample of an automatic batch as it opens.
    Future<void> feed(int samples, {int amplitude = 1000}) async {
      for (var i = 1; i <= samples; i++) {
        await until(() => frameSubscriptions >= i);
        await pushFrames(3, amplitude: amplitude);
      }
    }

    test('the noise floor repeats on its own and saves every sample', () async {
      final tests = build(acoustic: const Duration(milliseconds: 40));
      await tests.load();

      final run = tests.runNoiseFloor(
        deviceId: knownDevice.id,
        requestCodec: AudioCodec.pcmS16le,
        repeats: 3,
      );
      await feed(3);
      await run;

      // Three rows on disk, one batch, numbered - not one row that was
      // overwritten twice.
      final batch = tests.batchesOf(DeviceTestKind.noiseFloor).single;
      expect(batch.sampleCount, 3);
      expect(batch.requested, 3);
      expect(batch.isPartial, isFalse);
      expect(batch.runs.map((run) => run.repeatIndex), <int>[1, 2, 3]);
      expect(batch.runs.map((run) => run.batchId).toSet(), hasLength(1));
      expect(frameSubscriptions, 3);
      // Every sample got its own stream and gave it back.
      verify(() => transport.unsubscribeFrames(knownDevice.id)).called(3);
      // And the batch is over: nothing is left holding the screen open.
      expect(tests.isRunning, isFalse);
      expect(tests.isBatchActive, isFalse);
      expect(tests.phase, DeviceTestPhase.idle);
    });

    test('the aggregate of a batch is a median with the spread around it',
        () async {
      final tests = build(acoustic: const Duration(milliseconds: 40));
      await tests.load();

      final run = tests.runNoiseFloor(
        deviceId: knownDevice.id,
        requestCodec: AudioCodec.pcmS16le,
        repeats: 3,
      );
      // Three deliberately different levels, the middle one last: a median has
      // to find it wherever it is.
      await until(() => frameSubscriptions >= 1);
      await pushFrames(3, amplitude: 328);
      await until(() => frameSubscriptions >= 2);
      await pushFrames(3, amplitude: 32);
      await until(() => frameSubscriptions >= 3);
      await pushFrames(3, amplitude: 104);
      await run;

      final spread = tests
          .batchesOf(DeviceTestKind.noiseFloor)
          .single
          .spreadOf(DeviceTestReadings.noiseFloorRms);
      expect(spread.n, 3);
      // 328 is -40 dBFS, 104 is -50, 32 is -60.
      expect(spread.median, closeTo(-50, 0.5));
      expect(spread.min, closeTo(-60, 0.5));
      expect(spread.max, closeTo(-40, 0.5));
      expect(spread.spread, closeTo(20, 1));
    });

    test('an automatic batch stops at the first sample that cannot measure',
        () async {
      final tests = build(acoustic: const Duration(milliseconds: 30));
      await tests.load();

      // Nothing is ever pushed, so the first sample has no audio at all and is
      // failed. Four more three-minute attempts against a device that is not
      // streaming would be noise in the history, not data.
      await tests.runNoiseFloor(
        deviceId: knownDevice.id,
        requestCodec: AudioCodec.pcmS16le,
        repeats: 5,
      );

      final batch = tests.batchesOf(DeviceTestKind.noiseFloor).single;
      expect(batch.sampleCount, 1);
      expect(batch.requested, 5);
      expect(batch.isPartial, isTrue);
      // The reason is not lost: the failure IS one of the saved samples.
      expect(batch.countOf(DeviceTestOutcome.failed), 1);
      expect(tests.isBatchActive, isFalse);
    });

    test('cancelling an automatic batch keeps the samples already taken',
        () async {
      final tests = build(acoustic: const Duration(milliseconds: 60));
      await tests.load();

      final run = tests.runNoiseFloor(
        deviceId: knownDevice.id,
        requestCodec: AudioCodec.pcmS16le,
        repeats: 5,
      );
      await feed(2);
      // Mid third sample.
      await until(() => frameSubscriptions >= 3);
      await pushFrames(3, amplitude: 1000);
      tests.cancel();
      await run;

      final batch = tests.batchesOf(DeviceTestKind.noiseFloor).single;
      // Three samples: two finished and one cancelled with its partial numbers.
      expect(batch.sampleCount, 3);
      expect(batch.requested, 5);
      expect(batch.isPartial, isTrue);
      expect(batch.countOf(DeviceTestOutcome.cancelled), 1);
      // And the aggregate is computed over what there is, not refused.
      expect(batch.spreadOf(DeviceTestReadings.noiseFloorRms).n, 3);
      expect(tests.isBatchActive, isFalse);
    });

    test('the sensitivity check waits for the operator between samples',
        () async {
      final tests = build(acoustic: const Duration(milliseconds: 40));
      await tests.load();

      final first = tests.runSensitivity(
        deviceId: knownDevice.id,
        requestCodec: AudioCodec.pcmS16le,
        repeats: 3,
      );
      await until(() => frameSubscriptions >= 1);
      await pushFrames(3, amplitude: 4000);
      await first;

      // It did NOT loop into a second sample: somebody has to be there speaking
      // at the marked distance, and recording the silence after the first sample
      // would report it as a quiet voice.
      expect(tests.awaitingNextSample, isTrue);
      expect(tests.batchKind, DeviceTestKind.sensitivity);
      expect(tests.samplesTaken, 1);
      expect(tests.batchTarget, 3);
      expect(tests.sampleNumber, 2);
      expect(frameSubscriptions, 1);
      // The batch still counts as running, so nothing else can take the stream.
      expect(tests.isBatchActive, isTrue);

      final second = tests.continueBatch();
      await until(() => frameSubscriptions >= 2);
      await pushFrames(3, amplitude: 4000);
      await second;

      expect(tests.samplesTaken, 2);
      expect(tests.awaitingNextSample, isTrue);
      expect(tests.batchesOf(DeviceTestKind.sensitivity).single.sampleCount, 2);
    });

    test('stopping at two of five keeps both and labels the batch partial',
        () async {
      final tests = build(acoustic: const Duration(milliseconds: 40));
      await tests.load();

      final first = tests.runSensitivity(
        deviceId: knownDevice.id,
        requestCodec: AudioCodec.pcmS16le,
        repeats: 5,
      );
      await until(() => frameSubscriptions >= 1);
      await pushFrames(3, amplitude: 4000);
      await first;
      final second = tests.continueBatch();
      await until(() => frameSubscriptions >= 2);
      await pushFrames(3, amplitude: 4000);
      await second;

      // THE PARTIAL-RUN REQUIREMENT: they had enough, and what they measured is
      // not thrown away for being fewer than five.
      tests.endBatch();

      expect(tests.isBatchActive, isFalse);
      expect(tests.awaitingNextSample, isFalse);
      final batch = tests.batchesOf(DeviceTestKind.sensitivity).single;
      expect(batch.sampleCount, 2);
      expect(batch.requested, 5);
      expect(batch.isPartial, isTrue);
      expect(batch.spreadOf(DeviceTestReadings.rms).n, 2);
    });

    test('continueBatch does nothing when no batch is waiting', () async {
      final tests = build();
      await tests.load();

      // A double tap cannot start a second sample, and this is never the way to
      // start a batch.
      expect(await tests.continueBatch(), isNull);
      expect(tests.isBatchActive, isFalse);
      expect(frameSubscriptions, 0);
    });

    test('a batch in progress keeps the other check out', () async {
      final tests = build(acoustic: const Duration(milliseconds: 40));
      await tests.load();

      final first = tests.runSensitivity(
        deviceId: knownDevice.id,
        requestCodec: AudioCodec.pcmS16le,
        repeats: 3,
      );
      await until(() => frameSubscriptions >= 1);
      await pushFrames(3, amplitude: 4000);
      await first;
      expect(tests.awaitingNextSample, isTrue);

      // Nothing is streaming, but the batch is half collected - starting
      // something else here would abandon it.
      expect(
        await tests.runNoiseFloor(
          deviceId: knownDevice.id,
          requestCodec: AudioCodec.pcmS16le,
        ),
        isNull,
      );
      expect(
        await tests.runSensitivity(
          deviceId: knownDevice.id,
          requestCodec: AudioCodec.pcmS16le,
        ),
        isNull,
      );
      expect(tests.batchKind, DeviceTestKind.sensitivity);
      expect(frameSubscriptions, 1);
    });

    test('a single sample is still a batch of one, and says so', () async {
      final tests = build(acoustic: const Duration(milliseconds: 40));
      await tests.load();

      final run = tests.runNoiseFloor(
        deviceId: knownDevice.id,
        requestCodec: AudioCodec.pcmS16le,
      );
      await streaming();
      await pushFrames(3, amplitude: 1000);
      final result = await run;

      expect(result!.repeatIndex, 1);
      expect(result.repeatTarget, 1);
      final batch = tests.batchesOf(DeviceTestKind.noiseFloor).single;
      expect(batch.isSingle, isTrue);
      expect(batch.isPartial, isFalse);
      // With one sample there is no spread, and it must not read as zero.
      expect(
        batch.spreadOf(DeviceTestReadings.noiseFloorRms).spread,
        isNull,
      );
    });

    test('two sittings of the same check stay two batches', () async {
      final tests = build(acoustic: const Duration(milliseconds: 40));
      await tests.load();

      for (var sitting = 0; sitting < 2; sitting++) {
        final run = tests.runNoiseFloor(
          deviceId: knownDevice.id,
          requestCodec: AudioCodec.pcmS16le,
          repeats: 2,
        );
        await feed(2 * (sitting + 1));
        await run;
      }

      // "Latest beside Before", and both halves are batches of two.
      final batches = tests.batchesOf(DeviceTestKind.noiseFloor);
      expect(batches, hasLength(2));
      expect(batches.map((batch) => batch.sampleCount), <int>[2, 2]);
      expect(batches.first.batchId, isNot(batches[1].batchId));
    });

    test('a repeat count below one is one, never zero samples', () async {
      final tests = build(acoustic: const Duration(milliseconds: 40));
      await tests.load();

      final run = tests.runNoiseFloor(
        deviceId: knownDevice.id,
        requestCodec: AudioCodec.pcmS16le,
        repeats: 0,
      );
      await streaming();
      await pushFrames(3, amplitude: 1000);
      await run;

      expect(tests.batchesOf(DeviceTestKind.noiseFloor).single.sampleCount, 1);
    });
  });
}

/// A store whose writes always fail, for the "measured but not saved" path.
class _UnwritableStore extends MemoryFileStore {
  @override
  Future<void> writeBytes(String path, List<int> bytes) async =>
      throw Exception('read-only filesystem');
}
