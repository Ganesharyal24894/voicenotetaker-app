import 'firmware_update.dart';

/// Where an over-the-air firmware update stands, for a screen to render.
///
/// One value at a time, pushed by `FirmwareUpdateService`. Each step of the
/// run is its own state because each one fails differently and needs
/// different words: a download can simply be tried again, while a failure
/// after `OTA!` leaves the recorder waiting in its bootloader with no
/// application until a transfer finishes.
sealed class UpdateState {
  const UpdateState();
}

/// Nothing happening, and nothing to offer.
class UpdateIdle extends UpdateState {
  const UpdateIdle();

  @override
  bool operator ==(Object other) => other is UpdateIdle;

  @override
  int get hashCode => 0;

  @override
  String toString() => 'UpdateIdle';
}

/// Asking the release host for the latest firmware.
class UpdateChecking extends UpdateState {
  const UpdateChecking();

  @override
  String toString() => 'UpdateChecking';
}

/// Newer firmware exists. [blockedBy] is what must change before it can be
/// installed, or null when it can be installed now.
class UpdateAvailable extends UpdateState {
  const UpdateAvailable(this.release, {this.blockedBy});

  final FirmwareRelease release;
  final UpdateBlockReason? blockedBy;

  // Equality, so that re-deriving the same resting state on every recorder
  // notification does not notify a screen: `ValueNotifier` skips equal values.
  @override
  bool operator ==(Object other) =>
      other is UpdateAvailable &&
      other.blockedBy == blockedBy &&
      other.release.version == release.version;

  @override
  int get hashCode => Object.hash(1, blockedBy, release.version);

  @override
  String toString() => 'UpdateAvailable(${release.version}'
      '${blockedBy == null ? '' : ', blocked: ${blockedBy!.name}'})';
}

/// Fetching the package onto the phone.
class UpdateDownloading extends UpdateState {
  const UpdateDownloading(this.release, {required this.bytesDone});

  final FirmwareRelease release;
  final int bytesDone;

  /// 0..1, for a bar.
  double get fraction => release.sizeBytes <= 0
      ? 0
      : (bytesDone / release.sizeBytes).clamp(0.0, 1.0);

  @override
  String toString() => 'UpdateDownloading(${release.version}, $bytesDone B)';
}

/// The package is on the phone and its sha256 matched. Nothing has been sent
/// to the recorder yet; [blockedBy] says whether it can be now.
class UpdateReadyToInstall extends UpdateState {
  const UpdateReadyToInstall(this.release, {this.blockedBy});

  final FirmwareRelease release;
  final UpdateBlockReason? blockedBy;

  @override
  bool operator ==(Object other) =>
      other is UpdateReadyToInstall &&
      other.blockedBy == blockedBy &&
      other.release.version == release.version;

  @override
  int get hashCode => Object.hash(2, blockedBy, release.version);

  @override
  String toString() => 'UpdateReadyToInstall(${release.version}'
      '${blockedBy == null ? '' : ', blocked: ${blockedBy!.name}'})';
}

/// `OTA!` was accepted (or is being sent) and the phone is looking for the
/// bootloader. From here on the recorder is not recording.
class UpdateWaitingForBootloader extends UpdateState {
  const UpdateWaitingForBootloader(this.release);

  final FirmwareRelease release;

  @override
  String toString() => 'UpdateWaitingForBootloader(${release.version})';
}

/// The DFU library is sending the image.
class UpdateTransferring extends UpdateState {
  const UpdateTransferring(this.release, {required this.percent});

  final FirmwareRelease release;

  /// 0..100, as the DFU library reports it.
  final int percent;

  @override
  String toString() => 'UpdateTransferring(${release.version}, $percent%)';
}

/// The transfer finished; waiting for the recorder to boot the new image and
/// reconnect, so its `fe0a` can confirm what is really running.
class UpdateConfirming extends UpdateState {
  const UpdateConfirming(this.release);

  final FirmwareRelease release;

  @override
  String toString() => 'UpdateConfirming(${release.version})';
}

/// The recorder reconnected and reported [version].
class UpdateDone extends UpdateState {
  const UpdateDone(this.version);

  final FirmwareVersion version;

  @override
  String toString() => 'UpdateDone($version)';
}

/// Why a run stopped.
enum UpdateFailure {
  /// The package could not be fetched.
  download,

  /// The package arrived, but not the bytes that were published. It is
  /// deleted; a retry downloads it again.
  checksumMismatch,

  /// The phone could not keep the package.
  storage,

  /// Not connected to the recorder when `OTA!` had to be written.
  notConnected,

  /// The recorder refused `OTA!` - most likely because it is not on its
  /// charger, which the firmware answers with the same ATT error as a wrong
  /// value - or the write never arrived.
  triggerRefused,

  /// `OTA!` was accepted but the link never dropped.
  recorderDidNotRestart,

  /// No `AdaDFU` was seen in time. The recorder may still be waiting in its
  /// bootloader, which never times out, so looking again is worth it.
  bootloaderNotFound,

  /// The DFU library reported an error. The bootloader goes back to
  /// advertising, so the transfer can be started again.
  transferFailed,

  /// The transfer finished but the recorder did not reconnect in time.
  recorderDidNotReturn,

  /// The recorder reconnected but still reports another version.
  versionMismatch,
}

/// A run stopped at [reason]. [canRetry] says whether `retry()` has
/// something to do; [detail] is for a log, not for the screen.
class UpdateFailed extends UpdateState {
  const UpdateFailed(
    this.reason, {
    required this.canRetry,
    this.release,
    this.detail,
  });

  final UpdateFailure reason;
  final bool canRetry;
  final FirmwareRelease? release;
  final String? detail;

  @override
  String toString() => 'UpdateFailed(${reason.name}, canRetry: $canRetry'
      '${detail == null ? '' : ', $detail'})';
}
