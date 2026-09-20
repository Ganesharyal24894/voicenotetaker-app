/// Wire format of the `fe09` battery-life history characteristic.
///
/// Pure data, like `AutoSleep` and `CaptureFlags`: this is the device protocol,
/// not the BLE stack, so it lives in `model/` and survives a package swap.
///
/// THE DEVICE HAS NO CLOCK. It records awake seconds since the last plug edge
/// and counts what it cannot time (sleeps, boots, resets). Wall time comes from
/// the phone: every read is an anchor - see `battery_anchor.dart` and
/// `battery_report.dart`. The byte layout is the firmware's
/// `doc/battery-history.md`; every offset below is from there.
///
/// SECTIONS ARE READ BY THE LENGTHS IN THE HEADER, never by these constants.
/// That is the protocol, not a concession: the firmware publishes the lengths
/// precisely so a section can grow without every offset after it moving. A
/// value whose version is not [layoutVersion], whose sections are shorter than
/// this layout, or that does not hold what its header promises, is refused
/// rather than half-read.
library;

abstract final class BatteryHistoryFlags {
  /// Start mV / % are valid.
  static const int startSettled = 0x0001;

  /// The edge that began this happened while off or asleep: its time is
  /// unknown.
  static const int startUnseen = 0x0002;

  /// The same, for the edge that ended it.
  static const int endUnseen = 0x0004;

  /// An unexpected reset lost up to 15 min of counters.
  static const int resetSeen = 0x0008;

  /// A save was skipped or failed: counters under-report.
  static const int gap = 0x0010;

  /// A 16-bit counter reached 0xFFFF.
  static const int saturated = 0x0020;

  /// Stored history was missing, corrupt or an older layout when this began.
  static const int historyReset = 0x0040;

  /// The charger reported the charge complete.
  static const int terminated = 0x0080;

  /// Internal to the firmware: the last save was made entering System OFF.
  static const int atSleep = 0x0100;

  /// Began at the boot after a power loss.
  static const int afterPowerLoss = 0x0200;

  /// Flags that mean the counters (not the wall time) cannot be fully trusted,
  /// or that the history is discontinuous.
  static const int lowTrustMask =
      gap | resetSeen | historyReset | afterPowerLoss | saturated;
}

/// What the open record describes.
enum BatteryHistoryState {
  /// Nothing known yet.
  none,

  /// Unplugged: a discharge session is open.
  onBattery,

  /// External power present.
  external;

  static BatteryHistoryState fromWire(int value) => switch (value) {
        0 => none,
        1 => onBattery,
        2 => external,
        _ => throw FormatException('unknown battery history state $value'),
      };
}

/// Why a discharge session ended.
enum SessionEndReason {
  open,

  /// External power arrived.
  plugged,

  /// Lost power at a low voltage: ran flat.
  empty,

  /// Lost power at a healthy voltage: battery pulled or a fault. Not a runtime
  /// measurement.
  powerLost,

  /// A value this build does not know.
  unknown;

  static SessionEndReason fromWire(int value) => switch (value) {
        0 => open,
        1 => plugged,
        2 => empty,
        3 => powerLost,
        _ => unknown,
      };
}

int? _pct(int value) => value == 0xFF ? null : value;
int? _mv(int value) => value == 0 ? null : value;
int? _stamp(int value) => value == 0xFFFFFFFF ? null : value;

/// A little-endian cursor over one section.
class _Reader {
  _Reader(this._bytes, this._base);

  final List<int> _bytes;
  final int _base;

  int u8(int offset) => _bytes[_base + offset] & 0xFF;
  int u16(int offset) => u8(offset) | (u8(offset + 1) << 8);
  int u32(int offset) => u16(offset) | (u16(offset + 2) << 16);
}

/// The open record: counters since the last plug/unplug edge.
class BatteryHistoryCurrent {
  const BatteryHistoryCurrent({
    required this.state,
    required this.lastResetKind,
    required this.flags,
    required this.sessionId,
    required this.awakeSeconds,
    required this.micSeconds,
    required this.bleSeconds,
    required this.streamSeconds,
    required this.chargingSeconds,
    required this.sleeps,
    required this.boots,
    required this.resets,
    required this.sleepSaves,
    required this.edgeMv,
    required this.edgePercent,
    required this.lastPercent,
    required this.startMv,
    required this.startPercent,
    required this.startStampSeconds,
    required this.lastMv,
    required this.minMv,
    required this.lastStampSeconds,
    required this.saves,
    required this.fullStampSeconds,
  });

