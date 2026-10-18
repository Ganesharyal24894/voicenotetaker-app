/// Raised when a DFU transfer did not finish, so the service never has to
/// catch a package's exception type.
class FirmwareInstallException implements Exception {
  const FirmwareInstallException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() =>
      'FirmwareInstallException: $message${cause == null ? '' : ' ($cause)'}';
}

/// Sends a Nordic legacy DFU package to a bootloader that is already
/// advertising.
///
/// Only the transfer. Getting the recorder into its bootloader (`OTA!` on
/// `fe06`) and finding the bootloader are the BLE transport's job, so this
/// seam is exactly the part the DFU library owns - and a fake of it is all
/// the update service's tests need.
abstract class FirmwareInstaller {
  /// Pushes [zipPath] to the bootloader at [deviceId] - a MAC on Android, a
  /// CoreBluetooth identifier on iOS - reporting 0..100 through [onProgress].
  ///
  /// Completes when the bootloader has accepted the image and reset into it.
  /// Throws [FirmwareInstallException] for anything else; the bootloader then
  /// goes back to advertising and the call can be made again.
  Future<void> install({
    required String deviceId,
    required String zipPath,
    required void Function(int percent) onProgress,
  });

  /// Stops a transfer in progress. The old image is already gone by then, so
  /// this is for leaving a screen, not for undoing anything.
  Future<void> abort();
}
