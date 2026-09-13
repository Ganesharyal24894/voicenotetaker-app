/// The saved result of one device test, and the vocabulary around it.
///
/// WHY THIS IS A SAVED ARTEFACT AND NOT A LIVE READOUT. The recorder is going
/// into a plastic enclosure with a LiPo cell under the board. Both change how
/// it behaves, and the only way to know whether they made it worse is to have
/// measured it before. A number you can watch but not re-read cannot answer
/// "was it better before?", so every test ends in one of these, it is written
/// to disk, and it goes into the diagnostics export.
///
/// Runs are distinguished by [startedAt] and nothing else. The app has no way
/// to know whether the enclosure is fitted, and a checkbox claiming it does
/// would be a fabricated fact - so the instruction is to run the suite before
/// fitting the case and again after, and to compare by date.
///
/// Pure data, like [BatteryStatus] and [StreamInfo]: no I/O, no formatting.
/// Persistence lives in `services/device_test_store.dart`; the strings a human
/// reads are assembled in `view/`.
library;

/// The five things worth measuring about the enclosure.
enum DeviceTestKind {
  /// How far the link carries before frames start going missing.
  range('range'),

  /// Ten seconds of a quiet room: what the enclosure itself contributes.
  noiseFloor('noise-floor'),

  /// A voice at a marked distance: what the port costs.
  sensitivity('sensitivity'),

  /// Minutes of streaming: intermittent RF problems an instant reading misses.
  linkSoak('link-soak'),

  /// Whether a shake still wakes a device with a case's mass and damping.
  wakeOnMotion('wake-on-motion');

  const DeviceTestKind(this.wireName);

  /// Stable identifier used in the saved file. NEVER the enum index: inserting
  /// a value would silently re-label every result already on disk.
  final String wireName;

  static DeviceTestKind? fromWireName(String name) {
    for (final kind in DeviceTestKind.values) {
      if (kind.wireName == name) return kind;
    }
    return null;
  }
}

/// How a run ended.
///
/// [unavailable] is the honest answer for a test that could not even start -
/// nothing connected, no `fe04` on this firmware, a capture already running.
/// It is a RESULT, recorded and exported like any other, because "we could not
/// measure it" is a fact worth having in a before-and-after comparison. What
/// it must never be is a zero, or a default, or a blank row that looks like a
/// pass.
enum DeviceTestOutcome {
  /// Ran to its end and produced its readings.
  completed('completed'),

  /// The operator stopped it. Whatever partial readings it had are kept, and
  /// labelled as partial.
  cancelled('cancelled'),

  /// It could not run at all. [DeviceTestResult.note] says why.
  unavailable('unavailable'),

  /// It started and then failed - the link went away, the device never stopped
  /// advertising, the shake never woke it. [DeviceTestResult.note] says what.
  failed('failed');

  const DeviceTestOutcome(this.wireName);

  final String wireName;

  static DeviceTestOutcome? fromWireName(String name) {
    for (final outcome in DeviceTestOutcome.values) {
      if (outcome.wireName == name) return outcome;
    }
    return null;
  }
}

/// What a running test is waiting for.
///
/// The operator is half of every one of these tests - they walk away, they
/// speak, they shake the board - so the phase is not decoration: it is the
/// instruction, and the screen cannot be built without it.
///
/// In `model/` rather than beside the service that sets it, because `view/`
/// renders it and `view/` depends on models, not on services.
enum DeviceTestPhase {
  /// Nothing running.
  idle,

  /// Streaming and counting; the operator is walking.
  walking,

  /// Streaming and measuring for a fixed window.
  measuring,

  /// Scanning, waiting for the device to stop advertising (System OFF).
  waitingForSystemOff,

  /// Waiting for the operator to say they have shaken it.
  waitingForShake,

  /// Scanning, waiting for it to advertise again.
  waitingForWake,

  /// Writing the result to disk.
  saving,
}

/// The names of the measurements, and the one parameter that has to be the
/// same every run.
///
/// Named constants rather than string literals so the service that produces a
/// reading, the card that shows it and the test that asserts on it cannot drift
/// apart in what they call the same number.
abstract final class DeviceTestReadings {
  /// The distance the sensitivity test is spoken from, in centimetres.
  ///
  /// A CONSTANT, not a setting. The number itself does not matter; what matters
  /// is that the run before the enclosure and the run after were taken from the
  /// same place, and a free-text field is how that stops being true.
  static const int sensitivityDistanceCm = 30;

  /// The headline of the range walk: the signal at the stop where frames FIRST
  /// went missing. Null on a walk where nothing dropped.
  static const String rssiAtFirstDrop = 'RSSI where drops began';

