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
  });

  /// Platform-scoped identifier (MAC on Android/Linux, UUID on Apple).
  final String id;
  final String? name;
  final int? rssi;

  @override
  bool operator ==(Object other) => other is DiscoveredDevice && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'DiscoveredDevice($id, name: $name, rssi: $rssi)';
}
