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

/// The five enclosure tests, driven against a fake radio.
///
/// These are service tests, not widget tests, and deliberately: the interesting
/// behaviour is a sequence over time - open a notify stream, count for a window,
/// watch an advertising gap, time a shake - and a widget tester's fake clock is
/// the wrong instrument for it. The windows are injected in milliseconds so the
/// whole file runs in a second.
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
  late bool advertising;
  late int disconnects;
  late int frameSubscriptions;
  DeviceTestService? service;

  setUp(() {
    transport = MockBleTransport();
    files = MemoryFileStore();
    store = DeviceTestStore(fileStore: files, directory: '/recordings');
    frames = StreamController<Uint8List>.broadcast();
    link = StreamController<BleConnectionStatus>.broadcast();
    scans = <StreamController<DiscoveredDevice>>[];
    advertising = true;
    disconnects = 0;
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
    when(() => transport.setAutoSleep(any(), any())).thenAnswer((_) async {});
    when(() => transport.stopScan()).thenAnswer((_) async {});
    // Each scan window is a fresh stream, exactly as the real transport hands
    // one out. Nothing is emitted unless the device is "advertising".
    when(() => transport.scan()).thenAnswer((_) {
      final controller = StreamController<DiscoveredDevice>();
      scans.add(controller);
      if (advertising) {
        scheduleMicrotask(() {
          if (!controller.isClosed) controller.add(knownDevice);
        });
      }
      return controller.stream;
    });
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
    Duration soak = const Duration(milliseconds: 60),
    Duration poll = const Duration(milliseconds: 20),
    Duration confirm = const Duration(milliseconds: 60),
    Duration systemOff = const Duration(milliseconds: 900),
    Duration wake = const Duration(milliseconds: 300),
    Future<void> Function()? disconnectLink,
    DeviceTestStore? withStore,
  }) {
    final built = DeviceTestService(
      transport: transport,
      store: withStore ?? store,
      disconnectLink: disconnectLink ??
          () async {
            disconnects++;
          },
      noiseFloorWindow: acoustic,
      sensitivityWindow: acoustic,
      linkSoakWindow: soak,
      advertisingPollWindow: poll,
      systemOffConfirm: confirm,
      systemOffTimeout: systemOff,
      wakeTimeout: wake,
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
  group('the noise floor test', () {
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

  group('the sensitivity test', () {
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
  group('the range walk', () {
    test('records the live RSSI and the frames lost on each leg', () async {
      final tests = build();
      await tests.load();

      expect(
        await tests.beginRangeWalk(
          deviceId: knownDevice.id,
          requestCodec: AudioCodec.pcmS16le,
        ),
        isTrue,
      );
      expect(tests.phase, DeviceTestPhase.walking);

      // Leg one: clean.
      await pushFrames(10);
      when(() => transport.readRssi(any())).thenAnswer((_) async => -54);
      await tests.markRangeStep();

      // Leg two: a gap in the sequence numbers - frames the device sent and the
      // phone never saw.
      await pushFrames(5, from: 10);
      await pushFrames(5, from: 19);
      when(() => transport.readRssi(any())).thenAnswer((_) async => -79);
      await tests.markRangeStep();

      final result = await tests.finishRangeWalk();

      expect(result!.steps.length, greaterThanOrEqualTo(2));
      expect(result.steps[0].rssiDbm, -54);
      expect(result.steps[0].framesLost, 0);
      expect(result.steps[1].rssiDbm, -79);
      expect(result.steps[1].framesLost, 4);
      // THE HEADLINE: the signal at the stop where frames first went missing.
      // An RSSI-only report would have called -79 dBm a usable link.
      expect(
        result.reading(DeviceTestReadings.rssiAtFirstDrop)?.value,
        -79,
      );
      expect(result.note, contains('stop 2'));
    });

    test('a walk with no drops reports no limit rather than a false one',
        () async {
      final tests = build();
      await tests.load();
      await tests.beginRangeWalk(
        deviceId: knownDevice.id,
        requestCodec: AudioCodec.pcmS16le,
      );
      await pushFrames(20);
      await tests.markRangeStep();
      final result = await tests.finishRangeWalk();

      // Null, NOT 0 dBm: nothing dropped, so there is no signal level to name.
      expect(result!.reading(DeviceTestReadings.rssiAtFirstDrop)?.value, isNull);
      expect(result.note, contains('only a floor on it'));
    });

    test('a stop with no RSSI reading still records its frame counts',
        () async {
      when(() => transport.readRssi(any()))
          .thenThrow(const BleTransportException('not supported here'));
      final tests = build();
      await tests.load();
      await tests.beginRangeWalk(
        deviceId: knownDevice.id,
        requestCodec: AudioCodec.pcmS16le,
      );
      await pushFrames(6);
      await tests.markRangeStep();
      final result = await tests.finishRangeWalk();

      expect(result!.steps.first.rssiDbm, isNull);
      expect(result.steps.first.framesReceived, greaterThan(0));
      // The frame counts are the half of the measurement that cannot be argued
      // with, so losing RSSI must not lose the walk.
      expect(result.outcome, DeviceTestOutcome.completed);
    });

    test('the final leg is measured rather than thrown away', () async {
      final tests = build();
      await tests.load();
      await tests.beginRangeWalk(
        deviceId: knownDevice.id,
        requestCodec: AudioCodec.pcmS16le,
      );
      await pushFrames(4);
      await tests.markRangeStep();
      await pushFrames(4, from: 4);
      // No second Mark step: finishing must still close the last leg.
      final result = await tests.finishRangeWalk();

      expect(result!.steps, hasLength(2));
      expect(result.steps.last.framesReceived, 4);
    });

    test('marking a step outside a walk does nothing', () async {
      final tests = build();
      await tests.load();
      await tests.markRangeStep();
      expect(tests.steps, isEmpty);
      expect(await tests.finishRangeWalk(), isNull);
    });
  });

  // -------------------------------------------------------------------------
  group('the link soak', () {
    test('counts frames, loss and disconnections over the window', () async {
      final tests = build(soak: const Duration(milliseconds: 120));
      await tests.load();

      final run = tests.runLinkSoak(
        deviceId: knownDevice.id,
        requestCodec: AudioCodec.pcmS16le,
      );
      await streaming();
      await pushFrames(10);
      await pushFrames(10, from: 12);
      final result = await run;

      expect(result!.outcome, DeviceTestOutcome.completed);
      expect(result.reading(DeviceTestReadings.framesLost)?.value, 2);
      expect(result.reading(DeviceTestReadings.lossPercent)?.value,
          closeTo(100 * 2 / 22, 0.01));
      expect(result.reading(DeviceTestReadings.disconnections)?.value, 0);
    });

    test('a link that goes away ends the soak and says so', () async {
      final tests = build(soak: const Duration(seconds: 30));
      await tests.load();

      final run = tests.runLinkSoak(
        deviceId: knownDevice.id,
        requestCodec: AudioCodec.pcmS16le,
      );
      await streaming();
      await pushFrames(5);
      link.add(BleConnectionStatus.disconnected);
      final result = await run;

      // A run that spent most of its window disconnected is not a soak, and an
      // intermittent link is exactly what this test is looking for.
      expect(result!.outcome, DeviceTestOutcome.failed);
      expect(result.reading(DeviceTestReadings.disconnections)?.value, 1);
      expect(result.note, contains('went away'));
    });

    test('a transport that cannot report link state says unknown, not zero',
        () async {
      when(() => transport.connectionState(any()))
          .thenThrow(const BleTransportException('unsupported'));
      final tests = build(soak: const Duration(milliseconds: 60));
      await tests.load();

      final run = tests.runLinkSoak(
        deviceId: knownDevice.id,
        requestCodec: AudioCodec.pcmS16le,
      );
      await streaming();
      await pushFrames(4);
      final result = await run;

      // "No disconnections" and "we could not tell" are different facts.
      expect(result!.reading(DeviceTestReadings.disconnections)?.value, isNull);
      expect(result.reading(DeviceTestReadings.framesLost)?.value, 0);
    });

    test('malformed notifications are counted separately from loss', () async {
      final tests = build(soak: const Duration(milliseconds: 80));
      await tests.load();

      final run = tests.runLinkSoak(
        deviceId: knownDevice.id,
        requestCodec: AudioCodec.pcmS16le,
      );
      await streaming();
      await pushFrames(3);
      // One byte: too short to carry a sequence header at all.
      frames.add(Uint8List.fromList(<int>[0x01]));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final result = await run;

      expect(result!.reading('Malformed frames')?.value, 1);
      expect(result.reading(DeviceTestReadings.framesLost)?.value, 0);
    });

    test('cancelling stops it early and saves what it had', () async {
      final tests = build(soak: const Duration(seconds: 30));
      await tests.load();

      final run = tests.runLinkSoak(
        deviceId: knownDevice.id,
        requestCodec: AudioCodec.pcmS16le,
      );
      await streaming();
      await pushFrames(6);
      tests.cancel();
      final result = await run;

      expect(result!.outcome, DeviceTestOutcome.cancelled);
      expect(result.reading('Frames received')?.value, 6);
      expect(tests.history.first.outcome, DeviceTestOutcome.cancelled);
    });
  });

  // -------------------------------------------------------------------------
  group('the wake-on-motion test', () {
    test('enables auto-sleep, drops the link, waits for silence, times a shake',
        () async {
      final tests = build();
      await tests.load();

      final run = tests.runWakeOnMotion(deviceId: knownDevice.id);
      // It stops advertising shortly after the link goes.
      await until(() => disconnects == 1);
      advertising = false;

      await until(() => tests.phase == DeviceTestPhase.waitingForShake);
      // The shake, and the device coming back.
      advertising = true;
      tests.confirmShaken();
      final result = await run;

      verify(() => transport.setAutoSleep(knownDevice.id, true)).called(1);
      expect(disconnects, 1);
      expect(result!.outcome, DeviceTestOutcome.completed);
      final delay = result.reading(DeviceTestReadings.wakeDelay)!;
      expect(delay.value, isNotNull);
      expect(delay.unit, 's');
      // The caveat travels with the figure: this includes the phone's own scan
      // discovery latency, so it is a coarse number by construction.
      expect(result.note, contains('scan-discovery latency'));
    });

    test('firmware that will not take the flag is unavailable, not failed',
        () async {
      when(() => transport.setAutoSleep(any(), any()))
          .thenThrow(const BleTransportException('no such characteristic'));
      final tests = build();
      await tests.load();

      final result = await tests.runWakeOnMotion(deviceId: knownDevice.id);

      expect(result!.outcome, DeviceTestOutcome.unavailable);
      expect(result.note, contains('auto-sleep could not be enabled'));
      // And the link is left alone: there was never a test to run.
      expect(disconnects, 0);
    });

    test('a build that cannot end the link reports that, and measures nothing',
        () async {
      final tests = DeviceTestService(
        transport: transport,
        store: store,
        tick: const Duration(milliseconds: 10),
      );
      service = tests;
      await tests.load();

      final result = await tests.runWakeOnMotion(deviceId: knownDevice.id);

      expect(result!.outcome, DeviceTestOutcome.unavailable);
      expect(result.note, contains('will not sleep while the app is connected'));
    });

    test('a device that never stops advertising is a failure with a reason',
        () async {
      final tests = build(systemOff: const Duration(milliseconds: 200));
      await tests.load();

      // Never goes quiet.
      final result = await tests.runWakeOnMotion(deviceId: knownDevice.id);

      expect(result!.outcome, DeviceTestOutcome.failed);
      expect(result.note, contains('never reached System OFF'));
      expect(result.reading(DeviceTestReadings.wakeDelay), isNull);
    });

    test('a shake that does not wake it reports no wake time at all', () async {
      final tests = build(wake: const Duration(milliseconds: 150));
      await tests.load();

      final run = tests.runWakeOnMotion(deviceId: knownDevice.id);
      await until(() => disconnects == 1);
      advertising = false;
      await until(() => tests.phase == DeviceTestPhase.waitingForShake);
      // Shaken, but it stays asleep - the case is damping the shake below the
      // IMU's threshold, which is the whole finding.
      tests.confirmShaken();
      final result = await run;

      expect(result!.outcome, DeviceTestOutcome.failed);
      // A timeout is NOT a wake time.
      expect(result.reading(DeviceTestReadings.wakeDelay)?.value, isNull);
      expect(result.note, contains('mass and damping'));
    });

    test('cancelling before the shake says auto-sleep was left enabled',
        () async {
      final tests = build();
      await tests.load();

      final run = tests.runWakeOnMotion(deviceId: knownDevice.id);
      await until(() => disconnects == 1);
      advertising = false;
      await until(() => tests.phase == DeviceTestPhase.waitingForShake);
      tests.cancel();
      final result = await run;

      expect(result!.outcome, DeviceTestOutcome.cancelled);
      // The flag lives in the device's flash, so leaving it on is a real
      // consequence the operator has to be told about.
      expect(result.note, contains('left'));
      expect(result.note, contains('enabled'));
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

    test('is recorded with a soak and with a range walk', () async {
      final tests = build(soak: const Duration(milliseconds: 60));
      await tests.load();

      final soak = tests.runLinkSoak(
        deviceId: knownDevice.id,
        requestCodec: AudioCodec.pcmS16le,
      );
      await streaming();
      await pushFrames(2);
      final soaked = await soak;
      expect(
        soaked!.reading(DeviceTestReadings.dieTemperature)?.value,
        closeTo(38.6, 1e-9),
      );

      await tests.beginRangeWalk(
        deviceId: knownDevice.id,
        requestCodec: AudioCodec.pcmS16le,
      );
      await pushFrames(2, from: 40);
      final walk = await tests.finishRangeWalk();
      expect(
        walk!.reading(DeviceTestReadings.dieTemperature)?.value,
        closeTo(38.6, 1e-9),
      );
    });

    test('the wake test reads it BEFORE dropping the link', () async {
      final tests = build();
      await tests.load();

      final run = tests.runWakeOnMotion(deviceId: knownDevice.id);
      await until(() => disconnects == 1);
      advertising = false;
      await until(() => tests.phase == DeviceTestPhase.waitingForShake);
      advertising = true;
      tests.confirmShaken();
      final result = await run;

      // Afterwards the device is asleep and then freshly awake, with no link to
      // read over - so a reading taken at the end would always be missing.
      expect(
        result!.reading(DeviceTestReadings.dieTemperature)?.value,
        closeTo(38.6, 1e-9),
      );
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

  group('the harness itself', () {
    test('only one test runs at a time', () async {
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
      expect(
        await tests.beginRangeWalk(
          deviceId: knownDevice.id,
          requestCodec: AudioCodec.pcmS16le,
        ),
        isFalse,
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
}

/// A store whose writes always fail, for the "measured but not saved" path.
class _UnwritableStore extends MemoryFileStore {
  @override
  Future<void> writeBytes(String path, List<int> bytes) async =>
      throw Exception('read-only filesystem');
}
