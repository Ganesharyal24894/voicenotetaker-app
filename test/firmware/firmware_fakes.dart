import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/drivers/ble_transport.dart';
import 'package:voicenotetaker_app/drivers/download_client.dart';
import 'package:voicenotetaker_app/drivers/firmware_installer.dart';
import 'package:voicenotetaker_app/drivers/firmware_release_source.dart';
import 'package:voicenotetaker_app/model/device_state.dart';
import 'package:voicenotetaker_app/model/firmware_update.dart';

/// A scripted HTTP server: each URL answers with its status and bytes.
class FakeDownloadClient implements DownloadClient {
  final Map<String, (int, List<int>)> routes = <String, (int, List<int>)>{};
  final List<String> requested = <String>[];
  bool offline = false;

  void text(String url, String body, {int status = 200}) =>
      routes[url] = (status, utf8.encode(body));

  @override
  Future<DownloadResponse> get(String url, {int from = 0}) async {
    requested.add(url);
    if (offline) throw const DownloadException('no network');
    final (status, bytes) = routes[url] ?? (404, const <int>[]);
    final body = from > 0 && status == 200 ? bytes.sublist(from) : bytes;
    return DownloadResponse(
      statusCode: from > 0 && status == 200 ? 206 : status,
      contentLength: body.length,
      body: Stream<List<int>>.value(body),
      abort: () async {},
    );
  }

  @override
  void close() {}
}

/// The firmware package the tests publish, with its real digest.
final List<int> packageBytes = List<int>.generate(3000, (i) => i * 7 & 0xFF);
final String packageSha = sha256.convert(packageBytes).toString();

FirmwareRelease releaseOf(String version, {String? sha, int? size}) =>
    FirmwareRelease(
      version: FirmwareVersion.tryParse(version)!,
      zipName: 'voiceNotetaker-$version.zip',
      zipUrl: 'https://example.test/voiceNotetaker-$version.zip',
      sha256: sha ?? packageSha,
      sizeBytes: size ?? packageBytes.length,
      publishedAt: DateTime.utc(2026, 10, 18),
      notes: '',
    );

class FakeReleaseSource implements FirmwareReleaseSource {
  FakeReleaseSource(this.release);

  FirmwareRelease? release;
  int calls = 0;

  @override
  Future<FirmwareRelease?> latest() async {
    calls++;
    return release;
  }
}

/// The recorder and its bootloader, as far as the update service sees them.
class FakeTransport extends Fake implements BleTransport {
  String firmwareVersion = '0.1.0';
  bool refuseOta = false;

  /// Whether an accepted `OTA!` drops the link, as the real reboot does.
  bool otaDropsLink = true;

  /// What each bootloader scan reports.
  List<DiscoveredDevice> bootloaders = <DiscoveredDevice>[];
  int otaWrites = 0;
  int scans = 0;
  final StreamController<BleConnectionStatus> link =
      StreamController<BleConnectionStatus>.broadcast();

  @override
  Future<String> readFirmwareVersion(String deviceId) async => firmwareVersion;

  @override
  Stream<BleConnectionStatus> connectionState(String deviceId) => link.stream;

  @override
  Future<void> requestOtaBootloader(String deviceId) async {
    otaWrites++;
    // [otaDropsLink] with [refuseOta]: the reboot beat the write response, so
    // the write errors AND the link goes - the case the handoff must read as
    // "taken", not "refused". Scheduled from here, not from the test, so it
    // cannot fire before the write is attempted.
    if (otaDropsLink) {
      scheduleMicrotask(() => link.add(BleConnectionStatus.disconnected));
    }
    if (refuseOta) throw const BleTransportException('ATT 0x13');
  }

  @override
  Stream<DiscoveredDevice> scanForDfuBootloader({required Duration window}) {
    scans++;
    return Stream<DiscoveredDevice>.fromIterable(bootloaders);
  }
}

class FakeInstaller implements FirmwareInstaller {
  /// Failures still to report before a transfer succeeds.
  int failuresLeft = 0;
  final List<String> targets = <String>[];
  void Function()? onFinished;

  @override
  Future<void> install({
    required String deviceId,
    required String zipPath,
    required void Function(int percent) onProgress,
  }) async {
    targets.add(deviceId);
    onProgress(50);
    if (failuresLeft > 0) {
      failuresLeft--;
      throw const FirmwareInstallException('Operation failed');
    }
    onProgress(100);
    onFinished?.call();
  }

  @override
  Future<void> abort() async {}
}
