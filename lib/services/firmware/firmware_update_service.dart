import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../drivers/ble_transport.dart';
import '../../drivers/firmware_installer.dart';
import '../../drivers/firmware_release_source.dart';
import '../../model/firmware_update.dart';
import '../../model/firmware_update_state.dart';
import 'bootloader_handoff.dart';
import 'firmware_check_store.dart';
import 'firmware_download.dart';

/// Over-the-air firmware updates, from "is there one?" to "the recorder is
/// running it".
///
/// THE RUN, AND WHY IN THIS ORDER. The bootloader's OTA mode never times out
/// and the transfer is single-bank - the old image is erased as soon as it
/// starts - so every step that can fail cheaply happens first:
///
///   1. download the package and check its sha256 (nothing touched yet);
///   2. write `OTA!` to `fe06` (the firmware refuses it off USB power);
///   3. wait for the link to drop, then scan for `AdaDFU`;
///   4. hand the package to the DFU library;
///   5. wait for the recorder to reconnect and read `fe0a` again, because
///      "the library said it finished" is not "the recorder runs it".
///
/// After step 2 a failure leaves the recorder in its bootloader, still
/// advertising. So the package is kept and [retry] resumes at step 3.
///
/// It learns about the recorder from [observeRecorder], fed by whatever owns
/// the connection, and talks to it only through [BleTransport].
class FirmwareUpdateService {
  FirmwareUpdateService({
    required this._transport,
    required this._releases,
    required this._installer,
    required this._download,
    required this._store,
    DateTime Function()? now,
    this.checkInterval = const Duration(days: 1),
    Duration refusalGrace = const Duration(seconds: 3),
    Duration restartTimeout = const Duration(seconds: 10),
    Duration bootloaderTimeout = const Duration(seconds: 30),
    Duration bootloaderSettle = const Duration(seconds: 2),
    this.returnTimeout = const Duration(minutes: 2),
  })  : _now = now ?? DateTime.now,
        _handoff = BootloaderHandoff(
          transport: _transport,
          refusalGrace: refusalGrace,
          restartTimeout: restartTimeout,
          bootloaderTimeout: bootloaderTimeout,
          bootloaderSettle: bootloaderSettle,
        );

  final BleTransport _transport;
  final FirmwareReleaseSource _releases;
  final FirmwareInstaller _installer;
  final FirmwareDownload _download;
  final FirmwareCheckStore _store;
  final DateTime Function() _now;
  final BootloaderHandoff _handoff;

  /// GitHub allows 60 unauthenticated requests an hour; firmware ships far
  /// less often than daily.
  final Duration checkInterval;

  /// How long the recorder has to boot the new image and reconnect.
  final Duration returnTimeout;

  final ValueNotifier<UpdateState> _state =
      ValueNotifier<UpdateState>(const UpdateIdle());

  String? _deviceId;
  String? _recorderAddress;
  bool _charging = false;
  bool _externalPower = false;
  FirmwareVersion? _installed;
  FirmwareRelease? _latest;
  DateTime? _lastAttempt;
  String? _readyPath;
  bool _running = false;
  bool _otaRequested = false;
  bool _disposed = false;
  Completer<void>? _dropWaiter;
  Completer<FirmwareVersion?>? _returnWaiter;

  ValueListenable<UpdateState> get state => _state;
  FirmwareVersion? get installedVersion => _installed;
  FirmwareRelease? get latestRelease => _latest;

  UpdateDecision get decision => UpdateDecision.evaluate(
        current: _installed,
        latest: _latest,
        charging: _charging,
        externalPower: _externalPower,
        connected: _deviceId != null,
      );

  /// Loads what the last check found and whether its package is already here.
  Future<void> initialise() async {
    final check = await _store.load();
    _latest = check?.latest;
    _lastAttempt = check?.checkedAt;
    final latest = _latest;
    if (latest != null) _readyPath = await _download.verifiedPath(latest);
    _refresh();
  }

  /// The recorder as its owner sees it. Cheap when nothing changed, so it can
  /// be called on every notification of the app's controller.
  void observeRecorder({
    required String? deviceId,
    required bool charging,
    required bool externalPower,
  }) {
    final changed = deviceId != _deviceId;
    _charging = charging;
    _externalPower = externalPower;
    if (changed) {
      _deviceId = deviceId;
      if (deviceId == null) {
        if (!(_dropWaiter?.isCompleted ?? true)) _dropWaiter!.complete();
      } else {
        _recorderAddress = deviceId;
        unawaited(_onConnected(deviceId));
      }
    }
    _refresh();
  }

