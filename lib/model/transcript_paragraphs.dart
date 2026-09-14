/// A transcript laid out for reading: paragraphs, speakers, words, and which
/// paragraph the playhead is in.
///
/// PURE: no clock, no I/O, no widgets. The note screen renders what this
/// returns, and every rule is a unit test.
library;

import 'speaker_names.dart';
import 'transcript.dart';

/// Consecutive segments read as one block, with the time it starts at.
class TranscriptParagraph {
  const TranscriptParagraph({
    required this.start,
    required this.end,
    required this.text,
    this.speaker,
  });

  final Duration start;
  final Duration end;
  final String text;

  /// The speaker label shared by every segment in it; null without speakers.
  final String? speaker;

  @override
  String toString() => 'TranscriptParagraph($start-$end $speaker: $text)';
}

abstract final class TranscriptLayout {
  /// Without speakers, a paragraph is closed once it is this long, so the
  /// timestamps stay close enough together to find a moment by.
  static const Duration maxParagraph = Duration(seconds: 30);

  /// A pause at least this long starts a new paragraph.
  static const Duration pauseBreak = Duration(seconds: 2);

  /// The spoken segments grouped into paragraphs, in order. Silent segments
  /// are dropped. A new paragraph starts when the speaker changes, after a
  /// [pauseBreak], or - for the same speaker - once [maxParagraph] is reached.
  static List<TranscriptParagraph> paragraphs(Transcript transcript) {
    final result = <TranscriptParagraph>[];
    Duration? start;
    var end = Duration.zero;
    String? speaker;
    final words = <String>[];

    void close() {
      if (start == null) return;
      result.add(
        TranscriptParagraph(
          start: start!,
          end: end,
          text: words.join(' '),
          speaker: speaker,
        ),
      );
      start = null;
      words.clear();
    }

    for (final segment in transcript.segments) {
      final text = segment.text.trim();
      if (text.isEmpty) continue;
      final open = start;
      if (open != null &&
          (segment.speaker != speaker ||
              segment.start - end >= pauseBreak ||
              segment.end - open > maxParagraph)) {
        close();
      }
      if (start == null) {
        start = segment.start;
        speaker = segment.speaker;
      }
      end = segment.end;
      words.add(text);
    }
    close();
    return result;
  }

  /// Speaker labels in the order they first speak. Empty without speakers.
  static List<String> speakers(Transcript transcript) {
    final seen = <String>[];
    for (final segment in transcript.segments) {
      final speaker = segment.speaker;
      if (speaker == null || segment.text.trim().isEmpty) continue;
      if (!seen.contains(speaker)) seen.add(speaker);
    }
    return seen;
  }

  static final RegExp _space = RegExp(r'\s+');

  /// Words in the transcript, split on whitespace - which is how Hindi is
  /// written too.
  static int wordCount(Transcript transcript) {
    final text = transcript.text.trim();
    return text.isEmpty ? 0 : text.split(_space).length;
  }

  /// The paragraph being heard at [position]: the one it falls inside, or in a
  /// pause, the one just heard - so the highlight does not flicker off between
  /// sentences. Null before the first paragraph starts, or with none.
  static int? paragraphAt(
    List<TranscriptParagraph> paragraphs,
    Duration position,
  ) {
    int? found;
    for (var i = 0; i < paragraphs.length; i++) {
      if (paragraphs[i].start > position) break;
      found = i;
    }
    return found;
  }

  /// The transcript as text to paste elsewhere: one paragraph per line, with
  /// its time and - when there are speakers - who said it.
  ///
  /// `[00:42] Speaker 2: ...`, or `[00:42] ...` without speakers.
  static String plainText(Transcript transcript, SpeakerNames names) {
    final order = speakers(transcript);
    return <String>[
      for (final paragraph in paragraphs(transcript))
        paragraph.speaker == null
            ? '[${timestamp(paragraph.start)}] ${paragraph.text}'
            : '[${timestamp(paragraph.start)}] '
                '${names.labelFor(paragraph.speaker!, order)}: '
                '${paragraph.text}',
    ].join('\n');
  }

  /// `00:42`, or `1:02:07` past an hour.
  static String timestamp(Duration at) {
    String two(int value) => value.toString().padLeft(2, '0');
    final seconds = at.inSeconds.abs();
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final secs = seconds % 60;
    if (hours > 0) return '$hours:${two(minutes)}:${two(secs)}';
    return '${two(minutes)}:${two(secs)}';
  }
}
