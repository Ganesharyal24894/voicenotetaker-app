/// Can a decode window contain speech at all?
///
/// A window that holds nothing but the note's own noise floor is handed
/// straight back as "" instead of costing a full recognizer decode. Pure
/// arithmetic over PCM: no plugin, no file, no isolate, so the decision is
/// decided here and tested on the host.
///
/// WHAT WAS MEASURED, AND WHAT IT COST THE CLAIM THIS EXISTS FOR.
/// The todo row this comes from says 44.6 % of the app's segments are empty
/// (319 of 716 on the owner's 51 newest notes) and reads that as 45 % of
/// decode time waiting to be skipped. Those two are NOT the same thing, and
/// the audio says so. Over 1 652 real windows whose text the app (or the
/// evaluation harness running the app's own pipeline) actually produced -
/// the 716 turn windows of `out/app-transcripts.json`, the 772 grid windows of
/// `out/windows-iphone-old-grid.json` and the 164 of
/// `out/windows-device-grid.json`, all under
/// `notetaker-data/accuracy-20260918-205506/` - the windows that decoded to ""
/// are NOT quiet:
///
/// | statistic, per window | produced text (949) | produced "" (703) |
/// |---|---|---|
/// | loudest 20 ms above the note's floor (pre-emphasised) | median 18.2 dB, min **2.23** | median 9.6 dB, min 2.85 |
/// | loudest 20 ms above the note's floor (no pre-emphasis) | median 20.7 dB | median 20.6 dB |
///
/// The empty windows sit ON TOP of the windows that produced words. They are
/// not silence: they are audible material the recognizer had nothing to say
/// about - far speech, handling noise, a fan, someone else's conversation.
/// Ten other statistics were tried (speech-band level, band ratio, fraction
/// and longest run of frames above the floor, 95th percentile, tenth-loudest
/// frame, and floors at the 5th to 50th percentile, with and without
/// pre-emphasis): none separates the two at ANY threshold that keeps every
/// window that produced text. The measured trade, on those same 1 652
/// windows, is in `notetaker-data/silence-skip-20260921/`:
///
/// | threshold | windows skipped | windows with text skipped |
/// |---|---|---|
/// | **1.1 dB (here)** | **0.0 %** | **0** |
/// | 2 dB | 0.0 % | 0 |
/// | 5 dB | 4.9 % | 7 |
/// | 8 dB | 18.4 % | 56 |
/// | 10 dB | 30.3 % | 132 |
///
/// So this check is honest about being small: on 13.6 hours of the owner's own
/// recordings (3 250 windows of 16 s across the 141 device notes and the 136
/// iPhone-synced ones) it skips 0 windows at the shipped threshold and 1 at
/// 2 dB. It is a floor under the cost of dead air, not the 45 % the row hoped
/// for. The 45 % is not reachable by a silence check, because the empty
/// segments are not silent.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// The verdict, and the numbers behind it.
abstract final class SpeechPresence {
  /// The block every level is measured over.
  ///
  /// 20 ms is the firmware speech gate's own block (`speech_gate.c`), so the
  /// app and the recorder describe loudness in the same unit. It is also
  /// short enough that one syllable spans several blocks and long enough that
  /// a single sample of pop does not become a block of speech.
  static const Duration frame = Duration(milliseconds: 20);

  /// Where the note's noise floor is read off its own block levels.
  ///
  /// The 5th percentile, not the minimum: one dropout, one moment of the
  /// radio muting, or one all-zero block would drag the minimum to digital
  /// silence and make every real block look loud by comparison. Not the
  /// median either - in a note that is mostly talk the median IS talk, and a
  /// floor made of speech would put quiet speech below it.
  static const double floorPercentile = 0.05;

  /// How far above the floor a window's loudest block may sit and still be
  /// skipped.
  ///
  /// 1.1 dB is HALF the smallest margin ever measured on a window that
  /// produced text: 2.23 dB, over 949 such windows (see the library comment).
  /// Half, because losing a word costs the owner a note and skipping one more
  /// window saves a fraction of a second - the asymmetry is not close. 1.1 dB
  /// is also smaller than the block-to-block jitter of a steady noise floor
  /// itself, which is what "this window is nothing but the floor" has to mean
  /// to be safe. Raising it to 2 dB would buy one window in 3 250 and leave
  /// 0.23 dB of margin; it is not worth it.
  static const double skipWithinDb = 1.1;

  /// The level reported for a block of digital silence.
  ///
  /// An all-zero block has no logarithm. -180 dBFS is far below 16-bit
  /// quantisation noise (-96 dBFS), so it can never be mistaken for signal,
  /// and it is the same convention the measurement harness prints.
  static const double silenceDbfs = -180;

  /// Samples in one [frame] at [sampleRateHz]; at least one.
  static int frameSamples(int sampleRateHz) =>
      math.max(1, sampleRateHz * frame.inMilliseconds ~/ 1000);

  /// Whether [samples] - one decode window - can contain speech, given the
  /// noise floor of the note it came from.
  ///
  /// TRUE MEANS DECODE, AND SO DOES NOT KNOWING. A window shorter than one
  /// block, or a note whose floor could not be measured
  /// ([NoiseFloor.dbfs] null), is decoded: this check may only ever remove
  /// work it is certain is wasted.
  static bool canContainSpeech({
    required Float32List samples,
    required int sampleRateHz,
    double? noiseFloorDbfs,
  }) {
    if (noiseFloorDbfs == null) return true;
    final level = loudestBlockDbfs(samples, sampleRateHz);
    if (level == null) return true;
    return level > noiseFloorDbfs + skipWithinDb;
  }

