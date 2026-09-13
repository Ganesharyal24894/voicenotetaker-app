import 'recording_metadata.dart';

/// What the link is doing RIGHT NOW: the signal, and what the stream delivered.
///
/// WHY THIS REPLACED TWO SAVED TESTS. There used to be a stepped range walk and
/// a three-minute link soak, both of which ended in a row in a file. Between
/// them they measured two things - the signal strength, and the frames that went
/// missing - and the device is doing both continuously the whole time it is
/// connected. A live readout measures the same two quantities without anybody
/// walking anywhere and without a number being frozen at the moment somebody
/// happened to press stop: a soak is this view left open, and a range walk is
/// this view carried across a room.
///
/// RSSI ALONE MISLEADS, which is the whole reason this type carries the signal
/// and the loss side by side. A link can sit at a perfectly respectable -75 dBm
/// and still be shedding frames, because what kills a notify stream is retries
/// in a crowded 2.4 GHz band rather than raw path loss. Either figure on its own
/// invites the wrong conclusion.
///
/// NULL IS NOT ZERO, twice over. A [rssiDbm] of null is a platform that would
/// not report the signal - 0 dBm is a real reading and an absurd one. A
/// [lossPercent] of null is a stream that has not delivered anything yet, which
/// is not the same fact as a stream that has delivered everything.
///
/// Pure data, like [BatteryStatus] and [DieTemperature]: no I/O, no formatting.
/// The polling and the counting live in `services/link_monitor.dart`; the
/// strings a human reads are assembled in `view/`.
class LinkHealth {
  const LinkHealth({
    this.rssiDbm,
    this.stats = const CaptureStats(),
    this.watching = false,
  });

  /// Nothing is being watched - the state before the diagnostics screen opens,
  /// and the state the moment it closes.
  static const LinkHealth idle = LinkHealth();

  /// Weakest signal the meter draws, in dBm.
  ///
  /// -95 dBm is about where a 1 Mbit BLE link stops working at all, so it is the
  /// bottom of the scale rather than a threshold anybody chose for looks.
  static const int rssiFloorDbm = -95;

  /// Strongest signal the meter draws, in dBm.
  ///
  /// -45 dBm is a phone lying next to the device. Anything stronger pins the
  /// meter, which is correct: the difference between -45 and -35 is not a
  /// difference anybody needs to see.
  static const int rssiCeilingDbm = -45;

  /// Signal strength of the LIVE link in dBm, or null when the platform would
  /// not report it.
  ///
  /// NOT [DiscoveredDevice.rssi], which is one sample taken off an advertising
  /// packet at scan time and never updated again.
  final int? rssiDbm;

  /// Frames the phone received, the frames it did not, and the malformed ones.
  ///
  /// Lost frames are counted from GAPS IN THE `fe01` SEQUENCE NUMBER, which is
  /// the number worth having: it counts what the phone failed to receive, air
  /// losses included. A byte counter kept by the firmware could only report what
  /// the firmware believed it had sent.
  final CaptureStats stats;

  /// True while something is actually subscribed and counting.
  ///
  /// The difference between "no frames lost" and "nothing is listening" is the
  /// whole distinction this flag exists to keep, and it is why the counters are
  /// not simply rendered whenever they are zero.
  final bool watching;

  /// Frames the device is believed to have sent - received plus lost.
  int get framesExpected => stats.framesExpected;

  int get framesReceived => stats.framesReceived;

  int get framesLost => stats.framesLost;

  /// Loss as a percentage, or null when nothing has arrived yet.
  ///
  /// Null rather than 0.00%: a stream that has not started is not a clean
  /// stream, and this is the last place the two could be collapsed.
  double? get lossPercent =>
      framesExpected == 0 ? null : stats.lossRatio * 100;

  /// Where the signal sits on the meter, `0.0 .. 1.0`, or null when there is no
  /// reading to place.
  double? get rssiFraction {
    final dbm = rssiDbm;
    if (dbm == null) return null;
    if (dbm <= rssiFloorDbm) return 0.0;
    if (dbm >= rssiCeilingDbm) return 1.0;
    return (dbm - rssiFloorDbm) / (rssiCeilingDbm - rssiFloorDbm);
  }

  LinkHealth copyWith({
    int? rssiDbm,
    bool clearRssi = false,
    CaptureStats? stats,
    bool? watching,
  }) =>
      LinkHealth(
        rssiDbm: clearRssi ? null : (rssiDbm ?? this.rssiDbm),
        stats: stats ?? this.stats,
        watching: watching ?? this.watching,
      );

  @override
  bool operator ==(Object other) =>
      other is LinkHealth &&
      other.rssiDbm == rssiDbm &&
      other.watching == watching &&
      other.stats.framesReceived == stats.framesReceived &&
      other.stats.framesLost == stats.framesLost &&
      other.stats.malformedFrames == stats.malformedFrames;

  @override
  int get hashCode => Object.hash(
        rssiDbm,
        watching,
        stats.framesReceived,
        stats.framesLost,
        stats.malformedFrames,
      );

  @override
  String toString() => 'LinkHealth('
      '${rssiDbm == null ? 'no rssi' : '$rssiDbm dBm'}, '
      '${stats.framesReceived} received, ${stats.framesLost} lost, '
      '${watching ? 'watching' : 'idle'})';
}