  static const String noiseFloorRms = 'Noise floor (RMS)';
  static const String peak = 'Peak';
  static const String rms = 'RMS';
  static const String framesReceived = 'Frames received';
  static const String framesLost = 'Frames lost';
  static const String malformedFrames = 'Malformed frames';
  static const String lossPercent = 'Loss';
  static const String disconnections = 'Disconnections';
  static const String wakeDelay = 'Shake to advertising';
  static const String stops = 'Stops';
  static const String strongestRssi = 'Strongest RSSI';
  static const String weakestRssi = 'Weakest RSSI';
  static const String audioMeasured = 'Audio measured';
  static const String soaked = 'Soaked';

  /// The nRF52840's DIE temperature at the moment of the run. Named "die"
  /// HERE, in the label itself, because the label is what a reader of the
  /// saved result sees - and a plastic case with a cell under the board will
  /// move this figure, which is exactly why it is stamped on every run.
  static const String dieTemperature = 'Die temperature';
}

/// Why a test cannot be offered right now.
///
/// The same three-state discipline `AppController` uses for auto-sleep and the
/// battery: a control with nothing truthful behind it is shown as unavailable
/// WITH A REASON, never as a default. The reason is an enum rather than a
/// sentence so the wording stays in `view/`.
enum DeviceTestBlocker {
  /// No link, so there is nothing to measure.
  notConnected,

  /// A capture is running. The frame subscription is exclusive - see
  /// `BleTransport.subscribeFrames` - so a test cannot have one too.
  recording,

  /// Another test is running.
  testRunning,

  /// Firmware with no `fe04`. Nothing can be put to sleep on purpose, so the
  /// wake test has no starting condition.
  noAutoSleep,

  /// The OS refused the permissions a scan needs, and the wake test can only
  /// see the device advertise by scanning.
  scanPermissionDenied,
}

/// One number out of a test, with its unit.
///
/// [value] is nullable because a reading can legitimately be absent from an
/// otherwise good run - "RSSI where drops began" has no value when nothing
/// dropped, which is the best possible outcome and must not render as zero.
class DeviceTestReading {
  const DeviceTestReading({
    required this.label,
    required this.value,
    this.unit = '',
  });

  final String label;

  /// The measurement, or `null` when this run has none.
  final num? value;

  /// `dBFS`, `dBm`, `%`, `s`, or empty for a plain count.
  final String unit;

  Map<String, Object?> toJson() => <String, Object?>{
        'label': label,
        'value': value,
        'unit': unit,
      };

  static DeviceTestReading fromJson(Map<String, Object?> json) {
    final label = json['label'];
    final value = json['value'];
    final unit = json['unit'];
    if (label is! String) {
      throw const FormatException('reading label must be a string');
    }
    if (value != null && value is! num) {
      throw const FormatException('reading value must be a number or null');
    }
    if (unit is! String) {
      throw const FormatException('reading unit must be a string');
    }
    return DeviceTestReading(label: label, value: value as num?, unit: unit);
  }

  @override
  bool operator ==(Object other) =>
      other is DeviceTestReading &&
      other.label == label &&
      other.value == value &&
      other.unit == unit;

  @override
  int get hashCode => Object.hash(label, value, unit);

  @override
  String toString() => 'DeviceTestReading($label: $value $unit)';
}

/// One stop on the range walk.
///
/// RSSI ALONE MISLEADS, which is the whole reason this type has two fields
/// next to each other. A link can sit at a perfectly respectable -75 dBm and
/// still be shedding frames, because what kills a notify stream is retries and
/// a crowded 2.4 GHz band, not raw path loss. So every stop records the signal
/// AND what the link actually delivered between this stop and the last one.
class DeviceTestStep {
  const DeviceTestStep({
    required this.index,
    required this.rssiDbm,
    required this.framesReceived,
    required this.framesLost,
  });

  /// 1-based position in the walk.
  final int index;

  /// Signal strength read from the live link at this stop, or `null` when the
  /// platform would not give one. Null is not zero: 0 dBm is a reading.
  final int? rssiDbm;

  /// Frames that arrived since the previous stop.
  final int framesReceived;

  /// Frames the sequence numbers say went missing since the previous stop.
  final int framesLost;

  int get framesExpected => framesReceived + framesLost;

  /// Fraction of expected frames lost in this leg, `0.0 .. 1.0`.
  double get lossRatio =>
      framesExpected == 0 ? 0.0 : framesLost / framesExpected;

  bool get dropped => framesLost > 0;

  Map<String, Object?> toJson() => <String, Object?>{
        'index': index,
        'rssiDbm': rssiDbm,
        'framesReceived': framesReceived,
        'framesLost': framesLost,
      };

