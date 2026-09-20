import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/controller/app_controller.dart';
import 'package:voicenotetaker_app/drivers/ble_transport.dart';
import 'package:voicenotetaker_app/model/capture_flags.dart';
import 'package:voicenotetaker_app/model/continuous_status.dart';
import 'package:voicenotetaker_app/model/device_state.dart';
import 'package:voicenotetaker_app/model/reconnect_backoff.dart';
import 'package:voicenotetaker_app/services/library_service.dart';
import 'package:voicenotetaker_app/services/wav_writer.dart';

import '../view/harness.dart';

/// Always-listening at the controller: when it listens, what it tells the
/// device, how it comes back after a drop, and what the notification says.
void main() {
  setUpAll(registerViewFallbacks);

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

  Future<(ViewHarness, FakeBackgroundMode)> started({
    bool newFirmware = true,
  }) async {
    final background = FakeBackgroundMode();
    final harness = ViewHarness(backgroundMode: background)
      ..captureSupported = newFirmware;
    addTearDown(harness.dispose);
    await harness.controller.initialise();
    await harness.controller.connect(knownDevice);
    return (harness, background);
  }

  test('off by default: nothing is written, nothing runs', () async {
    final (harness, background) = await started();

    expect(harness.controller.continuousEnabled, isFalse);
    expect(harness.controller.continuousStatus, ContinuousStatus.off);
    verifyNever(() => harness.transport.writeCapture(any(), any()));
    verifyNever(() => harness.transport.subscribeCapture(any()));
    expect(background.texts, isEmpty);
  });

  test('turning it on while connected starts listening', () async {
    final (harness, background) = await started();

    await harness.controller.setContinuousEnabled(true);

    verify(() => harness.transport
        .writeCapture(knownDevice.id, CaptureCommand.gateEnabled)).called(1);
    expect(harness.controller.continuousActive, isTrue);
    expect(harness.controller.continuousStatus, ContinuousStatus.listening);
    expect(background.running, isTrue);
    expect(background.texts.last, 'Always listening');
  });

  test('the device reporting speech and mute moves the status and the '
      'notification', () async {
    final (harness, background) = await started();
    await harness.controller.setContinuousEnabled(true);

    harness.capture.add(
      const CaptureFlags(muted: false, speechOpen: true, gateEnabled: true),
    );
    await settle();
    expect(harness.controller.continuousStatus, ContinuousStatus.hearingSpeech);
    expect(background.texts.last, 'Hearing speech');

    harness.capture.add(
      const CaptureFlags(muted: true, speechOpen: false, gateEnabled: true),
    );
    await settle();
    expect(harness.controller.continuousStatus, ContinuousStatus.muted);
    expect(background.texts.last, 'Muted on device');
  });

  test('Record is refused while always listening', () async {
    final (harness, _) = await started();
    await harness.controller.setContinuousEnabled(true);

    await harness.controller.startRecording();

    expect(harness.controller.isRecording, isFalse);
  });

  test('old firmware needs an update, and manual recording still works',
      () async {
    final (harness, background) = await started(newFirmware: false);

    await harness.controller.setContinuousEnabled(true);

    expect(harness.controller.continuousStatus,
        ContinuousStatus.needsFirmwareUpdate);
    expect(harness.controller.continuousActive, isFalse);
    expect(background.texts.last, 'Needs firmware update');
    verifyNever(() => harness.transport.writeCapture(any(), any()));

    await harness.controller.startRecording();
    expect(harness.controller.isRecording, isTrue);
    await harness.controller.stopRecording();
  });

  test('a manual recording on new firmware asks the device to stream '
      'everything first', () async {
    final (harness, _) = await started();

    await harness.controller.startRecording();

    verify(() => harness.transport
        .writeCapture(knownDevice.id, CaptureCommand.gateDisabled)).called(1);
    expect(harness.controller.isRecording, isTrue);
    await harness.controller.stopRecording();
  });

  test('turning it off stops listening and puts the device back', () async {
    final (harness, background) = await started();
    await harness.controller.setContinuousEnabled(true);
    clearInteractions(harness.transport);

    await harness.controller.setContinuousEnabled(false);

    verify(() => harness.transport
        .writeCapture(knownDevice.id, CaptureCommand.gateDisabled)).called(1);
    expect(harness.controller.continuousActive, isFalse);
    expect(harness.controller.isConnected, isTrue);
    expect(background.running, isFalse);
  });

  test('a dropped link is reconnected on its own, with no failure screen',
      () async {
    final (harness, background) = await started();
    await harness.controller.setContinuousEnabled(true);
    clearInteractions(harness.transport);

    harness.link.add(BleConnectionStatus.disconnected);
    await settle();

    expect(harness.controller.linkOutcome, LinkOutcome.none);
    verify(() => harness.transport.connect(
          knownDevice.id,
          timeout: ReconnectBackoff.attemptTimeout,
        )).called(1);
    expect(harness.controller.isConnected, isTrue);
    expect(harness.controller.continuousActive, isTrue);
    // Listening again on the new link.
    verify(() => harness.transport
        .writeCapture(knownDevice.id, CaptureCommand.gateEnabled)).called(1);
    expect(background.texts, contains('Device not connected'));
    expect(background.texts.last, 'Always listening');
  });

  test('without always listening a drop still shows the failure screen',
      () async {
    final (harness, _) = await started();

    harness.link.add(BleConnectionStatus.disconnected);
    await settle();

    expect(harness.controller.linkOutcome, LinkOutcome.connectionLost);
    verifyNever(() => harness.transport
        .connect(any(), timeout: ReconnectBackoff.attemptTimeout));
  });

  test('a failed attempt waits, and turning it off stops the trying',
      () async {
    final (harness, _) = await started();
    await harness.controller.setContinuousEnabled(true);
    when(() => harness.transport.connect(any(), timeout: any(named: 'timeout')))
        .thenThrow(const BleTransportException('out of range'));

    harness.link.add(BleConnectionStatus.disconnected);
    await settle();

    verify(() => harness.transport
        .connect(any(), timeout: ReconnectBackoff.attemptTimeout)).called(1);
    expect(harness.controller.phase, AppPhase.idle);
    expect(harness.controller.continuousStatus, ContinuousStatus.notConnected);
    expect(harness.controller.errorMessage, isNull);

    // The next attempt is two seconds out; it must not happen once off.
    await harness.controller.setContinuousEnabled(false);
    await Future<void>.delayed(const Duration(milliseconds: 2300));
    verifyNever(() => harness.transport
        .connect(any(), timeout: ReconnectBackoff.attemptTimeout));
  });

  test('Bluetooth coming back reconnects while always listening', () async {
    final (harness, _) = await started();
    await harness.controller.setContinuousEnabled(true);

    harness.adapter.add(BleAvailability.poweredOff);
    await settle();
    expect(harness.controller.isConnected, isFalse);
    verifyNever(() => harness.transport
        .connect(any(), timeout: ReconnectBackoff.attemptTimeout));

    harness.adapter.add(BleAvailability.poweredOn);
    await settle();
    verify(() => harness.transport.connect(
          knownDevice.id,
          timeout: ReconnectBackoff.attemptTimeout,
        )).called(1);
    expect(harness.controller.continuousActive, isTrue);
  });

  test('after a restart it reaches for the remembered device', () async {
    final (first, _) = await started();
    await first.controller.setContinuousEnabled(true);

    final background = FakeBackgroundMode();
    final again = ViewHarness(backgroundMode: background)
      ..captureSupported = true;
    addTearDown(again.dispose);
    again.fileStore.files.addAll(first.fileStore.files);

    await again.controller.initialise();
    await settle();

    verify(() => again.transport.connect(
          knownDevice.id,
          timeout: ReconnectBackoff.attemptTimeout,
        )).called(1);
    expect(again.controller.continuousEnabled, isTrue);
    expect(again.controller.continuousActive, isTrue);
    expect(background.running, isTrue);
  });

  test('Disconnect turns always listening off, and it stays off', () async {
    final (harness, background) = await started();
    await harness.controller.setContinuousEnabled(true);

    await harness.controller.disconnect();
    await settle();

    expect(harness.controller.continuousEnabled, isFalse);
    expect(background.running, isFalse);
    verifyNever(() => harness.transport
        .connect(any(), timeout: ReconnectBackoff.attemptTimeout));
  });

  test('it cannot be turned on with no device at all', () async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    await harness.controller.initialise();

    await harness.controller.setContinuousEnabled(true);

    expect(harness.controller.continuousEnabled, isFalse);
  });

  test('the background permissions are asked for only when missing',
      () async {
    final (harness, background) = await started();
    expect(await harness.controller.backgroundPermissionsGranted(), isTrue);
    await harness.controller.requestBackgroundPermissions();
    expect(background.permissionRequests, 0);

    background
      ..notifications = false
      ..batteryExempt = false;
    expect(await harness.controller.backgroundPermissionsGranted(), isFalse);
    await harness.controller.requestBackgroundPermissions();
    expect(background.permissionRequests, 2);
  });

  test('the notification is asked for first, and answered, before the second '
      'ask is raised', () async {
    final (harness, background) = await started();
    background
      ..notifications = false
      ..batteryExempt = false;

    await harness.controller.requestBackgroundPermissions();

    // Two system prompts at once is one the user never sees. The notification
    // prompt does not return until it has been answered, so the order here is
    // the order they appear in.
    expect(background.permissionOrder,
        <String>['notifications', 'backgroundWork']);
  });

  test('a permission already granted is not asked for again', () async {
    final (harness, background) = await started();
    background
      ..notifications = true
      ..batteryExempt = false;

    await harness.controller.requestBackgroundPermissions();

    expect(background.permissionOrder, <String>['backgroundWork']);
  });

  test('a keep-alive the OS refused is asked for again, not remembered as '
      'running', () async {
    final (harness, background) = await started();
    background.canStart = false;

    await harness.controller.setContinuousEnabled(true);
    await settle();
    expect(background.running, isFalse);

    // The phone changes its mind - the user granted the exemption, or the app
    // came back on screen. The same text must be asked for again; the old
    // code remembered the refusal as done and never retried.
    background.canStart = true;
    await harness.controller.appForegrounded();
    await settle();

    expect(background.running, isTrue);
    expect(background.texts.last, 'Always listening');
  });

  test('a service killed behind the app\'s back is asked for again',
      () async {
    final (harness, background) = await started();
    await harness.controller.setContinuousEnabled(true);
    await settle();
    expect(background.running, isTrue);
    final asks = background.texts.length;

    // A vendor task killer took it. Android says so on the channel.
    background.running = false;
    background.reportStopped();
    await harness.controller.appForegrounded();
    await settle();

    expect(background.texts.length, greaterThan(asks));
    expect(background.running, isTrue);
  });

  test('the note being written is marked, and cannot be deleted', () async {
    final (harness, _) = await started();
    await harness.controller.setContinuousEnabled(true);

    for (var i = 0; i < 150; i++) {
      final notification = Uint8List(642);
      notification[0] = i & 0xFF;
      harness.frames.add(notification);
    }
    await settle();
    await harness.controller.refreshLibrary();

    final writing = harness.controller.writingNotePath;
    expect(writing, isNotNull);
    final note = harness.controller.recordings.singleWhere((r) => r.path == writing);

    await harness.controller.deleteRecording(note);
    expect(harness.fileStore.files, contains(writing));

    // Turning it off closes and keeps the note.
    await harness.controller.setContinuousEnabled(false);
    await settle();
    expect(harness.controller.writingNotePath, isNull);
    expect(harness.controller.recordings.map((r) => r.path), contains(writing));
  });

  test('startup repairs a recording the app was killed in the middle of',
      () async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    final path = harness.fileStore.join(
      ViewHarness.recordingsDirectory,
      RecordingNaming.fileName(DateTime(2026, 9, 14, 9)),
    );
    harness.fileStore.files[path] = <int>[
      ...WavWriter.buildHeader(
        sampleRateHz: 16000,
        channels: 1,
        bitsPerSample: 16,
      ),
      ...Uint8List(32000 * 3),
    ];

    await harness.controller.initialise();

    expect(harness.controller.recordings.single.duration,
        const Duration(seconds: 3));
    expect(harness.fileStore.patched, contains(path));
  });
}
