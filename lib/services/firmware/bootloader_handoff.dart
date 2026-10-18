import 'dart:async';

import '../../drivers/ble_transport.dart';
import '../../model/device_state.dart';
import '../../model/dfu_bootloader.dart';

/// How a request for the OTA bootloader ended.
enum OtaRequestOutcome {
  /// The link dropped: the recorder is rebooting into its bootloader.
  rebooted,

  /// The write was refused and the link stayed up - most likely no USB
  /// power, which the firmware answers like a wrong value.
  refused,

  /// The write was accepted but no drop was seen in time.
  didNotRestart,
}

/// The two steps between "the package is ready" and "the DFU library can
/// have it": `OTA!` until the link drops, then a scan for the bootloader.
///
/// Apart from the update service so its timing rules sit in one place, and
/// so the service stays a readable state machine.
class BootloaderHandoff {
  BootloaderHandoff({
    required this._transport,
    required this.refusalGrace,
    required this.restartTimeout,
    required this.bootloaderTimeout,
    required this.bootloaderSettle,
  });

  final BleTransport _transport;

  /// How long a refused write is given to turn out to be a link that dropped
  /// first - the recorder rebooting before its write response went out.
  final Duration refusalGrace;

  /// How long an accepted write is given to drop the link.
  final Duration restartTimeout;
  final Duration bootloaderTimeout;

  /// How long to keep looking for the recorder's own address once some other
  /// `AdaDFU` has been seen.
  final Duration bootloaderSettle;

  /// Writes `OTA!` to [deviceId] and waits for the link to go.
  ///
  /// [ownerSawDrop] is the connection's owner reporting the same drop, which
  /// may arrive before or instead of this transport's own event.
  Future<(OtaRequestOutcome, Object?)> requestOta(
    String deviceId, {
    required Future<void> ownerSawDrop,
  }) async {
    final dropped = Completer<void>();
    void drop() {
      if (!dropped.isCompleted) dropped.complete();
    }

    unawaited(ownerSawDrop.then((_) => drop()));
    final link = _transport.connectionState(deviceId).listen(
      (status) {
        if (status == BleConnectionStatus.disconnected) drop();
      },
      onError: (Object _) {},
    );
    Object? refusal;
    try {
      await _transport.requestOtaBootloader(deviceId);
    } on BleTransportException catch (error) {
      refusal = error;
    }
    final didDrop = await dropped.future.then((_) => true).timeout(
          refusal == null ? restartTimeout : refusalGrace,
          onTimeout: () => false,
        );
    await link.cancel();
    if (didDrop) return (OtaRequestOutcome.rebooted, null);
    return refusal == null
        ? (OtaRequestOutcome.didNotRestart, null)
        : (OtaRequestOutcome.refused, refusal);
  }

  /// Scans until the bootloader at [recorderAddress] + 1 is seen, or
  /// [bootloaderSettle] after any other `AdaDFU`, or [bootloaderTimeout];
  /// then picks one - see [DfuBootloader.pick]. Null when none was seen.
  Future<DiscoveredDevice?> findBootloader(String? recorderAddress) async {
    final expected = recorderAddress == null
        ? null
        : DfuBootloader.incrementedAddress(recorderAddress);
    final seen = <String, DiscoveredDevice>{};
    final done = Completer<void>();
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    Timer? settle;
    // The transport closes the scan at its window; the same deadline is kept
    // here too, so a stream that never closes cannot hang the run.
    final deadline = Timer(bootloaderTimeout, finish);
    final scan = _transport
        .scanForDfuBootloader(window: bootloaderTimeout)
        .listen(
      (device) {
        seen[device.id] = device;
        if (DfuBootloader.isExpected(device, expected)) return finish();
        settle ??= Timer(bootloaderSettle, finish);
      },
      onError: (Object _) {},
      onDone: finish,
    );
    await done.future;
    settle?.cancel();
    deadline.cancel();
    await scan.cancel();
    return DfuBootloader.pick(seen.values.toList(), expectedAddress: expected);
  }
}
