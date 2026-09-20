import 'pairing_advert.dart';

/// Bluetooth adapter availability, expressed without reference to any BLE
/// package's enum.
enum BleAvailability {
  unknown,
  unsupported,
  unauthorized,
  poweredOff,
  poweredOn,
}

/// Link state of a single peripheral.
enum BleConnectionStatus { disconnected, connecting, connected, disconnecting }

/// A peripheral seen while scanning.
class DiscoveredDevice {
  const DiscoveredDevice({
    required this.id,
    this.name,
    this.rssi,
    this.pairing,
    this.bonded,
  });

  /// Platform-scoped identifier (MAC on Android/Linux, UUID on Apple).
  final String id;
  final String? name;
  final int? rssi;

  /// The pairing status from the scan response; null when the scan result
  /// carried none - a result seen without its scan response, or a recorder
  /// yet, or a device made up from a remembered id.
  final PairingAdvert? pairing;

  /// Whether the OS holds a bond with this device. Android reports it with
  /// every scan result; null where the platform cannot say (iOS).
  final bool? bonded;

  /// This device with what a later scan result added. A result without a scan
  /// response does not erase a status already seen.
  DiscoveredDevice mergedWith(DiscoveredDevice later) => DiscoveredDevice(
        id: id,
        name: later.name ?? name,
        rssi: later.rssi ?? rssi,
        pairing: later.pairing ?? pairing,
        bonded: later.bonded ?? bonded,
      );

  /// Whether [other] would show differently - same id, new facts.
  bool differsFrom(DiscoveredDevice other) =>
      other.name != name ||
      other.pairing != pairing ||
      other.bonded != bonded;

  @override
  bool operator ==(Object other) => other is DiscoveredDevice && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'DiscoveredDevice($id, name: $name, rssi: $rssi, pairing: $pairing, bonded: $bonded)';
}

/// What became of the most recent scan WINDOW.
///
/// A scan is bounded (see `AppController.scanWindow`), so "finished having
/// seen nothing" is a fact the app can state - and it is a different fact from
/// "a scan is running and has not seen anything yet". Collapsing the two would
/// mean showing "no recorder nearby" one millisecond after the user taps scan.
enum ScanOutcome {
  /// No scan has run its full window since the app started, one is running
  /// now, or the user stopped one early. Nothing can honestly be concluded.
  pending,

  /// A window ended having seen at least one peripheral.
  devicesFound,

  /// A window ran to its end and nothing answered. A RESULT, not an error.
  nothingFound,
}

/// Why there is no link to the recorder, when the reason is worth telling the
/// user about.
///
/// [connectFailed] and [connectionLost] are deliberately separate. One means
/// the recorder was found and the handshake did not complete; the other means
/// a working link went away on its own, most likely out of range - and the
/// recorder keeps capturing through it. They have different causes, different
/// reassurances and different screens, so they are different values here.
enum LinkOutcome {
  /// Nothing to report: never connected, or the user ended the link on
  /// purpose.
  none,

  /// A connect attempt on a device that had already been discovered did not
  /// complete.
  connectFailed,

  /// A link that was up dropped without the user asking for it.
  connectionLost,
}