  /// The loudest whole block in [samples], in dBFS, or null when there is not
  /// one whole block.
  ///
  /// THE LOUDEST, not the average: a window is kept if ANY 20 ms of it rises
  /// above the floor, even one. An average would let a second of speech
  /// disappear into fifteen seconds of quiet.
  static double? loudestBlockDbfs(Float32List samples, int sampleRateHz) {
    double? loudest;
    forEachBlockDbfs(
      samples,
      sampleRateHz,
      (level) {
        if (loudest == null || level > loudest!) loudest = level;
      },
    );
    return loudest;
  }

  /// Calls [onLevel] with the dBFS level of every whole block in [samples].
  ///
  /// PRE-EMPHASISED: every block is measured on the difference between
  /// consecutive samples rather than on the samples themselves. That is a
  /// 6 dB/octave high-pass, and it is here because the noise this app has to
  /// survive is low-frequency - a desk thump, a shirt rubbing the recorder,
  /// a fan, mains hum. Raw RMS lets that noise both look like speech AND
  /// inflate the floor it is compared against; measured on the owner's notes,
  /// a raw-RMS floor told the windows that produced words apart from the ones
  /// that produced nothing not at all (median 20.7 dB vs 20.6 dB above the
  /// floor - the same number). Pre-emphasised, the same comparison reads
  /// 18.2 dB vs 9.6 dB. Speech loses level too, but the floor is measured the
  /// same way, so the comparison is fair.
  ///
  /// [previous] is the sample before [samples] - the caller carries it across
  /// chunk boundaries so a note measured in pieces reads exactly like the same
  /// note measured whole. Returns the last sample seen, for the next call.
  static double forEachBlockDbfs(
    Float32List samples,
    int sampleRateHz,
    void Function(double level) onLevel, {
    double previous = 0,
  }) {
    final block = frameSamples(sampleRateHz);
    final blocks = samples.length ~/ block;
    var last = previous;
    for (var b = 0; b < blocks; b++) {
      var sum = 0.0;
      final end = (b + 1) * block;
      for (var i = b * block; i < end; i++) {
        final value = samples[i];
        final step = value - last;
        last = value;
        sum += step * step;
      }
      onLevel(dbfs(math.sqrt(sum / block)));
    }
    for (var i = blocks * block; i < samples.length; i++) {
      last = samples[i];
    }
    return last;
  }

  /// [amplitude] (0..1) as dBFS, with digital silence at [silenceDbfs].
  static double dbfs(double amplitude) => amplitude <= 0
      ? silenceDbfs
      : math.max(silenceDbfs, 20 * math.log(amplitude) / math.ln10);
}

/// One note's noise floor, measured over the whole recording.
///
/// WHY THE WHOLE NOTE, AND WHY OFFLINE. The recorder's own gate has to decide
/// in 20 ms with an adaptive floor that can only look backwards
/// (`speech_gate.c`). Here the note is already on disk, so the floor is the
/// note's own quiet material wherever it falls - which matters because the
/// recording ARRIVED with silence in it: the gate sends 540 ms of pre-roll
/// before the speech that opened it and a hangover tail after, so quiet at a
/// window's edges is expected and says nothing about the window.
///
/// Fed in chunks, in order. Holds one level per 20 ms - about 700 KB for an
/// hour of audio, against the 509 MB a decode peaks at.
class NoiseFloor {
  NoiseFloor({required this.sampleRateHz});

  /// The rate every chunk is at.
  final int sampleRateHz;

  final List<double> _levels = <double>[];
  final List<double> _carry = <double>[];
  double _previous = 0;

  /// How many whole blocks have been measured.
  int get blocks => _levels.length;

  /// Feeds the next [chunk] of the note. Chunks need not be block-aligned.
  void add(Float32List chunk) {
    final block = SpeechPresence.frameSamples(sampleRateHz);
    if (_carry.isEmpty && chunk.length % block == 0) {
      _previous = SpeechPresence.forEachBlockDbfs(
        chunk,
        sampleRateHz,
        _levels.add,
        previous: _previous,
      );
      return;
    }
    // Partial block left from the last chunk: glue it to the front of this one
    // so the blocks line up exactly as they would have in one pass.
    final joined = Float32List(_carry.length + chunk.length)
      ..setAll(0, _carry)
      ..setAll(_carry.length, chunk);
    final whole = (joined.length ~/ block) * block;
    _previous = SpeechPresence.forEachBlockDbfs(
      Float32List.sublistView(joined, 0, whole),
      sampleRateHz,
      _levels.add,
      previous: _previous,
    );
    _carry
      ..clear()
      ..addAll(joined.sublist(whole));
  }

  /// The floor, or null when the note has not one whole block in it.
  ///
  /// The trailing partial block is left out on purpose: a note that ends
  /// mid-block would otherwise be measured over fewer samples than every
  /// other block and read quieter than it is.
  double? get dbfs {
    if (_levels.isEmpty) return null;
    final sorted = List<double>.of(_levels)..sort();
    final at = ((sorted.length - 1) * SpeechPresence.floorPercentile).floor();
    return sorted[at];
  }
}
