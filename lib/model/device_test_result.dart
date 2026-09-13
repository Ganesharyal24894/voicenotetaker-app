/// The saved result of one device measurement, and the vocabulary around it.
///
/// WHY THIS IS A SAVED ARTEFACT AND NOT A LIVE READOUT. The recorder is going
/// into a plastic enclosure with a LiPo cell under the board. Both change how
/// it behaves, and the only way to know whether they made it worse is to have
/// measured it before. A number you can watch but not re-read cannot answer
/// "was it better before?", so every mic check ends in one of these, it is
/// written to disk, and it goes into the diagnostics export.
///
/// Runs are distinguished by [startedAt] and nothing else. The app has no way
/// to know whether the enclosure is fitted, and a checkbox claiming it does
/// would be a fabricated fact - so the instruction is to run the check before
/// fitting the case and again after, and to compare by date.
///
/// WHAT IS NOT HERE ANY MORE. Three measurements were removed rather than kept
/// for completeness:
///
///   * the stepped range walk and the minutes-long link soak, because the live
///     Link view on the diagnostics screen measures the same two things - the
///     signal, and the frames that went missing - continuously and without
///     anybody having to walk anywhere. A soak is that view left open.
///   * wake-on-motion, because the figure it reported was dominated by the
///     phone's own scan-discovery latency rather than by the IMU, absence of an
///     advertising packet is evidence of System OFF rather than proof of it,
///     and there is no mechanism by which a plastic shell changes the
///     sensitivity of an IMU that is soldered to the board. It also wrote
///     auto-sleep into the device's flash and dropped the link, which is a
///     mutation with nothing trustworthy to show for it.
///
/// Their wire names are listed in `DeviceTestStore.retiredKinds` and runs saved
/// under them are KEPT IN THE FILE, untouched - see that class. This build just
/// does not read them.
///
/// Pure data, like [BatteryStatus] and [StreamInfo]: no I/O, no formatting.
/// Persistence lives in `services/device_test_store.dart`; the strings a human
/// reads are assembled in `view/`.
library;

/// The two things worth measuring, and the reason there are only two.
///
/// Both are acoustic, and acoustics is where the enclosure can hurt a recording
/// silently: nothing fails, the words just get harder to make out. Everything
/// the LINK does is observable live, so it needs no saved run at all.
enum DeviceTestKind {
  /// Ten seconds of a quiet room: what the enclosure itself contributes.
  noiseFloor('noise-floor'),

  /// A voice at a marked distance: what the port costs.
  sensitivity('sensitivity');

  const DeviceTestKind(this.wireName);

  /// Stable identifier used in the saved file. NEVER the enum index: inserting
  /// or removing a value would silently re-label every result already on disk.
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
/// [unavailable] is the honest answer for a check that could not even start -
/// nothing connected, a capture already running, a device that will not say
/// what format it is streaming. It is a RESULT, recorded and exported like any
/// other, because "we could not measure it" is a fact worth having in a
/// before-and-after comparison. What it must never be is a zero, or a default,
/// or a blank row that looks like a pass.
enum DeviceTestOutcome {
  /// Ran to its end and produced its readings.
  completed('completed'),

  /// The operator stopped it. Whatever partial readings it had are kept, and
  /// labelled as partial.
  cancelled('cancelled'),

  /// It could not run at all. [DeviceTestResult.note] says why.
  unavailable('unavailable'),

  /// It started and then failed - the link went away, or no audio arrived.
  /// [DeviceTestResult.note] says what.
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

/// What a running check is waiting for.
///
/// The operator is half of the sensitivity check - they speak - so the phase is
/// not decoration: it is the instruction, and the screen cannot be built
/// without it.
///
/// In `model/` rather than beside the service that sets it, because `view/`
/// renders it and `view/` depends on models, not on services.
enum DeviceTestPhase {
  /// Nothing running.
  idle,

  /// Streaming and measuring for a fixed window.
  measuring,

  /// Writing the result to disk.
  saving,

  /// A batch of samples is part-way through and the next one needs the
  /// operator: they have to speak again.
  awaitingNextSample,
}

/// The names of the measurements, and the one parameter that has to be the
/// same every run.
///
/// Named constants rather than string literals so the service that produces a
/// reading, the card that shows it and the test that asserts on it cannot drift
/// apart in what they call the same number.
///
/// EVERY NAME HERE IS ALSO A KEY IN A FILE ON SOMEBODY'S PHONE. The bare-board
/// baseline is stored under these exact labels, so renaming one silently breaks
/// the comparison the whole file exists for.
abstract final class DeviceTestReadings {
  /// The distance the sensitivity check is spoken from, in centimetres.
  ///
  /// A CONSTANT, not a setting. The number itself does not matter; what matters
  /// is that the run before the enclosure and the run after were taken from the
  /// same place, and a free-text field is how that stops being true.
  static const int sensitivityDistanceCm = 30;

  static const String noiseFloorRms = 'Noise floor (RMS)';
  static const String peak = 'Peak';
  static const String rms = 'RMS';
  static const String framesLost = 'Frames lost';
  static const String audioMeasured = 'Audio measured';

  /// The nRF52840's DIE temperature at the moment of the run. Named "die"
  /// HERE, in the label itself, because the label is what a reader of the
  /// saved result sees - and a plastic case with a cell under the board will
  /// move this figure, which is exactly why it is stamped on every run.
  static const String dieTemperature = 'Die temperature';
}

/// Why a mic check cannot be offered right now.
///
/// The same three-state discipline `AppController` uses for auto-sleep and the
/// battery: a control with nothing truthful behind it is shown as unavailable
/// WITH A REASON, never as a default. The reason is an enum rather than a
/// sentence so the wording stays in `view/`.
enum DeviceTestBlocker {
  /// No link, so there is nothing to measure.
  notConnected,