  static DeviceTestStep fromJson(Map<String, Object?> json) {
    final index = json['index'];
    final rssi = json['rssiDbm'];
    final received = json['framesReceived'];
    final lost = json['framesLost'];
    if (index is! int || received is! int || lost is! int) {
      throw const FormatException('step counters must be integers');
    }
    if (rssi != null && rssi is! int) {
      throw const FormatException('step rssiDbm must be an integer or null');
    }
    return DeviceTestStep(
      index: index,
      rssiDbm: rssi as int?,
      framesReceived: received,
      framesLost: lost,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DeviceTestStep &&
      other.index == index &&
      other.rssiDbm == rssiDbm &&
      other.framesReceived == framesReceived &&
      other.framesLost == framesLost;

  @override
  int get hashCode => Object.hash(index, rssiDbm, framesReceived, framesLost);
}

/// A finished run of one test - the thing that is saved, re-read and exported.
class DeviceTestResult {
  const DeviceTestResult({
    required this.kind,
    required this.outcome,
    required this.startedAt,
    required this.duration,
    this.readings = const <DeviceTestReading>[],
    this.steps = const <DeviceTestStep>[],
    this.note,
  });

  /// A run that never started, with the reason recorded.
  ///
  /// Kept and exported like any other result: "this could not be measured on
  /// that date" is part of the before-and-after story.
  factory DeviceTestResult.unavailable({
    required DeviceTestKind kind,
    required DateTime at,
    required String because,
  }) =>
      DeviceTestResult(
        kind: kind,
        outcome: DeviceTestOutcome.unavailable,
        startedAt: at,
        duration: Duration.zero,
        note: because,
      );

  final DeviceTestKind kind;
  final DeviceTestOutcome outcome;

  /// When the run began. The ONLY thing that distinguishes one run from
  /// another - see the library comment.
  final DateTime startedAt;

  /// How long it took, which for the wake test is itself the measurement.
  final Duration duration;

  /// The numbers, in the order they should be read.
  final List<DeviceTestReading> readings;

  /// The range walk, empty for every other test.
  final List<DeviceTestStep> steps;

  /// Free text: why it was unavailable, what failed, the marked distance, the
  /// caveat that belongs with the figure.
  final String? note;

  /// Whether this run produced numbers worth comparing.
  bool get hasReadings =>
      readings.any((reading) => reading.value != null) || steps.isNotEmpty;

  /// The reading called [label], or `null` when this run has none.
  DeviceTestReading? reading(String label) {
    for (final reading in readings) {
      if (reading.label == label) return reading;
    }
    return null;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'kind': kind.wireName,
        'outcome': outcome.wireName,
        'startedAt': startedAt.toIso8601String(),
        'durationMs': duration.inMilliseconds,
        'readings': readings.map((r) => r.toJson()).toList(),
        'steps': steps.map((s) => s.toJson()).toList(),
        'note': note,
      };

  /// Reads one saved result.
  ///
  /// Throws [FormatException] on anything it does not recognise, INCLUDING an
  /// unknown [kind] or [outcome] - a file written by a newer build is not this
  /// build's to reinterpret. The store drops such entries and keeps the rest,
  /// rather than refusing to show any history at all.
  static DeviceTestResult fromJson(Map<String, Object?> json) {
    final kindName = json['kind'];
    final outcomeName = json['outcome'];
    final startedAt = json['startedAt'];
    final durationMs = json['durationMs'];
    if (kindName is! String) {
      throw const FormatException('result kind must be a string');
    }
    if (outcomeName is! String) {
      throw const FormatException('result outcome must be a string');
    }
    final kind = DeviceTestKind.fromWireName(kindName);
    if (kind == null) {
      throw FormatException('unknown test kind: $kindName');
    }
    final outcome = DeviceTestOutcome.fromWireName(outcomeName);
    if (outcome == null) {
      throw FormatException('unknown test outcome: $outcomeName');
    }
    if (startedAt is! String) {
      throw const FormatException('result startedAt must be a string');
    }
    if (durationMs is! int) {
      throw const FormatException('result durationMs must be an integer');
    }
    final note = json['note'];
    if (note != null && note is! String) {
      throw const FormatException('result note must be a string or null');
    }
    return DeviceTestResult(
      kind: kind,
      outcome: outcome,
      startedAt: DateTime.parse(startedAt),
      duration: Duration(milliseconds: durationMs),
      readings: _listOf(json['readings'], DeviceTestReading.fromJson),
      steps: _listOf(json['steps'], DeviceTestStep.fromJson),
      note: note as String?,
    );
  }

  static List<T> _listOf<T>(
    Object? raw,
    T Function(Map<String, Object?>) read,
  ) {
    if (raw == null) return <T>[];
    if (raw is! List) {
      throw const FormatException('expected a list');
    }
    return raw.map((entry) {
      if (entry is! Map) {
        throw const FormatException('expected an object in the list');
      }
      return read(entry.cast<String, Object?>());
    }).toList(growable: false);
  }

  @override
  String toString() => 'DeviceTestResult(${kind.wireName}, '
      '${outcome.wireName}, $startedAt, ${readings.length} readings)';
}
