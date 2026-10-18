import 'package:nordic_dfu/nordic_dfu.dart';

import '../model/dfu_bootloader.dart';
import 'firmware_installer.dart';

/// [FirmwareInstaller] over `nordic_dfu`, which wraps Nordic's own Android
/// and iOS DFU libraries.
///
/// The ONLY file that names the package.
///
/// THE SETTINGS, AND WHY.
///
///   * PRN 8 on both platforms. The Adafruit bootloader (0.6.x - 0.9.x) needs
///     a packet receipt notification every 8 packets or fewer. Android's
///     library turns PRNs off on Android 6+ unless told otherwise, and iOS's
///     defaults to 12, so neither default works. `numberOfPackets` is the
///     plugin's platform-neutral value (iOS falls back to it), and each
///     platform's own field is set too so neither depends on that fallback.
///   * No higher MTU on Android, by default. Legacy DFU writes 20-byte
///     packets without response; a link that negotiated a larger MTU can have
///     them rejected at the ATT layer and the transfer stalls with no error
///     (the plugin's own note on `disableMtuRequest`, and ZMK's experience:
///     "Operation failed" early means turn the high-MTU request off). Kept
///     switchable for a bootloader from 0.10.0 on, which negotiates above 20.
///     iOS offers no such switch: CoreBluetooth negotiates the MTU itself and
///     the app cannot ask it not to.
///   * Android runs the transfer in the plugin's foreground service, so it
///     survives the app going to the background. Its permissions
///     (`FOREGROUND_SERVICE_CONNECTED_DEVICE`) are in the app manifest
///     already, for always-listening.
class NordicDfuFirmwareInstaller implements FirmwareInstaller {
  NordicDfuFirmwareInstaller({this.androidDisableMtuRequest = true});

  /// See the class comment. True unless a bootloader that handles a larger
  /// MTU is known to be on the board.
  final bool androidDisableMtuRequest;

  final NordicDfu _dfu = NordicDfu();

  @override
  Future<void> install({
    required String deviceId,
    required String zipPath,
    required void Function(int percent) onProgress,
  }) async {
    String? error;
    try {
      await _dfu.startDfu(
        deviceId,
        zipPath,
        numberOfPackets: DfuBootloader.packetReceiptInterval,
        androidParameters: AndroidParameters(
          packetReceiptNotificationsEnabled: true,
          startAsForegroundService: true,
          disableMtuRequest: androidDisableMtuRequest,
        ),
        darwinParameters: const DarwinParameters(
          packetReceiptNotificationParameter:
              DfuBootloader.packetReceiptInterval,
        ),
        dfuEventHandler: DfuEventHandler(
          onProgressChanged: (_, percent, _, _, _, _) => onProgress(percent),
          onError: (_, code, _, message) => error = '$code: $message',
        ),
      );
    } on Object catch (cause) {
      // A PlatformException from the method channel: the library's own error,
      // an abort, or a file it would not read.
      throw FirmwareInstallException(error ?? 'the transfer failed', cause);
    }
  }

  @override
  Future<void> abort() async {
    try {
      await _dfu.abortDfu();
    } on Object {
      // NO_ACTIVE_DFU: nothing was running, which is the outcome asked for.
    }
  }
}
