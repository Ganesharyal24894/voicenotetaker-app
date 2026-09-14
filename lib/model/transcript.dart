/// A recording's saved transcript, and what the note screen can say about
/// one.
///
/// Pure data, like `DeviceTestResult`: JSON in and out, no I/O. Where the file
/// lives and how it is read is `services/transcription/transcript_store.dart`.
library;

import 'transcription.dart';

/// The words heard in one recording, kept beside it so they are never worked
/// out twice.
class Transcript {
  const Transcript({
    required this.languageCode,
    required this.modelId,
    required this.createdAt,
    required this.audioDuration,
    required this.segments,
    this.englishModelMissing = false,
  });

  /// Built from a finished job. [languageCode] overrides the result's own.
  factory Transcript.fromResult(
    TranscriptionResult result, {
    String? languageCode,
    required DateTime createdAt,
  }) =>
      Transcript(
        languageCode: languageCode ?? result.languageCode,
        modelId: result.modelId,
        createdAt: createdAt,
        audioDuration: result.audioDuration,
        segments: result.segments,
        englishModelMissing: result.englishModelMissing,
      );

  /// Bumped when the saved shape changes incompatibly. A file with another
  /// version is treated as absent, so the recording can be transcribed again.
  ///
  /// Still 1 after segments gained an optional `speaker`: the key is written
  /// only when there is one, an older file without it reads as "no speakers",
  /// and an older build reading a newer file ignores the key it does not know.
  /// Nothing that could be read before became unreadable, so nothing is
  /// transcribed twice.
  ///
  /// Still 1 after language routing, for the same reason: segments gained
  /// optional `lang` and `model`, the transcript an optional
  /// `englishModelMissing`, and `language` may now also read `en` or `auto`
  /// - all strings an older build already accepts.
  static const int formatVersion = 1;

  /// `hi` or `en` when the whole transcript is that language, `auto` when its
  /// segments mix the two. `hi` in every transcript from before routing.
  final String languageCode;

  /// Which model produced it - [SpeechModel.id], or two ids joined with `+`.
  final String modelId;

  /// Some of it sounded English, but the English model was not on the phone,
  /// so those parts are Hindi transliteration. The note screen can say "Add
  /// the English model to transcribe English"; nothing shows it yet.
  final bool englishModelMissing;

  final DateTime createdAt;
  final Duration audioDuration;

  /// One entry per decoded window, in order, possibly empty text.
  final List<TranscriptSegment> segments;

  /// Every segment's text joined with single spaces, silence skipped.
  String get text => segments
      .map((segment) => segment.text.trim())
      .where((text) => text.isNotEmpty)
      .join(' ');

  /// False for a recording in which nothing was recognised - silence, noise,
  /// or no audio at all. Still a result, and still saved.
  bool get hasSpeech => text.isNotEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
        'version': formatVersion,
        'language': languageCode,
        'model': modelId,
        'createdAt': createdAt.toIso8601String(),
        'audioMs': audioDuration.inMilliseconds,
        'segments': <Map<String, Object?>>[
          for (final segment in segments)
            <String, Object?>{
              'startMs': segment.start.inMilliseconds,
              'endMs': segment.end.inMilliseconds,
              'text': segment.text,
              if (segment.speaker != null) 'speaker': segment.speaker,
              if (segment.languageCode != null) 'lang': segment.languageCode,
              if (segment.modelId != null) 'model': segment.modelId,
            },
        ],
        if (englishModelMissing) 'englishModelMissing': true,
      };

  /// The transcript in [json], or `null` when it is not one this build can
  /// read. Never throws: a damaged file must not take the screen down.
  static Transcript? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    if (json['version'] != formatVersion) return null;
    final language = json['language'];
    final model = json['model'];
    final created = json['createdAt'];
    final audioMs = json['audioMs'];
    final rawSegments = json['segments'];
    if (language is! String ||
        model is! String ||
        created is! String ||
        audioMs is! int ||
        rawSegments is! List<Object?>) {
      return null;
    }
    final createdAt = DateTime.tryParse(created);
    if (createdAt == null) return null;
    final segments = <TranscriptSegment>[];
    for (final raw in rawSegments) {
      if (raw is! Map<String, Object?>) return null;
      final start = raw['startMs'];
      final end = raw['endMs'];
      final text = raw['text'];
      if (start is! int || end is! int || text is! String) return null;
      // Optional, and lenient: a label of the wrong type costs the speaker,
      // never the whole transcript.
      final speaker = raw['speaker'];
      final lang = raw['lang'];
      final segmentModel = raw['model'];
      segments.add(
        TranscriptSegment(
          start: Duration(milliseconds: start),
          end: Duration(milliseconds: end),
          text: text,
          speaker: speaker is String && speaker.isNotEmpty ? speaker : null,
          languageCode: lang is String && lang.isNotEmpty ? lang : null,
          modelId: segmentModel is String && segmentModel.isNotEmpty
              ? segmentModel
              : null,
        ),
      );
    }
    return Transcript(
      languageCode: language,
      modelId: model,
      createdAt: createdAt,
      audioDuration: Duration(milliseconds: audioMs),
      segments: List<TranscriptSegment>.unmodifiable(segments),
      englishModelMissing: json['englishModelMissing'] == true,
    );
  }
}

/// What the note screen shows for one recording's transcript.
enum TranscriptStatus {
  /// The saved transcript has not been looked for yet.
  checking,

  /// There is none, and nothing is running: offer to make one.
  none,

  /// This recording is being transcribed now.
  running,

  /// Waiting its turn in the background queue.
  queued,

  /// Saved, with words in it.
  done,

  /// Saved, and nothing was recognised.
  noSpeech,

  /// The model is not on this phone, or only partly.
  modelMissing,

  /// The file is not audio the model can take.
  unsupported,

  /// The engine failed. Worth trying again.
  failed,
}
