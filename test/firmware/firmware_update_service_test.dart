import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/drivers/file_store.dart';
import 'package:voicenotetaker_app/drivers/hashing_crypto.dart';
import 'package:voicenotetaker_app/model/device_state.dart';
import 'package:voicenotetaker_app/model/firmware_update.dart';
import 'package:voicenotetaker_app/model/firmware_update_state.dart';
import 'package:voicenotetaker_app/services/firmware/firmware_check_store.dart';
import 'package:voicenotetaker_app/services/firmware/firmware_download.dart';
import 'package:voicenotetaker_app/services/firmware/firmware_update_service.dart';

import 'firmware_fakes.dart';

const String recorder = 'C0:11:22:33:44:55';
const DiscoveredDevice ownBootloader =
    DiscoveredDevice(id: 'C0:11:22:33:44:56', name: 'AdaDFU', rssi: -70);
const DiscoveredDevice stranger =
    DiscoveredDevice(id: 'D0:00:00:00:00:01', name: 'AdaDFU', rssi: -40);

void main() {
  late Directory temp;
  late FakeDownloadClient client;
  late FakeTransport transport;
  late FakeInstaller installer;
  late FakeReleaseSource releases;
  late DateTime now;
  late FirmwareUpdateService service;
  late List<UpdateState> states;
  const store = IoFileStore();

  FirmwareUpdateService build() {
    final built = FirmwareUpdateService(
      transport: transport,
      releases: releases,
      installer: installer,
      download: FirmwareDownload(
        fileStore: store,
        client: client,
        hashing: const CryptoHashing(),
        directory: store.join(temp.path, 'firmware'),
      ),
      store: FirmwareCheckStore(fileStore: store, directory: temp.path),
      now: () => now,
      refusalGrace: const Duration(milliseconds: 30),
      restartTimeout: const Duration(milliseconds: 60),
      bootloaderTimeout: const Duration(milliseconds: 80),
      bootloaderSettle: const Duration(milliseconds: 20),
      returnTimeout: const Duration(milliseconds: 150),
    );
    built.state.addListener(() => states.add(built.state.value));
    return built;
  }

  /// The recorder connecting, then the version read and the check settling.
  Future<void> connect({bool charging = true, bool externalPower = true}) async {
    service.observeRecorder(
        deviceId: recorder, charging: charging, externalPower: externalPower);
    await pumpEventQueue();
    // The check touches real files, which the microtask queue does not cover.
    for (var i = 0; i < 200 && service.state.value is UpdateChecking; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  /// What the app's controller does when the new image boots: the link comes
  /// back and the recorder reports [version].
  void comesBackAs(String version) {
    installer.onFinished = () {
      transport.firmwareVersion = version;
      service.observeRecorder(
          deviceId: recorder, charging: true, externalPower: true);
    };
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('firmware_test');
    client = FakeDownloadClient();
    transport = FakeTransport()..bootloaders = [stranger, ownBootloader];
    installer = FakeInstaller();
    final release = releaseOf('0.2.0');
    releases = FakeReleaseSource(release);
    client.routes[release.zipUrl] = (200, packageBytes);
    now = DateTime.utc(2026, 10, 18, 9);
    states = <UpdateState>[];
    service = build();
    await service.initialise();
  });

  tearDown(() async {
    service.dispose();
    await transport.link.close();
    await temp.delete(recursive: true);
  });

  test('connecting reads fe0a and offers the newer release', () async {
    await connect();
    expect(service.installedVersion, FirmwareVersion.tryParse('0.1.0'));
    expect(service.state.value, isA<UpdateAvailable>());
    expect((service.state.value as UpdateAvailable).blockedBy, isNull);
  });

  test('external power is enough, even with the cell not charging', () async {
    await connect(charging: false, externalPower: true);
    expect((service.state.value as UpdateAvailable).blockedBy, isNull);
  });

  test('an sd recorder asks for, and is offered, the sd zip only', () async {
    final plain = releaseOf('0.2.0');
    final sd = releaseOf('0.2.0', variant: 'sd');
    releases.byVariant = {null: plain, 'sd': sd};
    transport.firmwareVersion = '0.1.0+sd';
    await connect();
    expect(releases.askedVariants, ['sd']);
    expect(service.latestRelease!.zipName, 'voiceNotetaker-0.2.0-sd.zip');
    expect((service.state.value as UpdateAvailable).blockedBy, isNull);
  });

  test('a default recorder asks for, and is offered, the plain zip only',
      () async {
    releases.byVariant = {
      null: releaseOf('0.2.0'),
      'sd': releaseOf('0.2.0', variant: 'sd'),
    };
    await connect();
    expect(releases.askedVariants, [null]);
    expect(service.latestRelease!.zipName, 'voiceNotetaker-0.2.0.zip');
  });

  test('a cached release for another build is replaced at once', () async {
    await connect(); // caches the default zip for a default recorder
    service.observeRecorder(
        deviceId: null, charging: false, externalPower: false);
    final sd = releaseOf('0.2.0', variant: 'sd');
    releases.byVariant = {null: releaseOf('0.2.0'), 'sd': sd};
    transport.firmwareVersion = '0.1.0+sd';
    await connect();
    expect(releases.askedVariants.last, 'sd', reason: 'not held off a day');
    expect(service.latestRelease!.zipName, sd.zipName);
  });

  test('the confirm step compares the variant too', () async {
    final sd = releaseOf('0.2.0', variant: 'sd');
    releases.release = sd;
    client.routes[sd.zipUrl] = (200, packageBytes);
    transport.firmwareVersion = '0.1.0+sd';
    await connect();
    comesBackAs('0.2.0');
    await service.install();
    expect((service.state.value as UpdateFailed).reason,
        UpdateFailure.versionMismatch);
  });

  test('the confirm step passes when number and variant both match',
      () async {
    final sd = releaseOf('0.2.0', variant: 'sd');
    releases.release = sd;
    client.routes[sd.zipUrl] = (200, packageBytes);
    transport.firmwareVersion = '0.1.0+sd';
    await connect();
    comesBackAs('0.2.0+sd');
    await service.install();
    expect(service.state.value, isA<UpdateDone>());
  });

  test('off the charger the offer says why it cannot start', () async {
    await connect(charging: false, externalPower: false);
    expect((service.state.value as UpdateAvailable).blockedBy,
        UpdateBlockReason.notOnCharger);
  });

  test('a downgrade is never offered or installed', () async {
    transport.firmwareVersion = '0.3.0';
    await connect();
    expect(service.state.value, isA<UpdateIdle>());
    await service.install();
    expect(transport.otaWrites, 0);
    expect(client.requested, isEmpty);
  });

  test('the release host is asked at most once a day, across launches',
      () async {
    await connect();
    service.observeRecorder(
        deviceId: null, charging: false, externalPower: false);
    await connect();
    expect(releases.calls, 1);

    service.dispose();
    service = build();
    await service.initialise();
    await connect();
    expect(releases.calls, 1, reason: 'the check was saved');
    expect(service.state.value, isA<UpdateAvailable>(),
        reason: 'what it found was saved too');

    now = now.add(const Duration(hours: 25));
    service.observeRecorder(
        deviceId: null, charging: false, externalPower: false);
    await connect();
    expect(releases.calls, 2);
  });

  test('happy path: verified, OTA!, own bootloader, sent, confirmed',
      () async {
    await connect();
    comesBackAs('0.2.0');
    await service.install();

    expect(transport.otaWrites, 1);
    expect(installer.targets, [ownBootloader.id],
        reason: 'the address + 1 beats a louder AdaDFU');
    expect(service.state.value, isA<UpdateDone>());
    expect((service.state.value as UpdateDone).version,
        FirmwareVersion.tryParse('0.2.0'));
    expect(
      states.map((s) => s.runtimeType).toSet(),
      containsAll(<Type>[
        UpdateDownloading,
        UpdateReadyToInstall,
        UpdateWaitingForBootloader,
        UpdateTransferring,
        UpdateConfirming,
        UpdateDone,
      ]),
    );
    expect(
      states.whereType<UpdateTransferring>().map((s) => s.percent),
      containsAllInOrder(<int>[0, 50, 100]),
    );
    expect(await store.list(store.join(temp.path, 'firmware')), isEmpty,
        reason: 'the package is not kept once it is running');
  });

  test('a checksum mismatch stops before the recorder is touched', () async {
    releases.release = releaseOf('0.2.0', sha: 'f' * 64);
    await connect();
    await service.install();

    final failed = service.state.value as UpdateFailed;
    expect(failed.reason, UpdateFailure.checksumMismatch);
    expect(failed.canRetry, isTrue);
    expect(transport.otaWrites, 0);
    expect(await store.list(store.join(temp.path, 'firmware')), isEmpty,
        reason: 'the bad bytes are not kept to be resumed');
  });

  test('a refused OTA! is reported and nothing is scanned for', () async {
    // A real refusal: the write errors and the link stays up.
    transport
      ..refuseOta = true
      ..otaDropsLink = false;
    await connect(charging: false, externalPower: false);
    await service.install();

    final failed = service.state.value as UpdateFailed;
    expect(failed.reason, UpdateFailure.triggerRefused);
    expect(failed.canRetry, isTrue);
    expect(transport.scans, 0);
    expect(installer.targets, isEmpty);
  });

  test('a write that errors while the link drops is still taken', () async {
    // The reboot beat the write response: the write throws, the link drops.
    transport
      ..refuseOta = true
      ..otaDropsLink = true;
    await connect();
    comesBackAs('0.2.0');
    await service.install();
    expect(service.state.value, isA<UpdateDone>());
  });

  test('no bootloader within the timeout fails, and can be retried',
      () async {
    transport.bootloaders = const [];
    await connect();
    await service.install();

    final failed = service.state.value as UpdateFailed;
    expect(failed.reason, UpdateFailure.bootloaderNotFound);
    expect(failed.canRetry, isTrue);

    transport.bootloaders = const [ownBootloader];
    comesBackAs('0.2.0');
    await service.retry();
    expect(transport.otaWrites, 1, reason: 'OTA mode never times out');
    expect(service.state.value, isA<UpdateDone>());
  });

  test('a scan that never ends still gives up at the timeout', () async {
    final silent = StreamController<DiscoveredDevice>();
    final hanging = _HangingScanTransport(silent.stream);
    transport = hanging;
    service.dispose();
    service = build();
    await service.initialise();
    await connect();
    await service.install()
        .timeout(const Duration(seconds: 2));
    expect((service.state.value as UpdateFailed).reason,
        UpdateFailure.bootloaderNotFound);
    await silent.close();
  });

  test('a transfer failure keeps the package; retry resumes at the bootloader',
      () async {
    installer.failuresLeft = 1;
    await connect();
    await service.install();

    final failed = service.state.value as UpdateFailed;
    expect(failed.reason, UpdateFailure.transferFailed);
    expect(failed.canRetry, isTrue);
    expect(await store.list(store.join(temp.path, 'firmware')), hasLength(1));

    comesBackAs('0.2.0');
    await service.retry();
    expect(transport.otaWrites, 1, reason: 'no second OTA!');
    expect(client.requested, hasLength(1), reason: 'no second download');
    expect(installer.targets, hasLength(2));
    expect(service.state.value, isA<UpdateDone>());
  });

  test('the version is confirmed by fe0a after the reboot, not assumed',
      () async {
    await connect();
    comesBackAs('0.1.0');
    await service.install();

    final failed = service.state.value as UpdateFailed;
    expect(failed.reason, UpdateFailure.versionMismatch);
    expect(failed.canRetry, isFalse);
  });

  test('a recorder that never comes back is reported, not reported done',
      () async {
    await connect();
    await service.install();
    expect((service.state.value as UpdateFailed).reason,
        UpdateFailure.recorderDidNotReturn);
  });
}

/// A transport whose bootloader scan neither finds anything nor ends.
class _HangingScanTransport extends FakeTransport {
  _HangingScanTransport(this._scan);

  final Stream<DiscoveredDevice> _scan;

  @override
  Stream<DiscoveredDevice> scanForDfuBootloader({required Duration window}) =>
      _scan;
}
