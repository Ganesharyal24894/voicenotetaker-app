import 'dart:typed_data';

/// Builds `fe09` values byte by byte from the documented offsets, so the tests
/// check the decoder against the contract rather than against itself.
class HistoryBytes {
  HistoryBytes({
    this.version = 1,
    this.headerLength = 12,
    this.currentLength = 64,
    this.chargeLength = 32,
    this.ringLength = 40,
  });

  final int version;
  final int headerLength;
  final int currentLength;
  final int chargeLength;
  final int ringLength;

  int nowFlags = 0x01;
  int bootResetKind = 5;
  int uptime = 120;

  /// Offset -> (width, value) writes into each section.
  final Map<int, (int, int)> current = <int, (int, int)>{};
  final Map<int, (int, int)> charge = <int, (int, int)>{};
  final List<Map<int, (int, int)>> ring = <Map<int, (int, int)>>[];

  /// Overrides the ring count byte.
  int? countOverride;

  Uint8List build({int? truncateTo}) {
    final count = ring.length;
    final total = headerLength + currentLength + chargeLength + count * ringLength;
    final bytes = Uint8List(total);
    final data = ByteData.sublistView(bytes);
    bytes[0] = version;
    bytes[1] = headerLength;
    bytes[2] = currentLength;
    bytes[3] = chargeLength;
    bytes[4] = ringLength;
    bytes[5] = countOverride ?? count;
    bytes[6] = nowFlags;
    bytes[7] = bootResetKind;
    data.setUint32(8, uptime, Endian.little);
    void put(int base, Map<int, (int, int)> fields) {
      for (final entry in fields.entries) {
        final (width, value) = entry.value;
        final at = base + entry.key;
        switch (width) {
          case 1:
            data.setUint8(at, value);
          case 2:
            data.setUint16(at, value, Endian.little);
          case 4:
            data.setUint32(at, value, Endian.little);
        }
      }
    }

    put(headerLength, current);
    put(headerLength + currentLength, charge);
    for (var i = 0; i < count; i++) {
      put(headerLength + currentLength + chargeLength + i * ringLength, ring[i]);
    }
    return truncateTo == null ? bytes : Uint8List.sublistView(bytes, 0, truncateTo);
  }

  /// A plausible on-battery open record with every "unknown" sentinel set
  /// where nothing was given.
  static Map<int, (int, int)> onBattery({
    int sessionId = 7,
    int awake = 3600,
    int sleeps = 0,
    int boots = 0,
    int flags = 0x0001,
    int startPercent = 96,
    int lastPercent = 62,
    int state = 1,
  }) =>
      <int, (int, int)>{
        0: (1, state),
        1: (1, 5),
        2: (2, flags),
        4: (4, sessionId),
        8: (4, awake),
        12: (4, 1800),
        16: (4, 3000),
        20: (4, 900),
        24: (4, 0),
        28: (2, sleeps),
        30: (2, boots),
        32: (2, 0),
        34: (2, 3),
        36: (2, 4180),
        38: (1, 100),
        39: (1, lastPercent),
        40: (2, 4120),
        42: (1, startPercent),
        44: (4, 61),
        48: (2, 3800),
        50: (2, 3790),
        52: (4, awake),
        56: (4, 4),
        60: (4, 0xFFFFFFFF),
      };
}
