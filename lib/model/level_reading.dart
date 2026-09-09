/// One loudness measurement of a block of PCM, in dBFS.
///
/// Pure data: the arithmetic that produces it lives in
/// `services/level_meter.dart`. Both values are <= 0, where 0 dBFS is a sample
/// at full scale, and both bottom out at the meter's floor rather than running
/// to negative infinity on digital silence.
class LevelReading {
  const LevelReading({
    required this.peakDbfs,
    required this.rmsDbfs,
    required this.peakSample,
    required this.sampleCount,
  });

  /// Loudest single sample in the block.
  final double peakDbfs;

  /// Root-mean-square level of the block.
  final double rmsDbfs;

  /// Absolute value of the loudest sample, `0 .. 32768`.
  final int peakSample;

  /// Number of samples the reading was computed from.
  final int sampleCount;

  @override
  String toString() => 'LevelReading(peak: ${peakDbfs.toStringAsFixed(1)} dBFS,'
      ' rms: ${rmsDbfs.toStringAsFixed(1)} dBFS, samples: $sampleCount)';

  @override
  bool operator ==(Object other) =>
      other is LevelReading &&
      other.peakDbfs == peakDbfs &&
      other.rmsDbfs == rmsDbfs &&
      other.peakSample == peakSample &&
      other.sampleCount == sampleCount;

  @override
  int get hashCode => Object.hash(peakDbfs, rmsDbfs, peakSample, sampleCount);
}