  /// A capture is running. The frame subscription is exclusive - see
  /// `BleTransport.subscribeFrames` - so a check cannot have one too.
  recording,

  /// Another check is running.
  testRunning,
}

/// One number out of a run, with its unit.
///
/// [value] is nullable because a reading can legitimately be absent from an
/// otherwise good run, and an absent reading must not render as zero.
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

/// A finished run of one check - the thing that is saved, re-read and exported.
class DeviceTestResult {
  const DeviceTestResult({
    required this.kind,
    required this.outcome,
    required this.startedAt,
    required this.duration,
    this.readings = const <DeviceTestReading>[],
    this.note,
    this.batchId,
    this.repeatIndex = 1,
    this.repeatTarget = 1,
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

  /// How long it took.
  final Duration duration;

  /// The numbers, in the order they should be read.
  final List<DeviceTestReading> readings;

  /// Free text: why it was unavailable, what failed, the marked distance, the
  /// caveat that belongs with the figure.
  final String? note;

  /// Which batch of repeated samples this run belongs to, or null when it ran
  /// on its own.
  ///
  /// WHY A BATCH ID AND NOT A TIMESTAMP WINDOW. A single measurement is not
  /// comparable against a single measurement - see
  /// `model/device_test_aggregate.dart` - so the unit of comparison is a set of
  /// samples, and a set needs a name. Grouping by "runs within ten minutes of
  /// each other" would have silently merged two deliberately separate sittings.
  ///
  /// NULL IS NOT A BUG. Every result saved before batches existed has none, and
  /// each of those is read as a batch of one, which is what it was.
  final String? batchId;

  /// 1-based position of this sample within its batch. 1 for a lone run.
  final int repeatIndex;

  /// How many samples the batch was ASKED for, which may be more than it took:
  /// the operator can stop a speak-again check after three of five, and three
  /// samples aggregated beats five samples abandoned. The difference between
  /// this and the number of runs actually saved is what lets the screen say
  /// "n=3 of 5, stopped early" rather than pretending five were taken.
  final int repeatTarget;

  /// The same run, stamped with where it sat in a batch.
  ///
  /// Used by the service as a result is saved, so the places that build one do
  /// not each have to remember the batch fields.
  DeviceTestResult inBatch({
    required String? batchId,
    required int repeatIndex,
    required int repeatTarget,
    Duration? duration,
  }) =>
      DeviceTestResult(
        kind: kind,
        outcome: outcome,
        startedAt: startedAt,
        duration: duration ?? this.duration,
        readings: readings,
        note: note,
        batchId: batchId,
        repeatIndex: repeatIndex,
        repeatTarget: repeatTarget,
      );

  /// Whether this run produced numbers worth comparing.
  bool get hasReadings => readings.any((reading) => reading.value != null);

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
        'note': note,
        // ADDITIVE, and the store's format version is deliberately NOT bumped
        // for them: a file written before these existed reads back with
        // `batchId` null and both counters 1, which is exactly what a lone run
        // is. An older build reading a newer file ignores the three keys it
        // does not know and still gets every reading. See [fromJson].
        'batchId': batchId,
        'repeatIndex': repeatIndex,
        'repeatTarget': repeatTarget,
      };

  /// Reads one saved result.
  ///
  /// Throws [FormatException] on anything it does not recognise, INCLUDING an
  /// unknown [kind] or [outcome]. Two different things look like that: a file
  /// written by a NEWER build, which is not this build's to reinterpret, and a
  /// run of a measurement that has since been retired. Neither is read, and
  /// NEITHER IS DISCARDED - the store keeps the row exactly as it found it and
  /// writes it back out untouched. See `DeviceTestStore`.
  ///
  /// A key this build does not know is IGNORED rather than rejected. That is
  /// what lets a run saved by an older build - one that also wrote a `steps`
  /// list for the range walk - still read as a result.
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
    final batchId = json['batchId'];
    if (batchId != null && batchId is! String) {
      throw const FormatException('result batchId must be a string or null');
    }
    return DeviceTestResult(
      kind: kind,
      outcome: outcome,
      startedAt: DateTime.parse(startedAt),
      duration: Duration(milliseconds: durationMs),
      readings: _listOf(json['readings'], DeviceTestReading.fromJson),
      note: note as String?,
      batchId: batchId as String?,
      repeatIndex: _counter(json['repeatIndex'], 'repeatIndex'),
      repeatTarget: _counter(json['repeatTarget'], 'repeatTarget'),
    );
  }

  /// A batch counter out of a saved file.
  ///
  /// ABSENT MEANS ONE, which is what keeps every result written before batches
  /// existed readable: a lone run IS sample 1 of 1. A value below one is
  /// nonsense rather than a different meaning, so it is pulled up to one rather
  /// than costing the row - a mangled counter must not lose a measurement.
  static int _counter(Object? raw, String name) {
    if (raw == null) return 1;
    if (raw is! int) {
      throw FormatException('result $name must be an integer');
    }
    return raw < 1 ? 1 : raw;
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
      '${outcome.wireName}, $startedAt, ${readings.length} readings, '
      'sample $repeatIndex of $repeatTarget)';
}
