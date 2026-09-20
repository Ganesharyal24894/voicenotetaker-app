import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/drivers/ble_transport.dart';
import 'package:voicenotetaker_app/model/audio_codec.dart';
import 'package:voicenotetaker_app/model/auto_sleep.dart';
import 'package:voicenotetaker_app/services/link_monitor.dart';

import 'view/harness.dart' show MockBleTransport, knownDevice;

/// The live link watcher, driven against a fake radio.
///
/// It replaced two saved tests - a stepped range walk and a three-minute link
/// soak - so the things worth pinning down are the two those tests measured, plus
/// the one rule that makes it safe to open on a main-UI screen:
///
///   * it STOPS COMPLETELY. No subscription, no notifications at the device, no
///     poll timer. It is opened by a screen becoming visible and a screen can
///     stop being visible for hours.
///   * it NEVER WRITES. Counting frames needs no codec and no flag; an observer
///     that reconfigured the device would not be one.
void main() {
  setUpAll(() {
    registerFallbackValue(AudioCodec.imaAdpcm);
    registerFallbackValue(AutoSleepDuration.off);
  });

  late MockBleTransport transport;
  late StreamController<Uint8List> frames;
  late int subscriptions;
  late int unsubscriptions;
  LinkMonitor? monitor;

  setUp(() {
    transport = MockBleTransport();
    frames = StreamController<Uint8List>.broadcast();
    subscriptions = 0;
    unsubscriptions = 0;

    when(() => transport.subscribeFrames(any())).thenAnswer((_) {
      subscriptions++;
      return frames.stream;
    });
    when(() => transport.unsubscribeFrames(any())).thenAnswer((_) async {
      unsubscriptions++;
    });
    when(() => transport.readRssi(any())).thenAnswer((_) async => -58);
  });

  tearDown(() async {
    await monitor?.dispose();
    monitor = null;
    if (!frames.isClosed) await frames.close();
  });

  LinkMonitor build({
    Duration poll = const Duration(milliseconds: 20),
  }) {
    final built = LinkMonitor(transport: transport, pollInterval: poll);
    monitor = built;
    return built;
  }

  /// One `fe01` notification: a little-endian sequence header and a payload.
  Uint8List frame(int sequence) {
    final bytes = Uint8List(2 + 8);
    bytes[0] = sequence & 0xFF;
    bytes[1] = (sequence >> 8) & 0xFF;
    return bytes;
  }

  Future<void> settle([int ms = 10]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  test('does nothing at all until it is started', () {
    final link = build();

    expect(link.isWatching, isFalse);
    expect(link.health.watching, isFalse);
    verifyNever(() => transport.subscribeFrames(any()));
    verifyNever(() => transport.readRssi(any()));
  });

  test('starting subscribes to the audio stream and reads the signal at once',
      () async {
    final link = build();
    await link.start(knownDevice.id);

    expect(link.isWatching, isTrue);
    expect(subscriptions, 1);
    // A reading immediately rather than after the first poll interval, so the
    // meter is not empty for a second on a link that is perfectly healthy.
    expect(link.health.rssiDbm, -58);
    expect(link.failure, isNull);
  });

  test('it never writes anything to the device', () async {
    // Counting frames works whatever format the device is streaming: the
    // sequence header sits in front of the payload and is not part of it.
    final link = build();
    await link.start(knownDevice.id);
    frames.add(frame(0));
    await settle();

    verifyNever(() => transport.selectCodec(any(), any()));
    verifyNever(() => transport.setAutoSleepDuration(any(), any()));
    expect(link.health.framesReceived, 1);
  });

  test('loss is counted from gaps in the sequence number', () async {
    final link = build();
    await link.start(knownDevice.id);

    frames.add(frame(0));
    frames.add(frame(1));
    // 2 never arrives.
    frames.add(frame(3));
    await settle();

    expect(link.health.framesReceived, 3);
    expect(link.health.framesLost, 1);
    expect(link.health.lossPercent, closeTo(25.0, 1e-9));
  });

  test('stopping leaves nothing running', () async {
    final link = build();
    await link.start(knownDevice.id);
    frames.add(frame(0));
    await settle();

    await link.stop();
    // Consumes the reads taken while it was running, so the check below is about
    // what happens AFTER the stop and nothing else.
    verify(() => transport.readRssi(any())).called(greaterThan(0));
    // The device is told to stop notifying, not merely ignored.
    expect(unsubscriptions, 1);
    expect(link.isWatching, isFalse);
    expect(link.health.watching, isFalse);
    expect(link.health.rssiDbm, isNull);

    // And the poll is gone: no further reads arrive however long we wait.
    await settle(80);
    verifyNever(() => transport.readRssi(any()));
  });

  test('the counters start from zero on every start', () async {
    // They describe this sitting in front of the screen, not the lifetime of the
    // link. A counter that carried over would mix a walk down the corridor into
    // a measurement taken at the desk.
    final link = build();
    await link.start(knownDevice.id);
    frames.add(frame(0));
    frames.add(frame(1));
    await settle();
    expect(link.health.framesReceived, 2);

    await link.stop();
    await link.start(knownDevice.id);

    expect(link.health.framesReceived, 0);
    expect(link.health.framesLost, 0);
    expect(link.health.lossPercent, isNull);
  });

  test('starting twice on the same device does not open a second stream',
      () async {
    // `openDiagnostics` is called on push AND on every resume from the
    // background, so this has to be idempotent.
    final link = build();
    await link.start(knownDevice.id);
    await link.start(knownDevice.id);

    expect(subscriptions, 1);
  });

  test('a platform that will not report the signal reads as no reading',
      () async {
    when(() => transport.readRssi(any()))
        .thenThrow(const BleTransportException('not supported'));
    final link = build();
    await link.start(knownDevice.id);

    // NOT zero, and not the previous value either: a meter frozen at -58 dBm
    // would be showing a measurement nothing is taking.
    expect(link.health.rssiDbm, isNull);
    // The frames are still counted - that half does not depend on the signal.
    frames.add(frame(0));
    await settle();
    expect(link.health.framesReceived, 1);
  });

  test('the signal is dropped rather than frozen when it stops being readable',
      () async {
    final link = build();
    await link.start(knownDevice.id);
    expect(link.health.rssiDbm, -58);

    when(() => transport.readRssi(any()))
        .thenThrow(const BleTransportException('link went away'));
    await settle(60);

    expect(link.health.rssiDbm, isNull);
  });

  test('a stream it cannot have is reported, not swallowed', () async {
    // The exclusive frame subscription: a recording or a mic check has it. "No
    // frames lost" and "nothing is counting" look identical in a counter.
    when(() => transport.subscribeFrames(any()))
        .thenThrow(const BleTransportException('a capture is already running'));
    final link = build();
    await link.start(knownDevice.id);

    expect(link.isWatching, isFalse);
    expect(link.failure, contains('capture is already running'));
    // The signal is still worth reading, so the poll started anyway.
    expect(link.health.rssiDbm, -58);
  });

  test('an error on the stream is said out loud', () async {
    final link = build();
    await link.start(knownDevice.id);
    frames.addError(const BleTransportException('notification decode failed'));
    await settle();

    expect(link.failure, contains('reported an error'));
  });

  test('changes are published so a screen can follow along', () async {
    final link = build();
    var notifications = 0;
    final subscription = link.changes.listen((_) => notifications++);
    addTearDown(subscription.cancel);

    await link.start(knownDevice.id);
    await settle(60);

    // The counters are published on the poll rather than on every notification:
    // a frame arrives about a hundred times a second and a rebuild per frame
    // would cost more than the measurement is worth.
    expect(notifications, greaterThan(1));
  });

  test('disposing stops it too', () async {
    final link = build();
    await link.start(knownDevice.id);
    await link.dispose();
    monitor = null;

    expect(unsubscriptions, 1);
    expect(link.isWatching, isFalse);
  });
}
