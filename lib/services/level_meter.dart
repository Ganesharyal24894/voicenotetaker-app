import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../model/level_reading.dart';

/// Peak and RMS level of the PCM the app is already decoding.
///
/// No extra data and no firmware change is needed for this: the recorder
/// decodes every ADPCM block to signed 16-bit PCM anyway, so the loudness of
/// each block is a few hundred integer operations on bytes that are already in
/// memory. It runs once per 20 ms block, which is why the hot loop reads the
/// samples in place rather than copying them into a list first.
class LevelMeter {
  LevelMeter({this.floorDbfs = defaultFloorDbfs});

  /// Quietest level reported, in dBFS.
  ///
  /// Digital silence is negative infinity, which no meter can draw, and the
  /// quietest thing 16-bit audio can express short of silence is about
  /// -96.3 dBFS - so the scale stops there.
  static const double defaultFloorDbfs = -96.0;

  /// Sample value that reads as 0 dBFS.
  static const int fullScale = 32767;

  /// Bytes per sample of the s16le PCM this meter consumes.
  static const int _bytesPerSample = 2;

  final double floorDbfs;

  final StreamController<LevelReading> _readings =
      StreamController<LevelReading>.broadcast();

  LevelReading? _last;

  /// A reading per block accepted.
  Stream<LevelReading> get levels => _readings.stream;

  /// The most recent reading, or `null` before the first block.
  LevelReading? get level => _last;

  /// Measures one block of signed 16-bit little-endian PCM.
  ///
  /// Returns `null` for an empty block without publishing anything: an empty
  /// accumulator divided by its own sample count is exactly the divide-by-zero
  /// that has bitten this project before, and there is no meaningful level to
  /// report for no audio at all.
  LevelReading? addPcmS16le(Uint8List pcm) {
    final sampleCount = pcm.length ~/ _bytesPerSample;
    if (sampleCount == 0) return null;

    final view = ByteData.sublistView(pcm);
    var peak = 0;
    // Sum of squares of int16 samples: at most 32768^2 * n, so a 20 ms block
    // stays far inside the 2^63 an int can hold.
    var sumOfSquares = 0;
    for (var i = 0; i < sampleCount; i++) {
      final sample = view.getInt16(i * _bytesPerSample, Endian.little);
      final magnitude = sample < 0 ? -sample : sample;
      if (magnitude > peak) peak = magnitude;
      sumOfSquares += sample * sample;
    }

    return _publish(
      peakSample: peak,
      meanSquare: sumOfSquares / sampleCount,
      sampleCount: sampleCount,
    );
  }

  /// Measures one block of already-decoded samples.
  ///
  /// The same guard applies: an empty block yields `null`, never a division by
  /// zero.
  LevelReading? addSamples(List<int> samples) {
    if (samples.isEmpty) return null;

    var peak = 0;
    var sumOfSquares = 0;
    for (final sample in samples) {
      final magnitude = sample < 0 ? -sample : sample;
      if (magnitude > peak) peak = magnitude;
      sumOfSquares += sample * sample;
    }

    return _publish(
      peakSample: peak,
      meanSquare: sumOfSquares / samples.length,
      sampleCount: samples.length,
    );
  }

  /// Forgets the last reading. Called when a new capture starts.
  void reset() => _last = null;

  Future<void> dispose() async {
    _last = null;
    await _readings.close();
  }

  LevelReading _publish({
    required int peakSample,
    required double meanSquare,
    required int sampleCount,
  }) {
    final reading = LevelReading(
      peakDbfs: dbfsForAmplitude(peakSample.toDouble()),
      rmsDbfs: dbfsForAmplitude(math.sqrt(meanSquare)),
      peakSample: peakSample,
      sampleCount: sampleCount,
    );
    _last = reading;
    if (!_readings.isClosed) _readings.add(reading);
    return reading;
  }

  /// `20 * log10(amplitude / 32767)`, clamped to `[floorDbfs, 0]`.
  ///
  /// Silence would be negative infinity and `-32768` a hair above full scale;
  /// both are clamped, so the value is always a number a meter can draw.
  double dbfsForAmplitude(double amplitude) {
    if (amplitude <= 0) return floorDbfs;
    final dbfs = 20 * (math.log(amplitude / fullScale) / math.ln10);
    if (dbfs.isNaN) return floorDbfs;
    if (dbfs < floorDbfs) return floorDbfs;
    if (dbfs > 0) return 0;
    return dbfs;
  }
}

/// Peak and RMS across a WHOLE measurement window, not one block.
///
/// [LevelMeter] answers "how loud is this 20 ms block", which is what a live
/// meter needs. An acoustic test asks a different question - "how loud was the
/// room over ten seconds" - and the answer is NOT the average of the per-block
/// dBFS figures. dBFS is logarithmic, so averaging it averages the logarithms
/// and quietly under-reports anything with a transient in it; a single door
/// slam in an otherwise silent room would barely move the number. Energy has
/// to be summed in the linear domain and converted once at the end, which is
/// what this does.
///
/// It borrows [LevelMeter.dbfsForAmplitude] rather than repeating the
/// conversion, so the floor and the full-scale reference cannot drift apart
/// from the live meter's.
class LevelWindow {
  LevelWindow({LevelMeter? meter}) : _meter = meter ?? LevelMeter();

  final LevelMeter _meter;

  int _peakSample = 0;
  double _sumOfSquares = 0;
  int _sampleCount = 0;

  /// Samples accumulated so far.
  int get sampleCount => _sampleCount;

  /// Whether anything has been measured at all. False means there is no
  /// reading, which must never be rendered as silence: no audio arrived is a
  /// different fact from the room being quiet.
  bool get hasAudio => _sampleCount > 0;

  /// Absolute value of the loudest sample seen, `0 .. 32768`.
  int get peakSample => _peakSample;

  /// Loudest single sample over the window, or `null` before any audio.
  double? get peakDbfs =>
      hasAudio ? _meter.dbfsForAmplitude(_peakSample.toDouble()) : null;

  /// RMS over the whole window, or `null` before any audio.
  double? get rmsDbfs => hasAudio
      ? _meter.dbfsForAmplitude(math.sqrt(_sumOfSquares / _sampleCount))
      : null;

  /// Accumulates one block of signed 16-bit little-endian PCM.
  ///
  /// An empty block is ignored rather than divided by - the same guard
  /// [LevelMeter.addPcmS16le] has, and for the same reason.
  void addPcmS16le(Uint8List pcm) {
    final count = pcm.length ~/ 2;
    if (count == 0) return;
    final view = ByteData.sublistView(pcm);
    for (var i = 0; i < count; i++) {
      final sample = view.getInt16(i * 2, Endian.little);
      final magnitude = sample < 0 ? -sample : sample;
      if (magnitude > _peakSample) _peakSample = magnitude;
      // Accumulated as a double: at 16 kHz a five-minute window is 4.8e6
      // samples, and 4.8e6 * 32768^2 is about 5.2e15 - inside an int, but only
      // just, and a double carries it with room to spare.
      _sumOfSquares += sample.toDouble() * sample.toDouble();
    }
    _sampleCount += count;
  }

  /// Forgets everything measured, ready for another window.
  void reset() {
    _peakSample = 0;
    _sumOfSquares = 0;
    _sampleCount = 0;
  }
}
