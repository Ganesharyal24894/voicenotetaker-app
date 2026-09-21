import 'dart:io';

import '../model/speech_presence.dart';
import 'speech_recognizer.dart' show pcm16leToFloat32;

/// Reads a whole note's PCM once and measures the floor every window is then
/// judged against ([SpeechPresence]).
///
/// WHY A PASS OF ITS OWN. The windows are decoded one at a time and in order,
/// so the last window's audio is not available when the first one is judged -
/// and a floor built from what has been seen so far would judge the start of
/// a note against nothing. Reading the file through costs an O(n) sum per
/// sample against a decode at RTF 0.14: about a thousandth of the work it is
/// there to avoid.
///
/// SEPARATE FILE because the recognizer driver it serves is already 558 lines
/// and the project's rule is ~300.
///
/// Null when the floor could not be measured - the note is shorter than one
/// 20 ms block, the read failed, or [stop] asked for the job to end. The
/// caller then decodes every window, exactly as it did before this existed.
Future<double?> measureNoiseFloor({
  required RandomAccessFile audio,
  required int dataOffset,
  required int totalSamples,
  required int sampleRateHz,
  required bool Function() stop,
}) async {
  if (totalSamples <= 0 || sampleRateHz <= 0) return null;
  final floor = NoiseFloor(sampleRateHz: sampleRateHz);
  // One second at a time, yielding between, so a cancel is seen promptly -
  // the same rhythm the voice-activity pass reads at.
  final chunk = sampleRateHz;
  try {
    for (var start = 0; start < totalSamples; start += chunk) {
      await Future<void>.delayed(Duration.zero);
      if (stop()) return null;
      final count = start + chunk < totalSamples ? chunk : totalSamples - start;
      audio.setPositionSync(dataOffset + start * 2);
      final bytes = audio.readSync(count * 2);
      if (bytes.isEmpty) break;
      floor.add(pcm16leToFloat32(bytes));
    }
  } on Object {
    // A short or unreadable file is the decode's problem to report, not this
    // one's; without a floor nothing is skipped.
    return null;
  }
  return floor.dbfs;
}
