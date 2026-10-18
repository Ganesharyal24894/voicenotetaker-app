import 'device_state.dart';

/// What the recorder looks like once `OTA!` has rebooted it into the
/// Adafruit nRF52 bootloader's BLE OTA mode, and how to tell it from any other
/// bootloader in range.
///
/// Read from the bootloader source (0.9.2,
/// `lib/sdk11/components/libraries/bootloader_dfu/dfu_transport_ble.c`): it
/// advertises the complete local name `AdaDFU` and the 128-bit Nordic legacy
/// DFU service, on the SoftDevice's address with `addr[0] += 1`.
abstract final class DfuBootloader {
  /// `DEVICE_NAME` in the bootloader. Every Adafruit-bootloader board in OTA
  /// mode uses it, which is why the address is preferred when there is one.
  static const String advertisedName = 'AdaDFU';

  /// The Nordic legacy DFU service, `0x1530` on the DFU base UUID.
  static const String serviceUuid = '00001530-1212-efde-1523-785feabcd123';

  /// Packet receipt notifications every this many packets. The bootloader
  /// README requires 8 or less on 0.6.x - 0.9.x; the iOS library defaults to
  /// 12 and Android's turns PRNs off altogether, so it is always set.
  static const int packetReceiptInterval = 8;

  /// The bootloader's address from the application's, or null when [address]
  /// is not a MAC - which on iOS it never is (a CoreBluetooth UUID).
  ///
  /// `addr[0]` is the LEAST significant byte, which Android writes LAST in
  /// `AA:BB:CC:DD:EE:FF`. It is a `uint8_t += 1`, so it wraps without a carry.
  ///
  /// UNVERIFIED ON A BOARD: the bootloader increments the SoftDevice's
  /// address, and whether Zephyr's identity address on this recorder is that
  /// same address has not been checked. That is why a match here is only a
  /// preference - see [pick].
  static String? incrementedAddress(String address) {
    final parts = address.split(':');
    if (parts.length != 6) return null;
    final bytes = <int>[];
    for (final part in parts) {
      if (part.length != 2) return null;
      final value = int.tryParse(part, radix: 16);
      if (value == null) return null;
      bytes.add(value);
    }
    bytes[5] = (bytes[5] + 1) & 0xFF;
    return bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(':');
  }

  /// The bootloader to send the update to, from what one scan saw.
  ///
  /// The recorder's own incremented address wins outright. Without one (iOS,
  /// or an address that did not match) the strongest `AdaDFU` is taken: the
  /// recorder was next to the phone a few seconds ago, and the bootloader
  /// accepts any client, so this is the best evidence there is. Null when
  /// nothing was seen.
  static DiscoveredDevice? pick(
    List<DiscoveredDevice> seen, {
    required String? expectedAddress,
  }) {
    if (seen.isEmpty) return null;
    if (expectedAddress != null) {
      for (final device in seen) {
        if (isExpected(device, expectedAddress)) return device;
      }
    }
    final sorted = [...seen]
      ..sort((a, b) => (b.rssi ?? -999).compareTo(a.rssi ?? -999));
    return sorted.first;
  }

  /// Whether [device] is at [expectedAddress], ignoring case.
  static bool isExpected(DiscoveredDevice device, String? expectedAddress) =>
      expectedAddress != null &&
      device.id.toUpperCase() == expectedAddress.toUpperCase();
}
