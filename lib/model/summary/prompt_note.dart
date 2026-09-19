/// One note as a prompt needs it: when, how long, who, and the words.
///
/// PURE. Built from a saved `Transcript` today, whose segments carry no
/// speakers; a transcript with speaker turns fills [PromptLine.speaker] and
/// the prompt labels the lines without any other change.
library;

import '../transcript.dart';

/// One stretch of words in a note.
class PromptLine {
  const PromptLine({required this.text, this.speaker, this.at});

  final String text;

  /// `Speaker 1`, or null when the transcript does not say.
  final String? speaker;

  /// Offset into the recording, when known.
  final Duration? at;
}

class PromptNote {
  const PromptNote({
    required this.startedAt,
    required this.duration,
    required this.lines,
    this.speakerCount,
  });

  /// Lines of about [lineSpan] each, from a transcript's decoded windows.
  ///
  /// The windows are ~16 s long (`model/decode_window.dart`); one line each
  /// would bury the words under
  /// timestamps. Consecutive windows are joined until a line spans
  /// [lineSpan], which keeps a "[01:30]" marker close enough to find the
  /// moment in the audio.
  factory PromptNote.fromTranscript({
    required DateTime startedAt,
    required Duration duration,
    required Transcript transcript,
    int? speakerCount,
    Duration lineSpan = const Duration(seconds: 30),
  }) {
    final lines = <PromptLine>[];
    Duration? lineStart;
    final words = <String>[];
    void flush() {
      if (words.isEmpty) return;
      lines.add(PromptLine(text: words.join(' '), at: lineStart));
      words.clear();
      lineStart = null;
    }

    for (final segment in transcript.segments) {
      final text = segment.text.trim();
      if (text.isEmpty) continue;
      lineStart ??= segment.start;
      words.add(text);
      if (segment.end - lineStart! >= lineSpan) flush();
    }
    flush();
    return PromptNote(
      startedAt: startedAt,
      duration: duration,
      lines: lines,
      speakerCount: speakerCount,
    );
  }

  final DateTime startedAt;
  final Duration duration;
  final List<PromptLine> lines;

  /// Null when unknown, which the prompt then leaves out.
  final int? speakerCount;

  bool get hasWords => lines.any((line) => line.text.trim().isNotEmpty);

  bool get hasSpeakers => lines.any((line) => line.speaker != null);

  int get wordCount => lines.fold(0, (sum, line) => sum + countWords(line.text));

  static int countWords(String text) =>
      text.split(RegExp(r'\s+')).where((word) => word.isNotEmpty).length;
}
