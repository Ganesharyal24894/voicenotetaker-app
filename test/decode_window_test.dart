import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/decode_window.dart';
import 'package:voicenotetaker_app/model/speaker_turns.dart';
import 'package:voicenotetaker_app/model/transcription.dart';

/// The one constant every window in the app is cut from, and the guard that
/// shortens it on a phone that is short of memory.
void main() {
  group('the window', () {
    // Measured, not chosen: 16 s beat 8 s on every set in
    // `notetaker-data/accuracy-20260918-205506/` (owner's notes on the shipped
    // path WER 59.41 -> 57.53, 189 decodes -> 116), and 24 s and 30 s bought
    // nothing for 40 and 226 MB more peak RSS. Moving this number means
    // re-running that evaluation.
    test('is 16 s, and the fallback is the 8 s that shipped before', () {
      expect(DecodeWindow.standard, const Duration(seconds: 16));
      expect(DecodeWindow.lowMemory, const Duration(seconds: 8));
    });

    test('is what both speech models are cut on', () {
      expect(
        SpeechModels.indicConformerHindiInt8.maxWindow,
        DecodeWindow.standard,
      );
      expect(
        SpeechModels.parakeetTdtEnglishInt8.maxWindow,
        DecodeWindow.standard,
      );
    });

    test('leaves room for the splitter to hunt in, at either length', () {
      expect(SpeakerTurns.splitFrom, lessThan(DecodeWindow.standard));
      expect(SpeakerTurns.splitFrom, lessThan(DecodeWindow.lowMemory));
    });
  });

  group('forAvailableMemory', () {
    test('plenty free: the measured window', () {
      expect(
        DecodeWindow.forAvailableMemory(2 * 1024 * 1024),
        DecodeWindow.standard,
      );
    });

    test('scraping: the shorter one', () {
      expect(DecodeWindow.forAvailableMemory(120 * 1024), DecodeWindow.lowMemory);
    });

    test('exactly at the line counts as enough', () {
      expect(
        DecodeWindow.forAvailableMemory(DecodeWindow.lowMemoryBelowKb),
        DecodeWindow.standard,
      );
      expect(
        DecodeWindow.forAvailableMemory(DecodeWindow.lowMemoryBelowKb - 1),
        DecodeWindow.lowMemory,
      );
    });

    // Every platform without /proc says nothing, and there is nothing there to
    // be careful with: the measurements that motivate the fallback are
    // Android's.
    test('a phone that will not say gets the measured window', () {
      expect(DecodeWindow.forAvailableMemory(null), DecodeWindow.standard);
    });
  });
}
