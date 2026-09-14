/// A recording's saved transcript, and what the playback screen can say about
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
  });

  /// Built from a finished job.
  factory Transcript.fromResult(
    TranscriptionResult result, {
    required String languageCode,
    required DateTime createdAt,
  }) =>
      Transcript(
        languageCode: languageCode,
        modelId: result.modelId,
        createdAt: createdAt,
        audioDuration: result.audioDuration,
        segments: result.segments,
      );

  /// Bumped when the saved shape changes incompatibly. A file with another
  /// version is treated as absent, so the recording can be transcribed again.
  static const int formatVersion = 1;

  /// BCP-47 code of the language the model was run for, `hi` today.
  final String languageCode;

  /// Which model produced it - [SpeechModel.id].
  final String modelId;

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
            },
        ],
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
      segments.add(
        TranscriptSegment(
          start: Duration(milliseconds: start),
          end: Duration(milliseconds: end),
          text: text,
        ),
      );
    }
    return Transcript(
      languageCode: language,
      modelId: model,
      createdAt: createdAt,
      audioDuration: Duration(milliseconds: audioMs),
      segments: List<TranscriptSegment>.unmodifiable(segments),
    );
  }
}

/// What the playback screen shows for one recording's transcript.
enum TranscriptStatus {
  /// The saved transcript has not been looked for yet.
  checking,

  /// There is none, and nothing is running: offer to make one.
  none,

  /// This recording is being transcribed now.
  running,

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