  Future<void> _onConnected(String deviceId) async {
    final version = await _readVersion(deviceId);
    // An application answered, so the recorder is not in its bootloader.
    _otaRequested = false;
    final waiter = _returnWaiter;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete(version);
      return;
    }
    // A cached release for another build is no use: look again at once.
    final cached = _latest?.version.variant;
    final mismatch = version != null && _latest != null && cached != version.variant;
    if (!_running) await checkForUpdate(force: mismatch);
  }

  Future<FirmwareVersion?> _readVersion(String deviceId) async {
    try {
      final text = await _transport.readFirmwareVersion(deviceId);
      _installed = FirmwareVersion.tryParse(text);
    } on BleTransportException {
      _installed = null;
    }
    _refresh();
    return _installed;
  }

  /// Asks the release host for the newest firmware, unless that was done less
  /// than [checkInterval] ago. Never throws.
  Future<void> checkForUpdate({bool force = false}) async {
    if (_running) return;
    final last = _lastAttempt;
    if (!force && last != null && _now().difference(last) < checkInterval) {
      return;
    }
    // Recorded before the request, so a phone with no network asks once per
    // interval per launch rather than on every reconnect. Only a check that
    // found something is saved; one that failed is retried next launch.
    _lastAttempt = _now();
    // A failure or a finished update stays on screen through a check.
    final current = _state.value;
    final show = current is! UpdateFailed && current is! UpdateDone;
    if (show) _set(const UpdateChecking());
    final latest = await _releases.latest(variant: _installed?.variant);
    if (latest != null) {
      _latest = latest;
      _readyPath = await _download.verifiedPath(latest);
      try {
        await _store.save(FirmwareCheck(checkedAt: _now(), latest: latest));
      } on Object {
        // Unsaved, the next launch simply asks again.
      }
    }
    if (show) _set(const UpdateIdle());
    _refresh();
  }

  /// Fetches and verifies the package without touching the recorder.
  Future<void> download() async {
    final release = _latest;
    if (_running || release == null) return;
    _running = true;
    try {
      await _fetch(release);
    } finally {
      _running = false;
    }
    _refresh();
  }

  Future<bool> _fetch(FirmwareRelease release) async {
    _set(UpdateDownloading(release, bytesDone: 0));
    try {
      _readyPath = await _download.fetch(
        release,
        onProgress: (bytes) =>
            _set(UpdateDownloading(release, bytesDone: bytes)),
      );
      await _download.prune(keep: release);
      _set(UpdateReadyToInstall(release));
      return true;
    } on FirmwareDownloadException catch (error) {
      _fail(
        switch (error.fault) {
          FirmwareDownloadFault.network => UpdateFailure.download,
          FirmwareDownloadFault.checksum => UpdateFailure.checksumMismatch,
          FirmwareDownloadFault.storage => UpdateFailure.storage,
        },
        release,
        canRetry: true,
        detail: error.message,
      );
      return false;
    }
  }

  /// The whole run. Only for a release newer than the recorder's; the
  /// charger check is left to the firmware, which is the authority on it.
  Future<void> install() async {
    final release = _latest;
    if (_running || release == null) return;
    final allowed = switch (decision) {
      UpdateOffered() => true,
      UpdateBlocked(reason: UpdateBlockReason.notOnCharger) => true,
      UpdateBlocked(reason: UpdateBlockReason.notConnected) => true,
      _ => false,
    };
    if (!allowed) return;
    _running = true;
    try {
      if (!await _fetch(release)) return;
      final deviceId = _deviceId;
      if (deviceId == null) {
        _fail(UpdateFailure.notConnected, release, canRetry: true);
        return;
      }
      if (!await _enterBootloader(deviceId, release)) return;
      await _sendToBootloader(release);
    } finally {
      _running = false;
    }
  }

  /// Picks the run up where it stopped: at the bootloader when `OTA!` was
  /// already taken and the recorder has not come back, from the top otherwise.
  Future<void> retry() async {
    final current = _state.value;
    final release = _latest;
    if (_running || current is! UpdateFailed || !current.canRetry) return;
    if (release == null) return;
    if (_deviceId == null && _otaRequested) {
      _running = true;
      try {
        await _sendToBootloader(release);
      } finally {
        _running = false;
      }
      return;
    }
    _set(const UpdateIdle());
    await install();
  }

  /// Clears a finished or failed run off the screen.
  void dismiss() {
    if (_running) return;
    _set(const UpdateIdle());
    _refresh();
  }

  Future<bool> _enterBootloader(String deviceId, FirmwareRelease release) async {
    _set(UpdateWaitingForBootloader(release));
    final dropped = _dropWaiter = Completer<void>();
    final (outcome, refusal) =
        await _handoff.requestOta(deviceId, ownerSawDrop: dropped.future);
    _dropWaiter = null;
    // An accepted write may have rebooted it with the drop missed: then
    // [retry] should look for the bootloader rather than write again.
    _otaRequested = outcome != OtaRequestOutcome.refused;
    switch (outcome) {
      case OtaRequestOutcome.rebooted:
        // The link is gone whether or not its owner has said so yet, and the
        // recorder coming back must read as a new connection.
        _deviceId = null;
        return true;
      case OtaRequestOutcome.refused:
        _fail(UpdateFailure.triggerRefused, release,
            canRetry: true, detail: '$refusal');
        return false;
      case OtaRequestOutcome.didNotRestart:
        _fail(UpdateFailure.recorderDidNotRestart, release, canRetry: true);
        return false;
    }
  }

  Future<void> _sendToBootloader(FirmwareRelease release) async {
    final zip = _readyPath ?? await _download.verifiedPath(release);
    if (zip == null) {
      _fail(UpdateFailure.storage, release, canRetry: false);
      return;
    }
    _set(UpdateWaitingForBootloader(release));
    final bootloader = await _handoff.findBootloader(_recorderAddress);
    if (bootloader == null) {
      _fail(UpdateFailure.bootloaderNotFound, release, canRetry: true);
      return;
    }
    _set(UpdateTransferring(release, percent: 0));
    final returned = _returnWaiter = Completer<FirmwareVersion?>();
    try {
      await _installer.install(
        deviceId: bootloader.id,
        zipPath: zip,
        onProgress: (percent) =>
            _set(UpdateTransferring(release, percent: percent)),
      );
    } on FirmwareInstallException catch (error) {
      _returnWaiter = null;
      _fail(UpdateFailure.transferFailed, release,
          canRetry: true, detail: error.toString());
      return;
    }
    _set(UpdateConfirming(release));
    final version = await returned.future
        .then<FirmwareVersion?>((v) => v)
        .timeout(returnTimeout, onTimeout: () => null);
    final cameBack = returned.isCompleted;
    _returnWaiter = null;
    if (!cameBack) {
      _fail(UpdateFailure.recorderDidNotReturn, release, canRetry: false);
    } else if (version != release.version ||
        version?.variant != release.version.variant) {
      _fail(UpdateFailure.versionMismatch, release,
          canRetry: false,
          detail: 'the recorder reports ${version?.full ?? 'no readable version'}');
    } else {
      _otaRequested = false;
      _readyPath = null;
      await _download.prune();
      _set(UpdateDone(version!));
    }
  }

  void _fail(
    UpdateFailure reason,
    FirmwareRelease release, {
    required bool canRetry,
    String? detail,
  }) =>
      _set(UpdateFailed(reason,
          canRetry: canRetry, release: release, detail: detail));

  /// The resting state, from what is known - unless a run is under way or
  /// its outcome is still on screen.
  void _refresh() {
    final current = _state.value;
    if (_running || current is UpdateFailed || current is UpdateDone) return;
    if (current is UpdateChecking) return;
    final blockedBy = switch (decision) {
      UpdateBlocked(:final reason) => reason,
      _ => null,
    };
    final next = switch (decision) {
      UpdateNone() => const UpdateIdle(),
      UpdateOffered(:final release) || UpdateBlocked(:final release) =>
        _readyPath != null
            ? UpdateReadyToInstall(release, blockedBy: blockedBy)
            : UpdateAvailable(release, blockedBy: blockedBy),
    };
    _set(next);
  }

  /// A read or a check still in flight when the service is disposed has
  /// nobody left to tell.
  void _set(UpdateState next) {
    if (!_disposed) _state.value = next;
  }

  void dispose() {
    _disposed = true;
    _state.dispose();
  }
}