  static const int wireLength = 64;

  final BatteryHistoryState state;
  final int lastResetKind;
  final int flags;

  /// On battery, the open session; otherwise the last one (0 = none yet).
  final int sessionId;

  /// Awake seconds since the edge: the anchor counter.
  final int awakeSeconds;
  final int micSeconds;
  final int bleSeconds;
  final int streamSeconds;
  final int chargingSeconds;
  final int sleeps;
  final int boots;
  final int resets;
  final int sleepSaves;
  final int? edgeMv;

  /// On external power this is % at plug-in; on battery it is charger-held.
  final int? edgePercent;
  final int? lastPercent;
  final int? startMv;

  /// On battery, the settled % at unplug.
  final int? startPercent;
  final int? startStampSeconds;
  final int? lastMv;
  final int? minMv;
  final int? lastStampSeconds;
  final int saves;
  final int? fullStampSeconds;

  bool has(int flag) => flags & flag != 0;

  static BatteryHistoryCurrent _read(_Reader r) => BatteryHistoryCurrent(
        state: BatteryHistoryState.fromWire(r.u8(0)),
        lastResetKind: r.u8(1),
        flags: r.u16(2),
        sessionId: r.u32(4),
        awakeSeconds: r.u32(8),
        micSeconds: r.u32(12),
        bleSeconds: r.u32(16),
        streamSeconds: r.u32(20),
        chargingSeconds: r.u32(24),
        sleeps: r.u16(28),
        boots: r.u16(30),
        resets: r.u16(32),
        sleepSaves: r.u16(34),
        edgeMv: _mv(r.u16(36)),
        edgePercent: _pct(r.u8(38)),
        lastPercent: _pct(r.u8(39)),
        startMv: _mv(r.u16(40)),
        startPercent: _pct(r.u8(42)),
        startStampSeconds: _stamp(r.u32(44)),
        lastMv: _mv(r.u16(48)),
        minMv: _mv(r.u16(50)),
        lastStampSeconds: _stamp(r.u32(52)),
        saves: r.u32(56),
        fullStampSeconds: _stamp(r.u32(60)),
      );
}

/// The last completed charge (external-power period).
class BatteryHistoryCharge {
  const BatteryHistoryCharge({
    required this.flags,
    required this.nextSessionId,
    required this.awakeSeconds,
    required this.chargingSeconds,
    required this.fullStampSeconds,
    required this.sleeps,
    required this.boots,
    required this.inMv,
    required this.inPercent,
    required this.outPercent,
    required this.outMv,
    required this.resets,
  });

  static const int wireLength = 32;

  final int flags;

  /// The discharge session the unplug opened.
  final int nextSessionId;
  final int awakeSeconds;
  final int chargingSeconds;
  final int? fullStampSeconds;
  final int sleeps;
  final int boots;
  final int? inMv;
  final int? inPercent;

  /// Held up by the charger; 100 if it had terminated.
  final int? outPercent;
  final int? outMv;
  final int resets;

  bool has(int flag) => flags & flag != 0;

  /// Null when the record says no charge has completed yet.
  static BatteryHistoryCharge? _read(_Reader r) {
    if (r.u8(0) == 0) return null;
    return BatteryHistoryCharge(
      flags: r.u16(2),
      nextSessionId: r.u32(4),
      awakeSeconds: r.u32(8),
      chargingSeconds: r.u32(12),
      fullStampSeconds: _stamp(r.u32(16)),
      sleeps: r.u16(20),
      boots: r.u16(22),
      inMv: _mv(r.u16(24)),
      inPercent: _pct(r.u8(26)),
      outPercent: _pct(r.u8(27)),
      outMv: _mv(r.u16(28)),
      resets: r.u16(30),
    );
  }
}

/// One completed discharge session from the ring.
class BatteryHistorySession {
  const BatteryHistorySession({
    required this.sessionId,
    required this.endReason,
    required this.edgePercent,
    required this.flags,
    required this.awakeSeconds,
    required this.micSeconds,
    required this.bleSeconds,
    required this.streamSeconds,
    required this.sleeps,
    required this.boots,
    required this.resets,
    required this.startMv,
    required this.startPercent,
    required this.endPercent,
    required this.endMv,
    required this.minMv,
  });

  static const int wireLength = 40;

  final int sessionId;
  final SessionEndReason endReason;

  /// % just before the unplug, held up by the charger.
  final int? edgePercent;
  final int flags;
  final int awakeSeconds;
  final int micSeconds;
  final int bleSeconds;
  final int streamSeconds;
  final int sleeps;
  final int boots;
  final int resets;
  final int? startMv;

  /// Settled start %.
  final int? startPercent;
  final int? endPercent;
  final int? endMv;
  final int? minMv;

  bool has(int flag) => flags & flag != 0;

  /// Counters under-report or the history is discontinuous. Shown gently,
  /// never hidden.
  bool get lowTrust => flags & BatteryHistoryFlags.lowTrustMask != 0;

  static BatteryHistorySession _read(_Reader r) => BatteryHistorySession(
        sessionId: r.u32(0),
        endReason: SessionEndReason.fromWire(r.u8(4)),
        edgePercent: _pct(r.u8(5)),
        flags: r.u16(6),
        awakeSeconds: r.u32(8),
        micSeconds: r.u32(12),
        bleSeconds: r.u32(16),
        streamSeconds: r.u32(20),
        sleeps: r.u16(24),
        boots: r.u16(26),
        resets: r.u16(28),
        startMv: _mv(r.u16(30)),
        startPercent: _pct(r.u8(32)),
        endPercent: _pct(r.u8(33)),
        endMv: _mv(r.u16(34)),
        minMv: _mv(r.u16(36)),
      );
}

/// One decoded `fe09` value.
class BatteryHistory {
  const BatteryHistory({
    required this.version,
    required this.storeUsable,
    required this.externalPower,
    required this.charging,
    required this.plugFromChargeLine,
    required this.bootResetKind,
    required this.uptimeSeconds,
    required this.current,
    required this.lastCharge,
    required this.sessions,
  });

  /// The one layout there is. A value announcing any other is refused: the
  /// field stays because a format that will grow is worth a version byte, but
  /// nothing here branches on it.
  static const int layoutVersion = 1;

  /// The value is at most this long.
  static const int maxBytes = 428;

  static const int headerLength = 12;
  static const int maxRingEntries = 8;

  /// Always [layoutVersion]; anything else was refused at the door.
  final int version;

  final bool storeUsable;
  final bool externalPower;
  final bool charging;
  final bool plugFromChargeLine;
  final int bootResetKind;
  final int uptimeSeconds;
  final BatteryHistoryCurrent current;
  final BatteryHistoryCharge? lastCharge;

  /// Completed sessions, newest first.
  final List<BatteryHistorySession> sessions;

  /// Decodes a value. Throws [FormatException] on anything this build cannot
  /// read honestly.
  static BatteryHistory fromBytes(List<int> bytes) {
    if (bytes.length < headerLength) {
      throw FormatException(
        'battery history needs a $headerLength-byte header, got ${bytes.length}',
      );
    }
    final header = _Reader(bytes, 0);
    final version = header.u8(0);
    if (version != layoutVersion) {
      throw FormatException('battery history layout version $version');
    }
    final hdrLen = header.u8(1);
    final curLen = header.u8(2);
    final chgLen = header.u8(3);
    final ringLen = header.u8(4);
    final count = header.u8(5);
    if (hdrLen < headerLength ||
        curLen < BatteryHistoryCurrent.wireLength ||
        chgLen < BatteryHistoryCharge.wireLength ||
        ringLen < BatteryHistorySession.wireLength) {
      throw FormatException(
        'battery history sections shorter than layout $layoutVersion: '
        '$hdrLen/$curLen/$chgLen/$ringLen',
      );
    }
    if (count > maxRingEntries) {
      throw FormatException('battery history ring of $count entries');
    }
    final needed = hdrLen + curLen + chgLen + count * ringLen;
    if (bytes.length < needed) {
      throw FormatException(
        'battery history needs $needed bytes, got ${bytes.length}',
      );
    }
    final now = header.u8(6);
    final ringStart = hdrLen + curLen + chgLen;
    return BatteryHistory(
      version: version,
      storeUsable: now & 0x01 != 0,
      externalPower: now & 0x02 != 0,
      charging: now & 0x04 != 0,
      plugFromChargeLine: now & 0x08 != 0,
      bootResetKind: header.u8(7),
      uptimeSeconds: header.u32(8),
      current: BatteryHistoryCurrent._read(_Reader(bytes, hdrLen)),
      lastCharge: BatteryHistoryCharge._read(_Reader(bytes, hdrLen + curLen)),
      sessions: List<BatteryHistorySession>.unmodifiable(<BatteryHistorySession>[
        for (var i = 0; i < count; i++)
          BatteryHistorySession._read(_Reader(bytes, ringStart + i * ringLen)),
      ]),
    );
  }
}
