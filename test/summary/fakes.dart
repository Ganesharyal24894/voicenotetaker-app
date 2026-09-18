import 'dart:ui';

import 'package:voicenotetaker_app/drivers/clipboard_text.dart';
import 'package:voicenotetaker_app/drivers/share_sheet.dart';
import 'package:voicenotetaker_app/model/recording_info.dart';
import 'package:voicenotetaker_app/model/transcript.dart';
import 'package:voicenotetaker_app/model/transcription.dart';

class FakeClipboard implements ClipboardText {
  String? text;
  int reads = 0;

  @override
  Future<String?> read() async {
    reads++;
    return text;
  }

  @override
  Future<void> write(String value) async => text = value;
}

class FakeShareSheet implements ShareSheet {
  final List<String> shared = <String>[];
  final List<List<String>> sharedFiles = <List<String>>[];

  @override
  Future<void> shareText(String text, {String? subject, Rect? origin}) async =>
      shared.add(text);

  @override
  Future<void> shareFiles(
    List<String> paths, {
    String? subject,
    String? text,
    Rect? origin,
  }) async =>
      sharedFiles.add(List<String>.of(paths));
}

RecordingInfo recordingAt(DateTime at, {int minutes = 12, bool hasTranscript = true}) => RecordingInfo(
      path: '/rec/voicenote-${at.millisecondsSinceEpoch}.wav',
      name: 'voicenote.wav',
      recordedAt: at,
      sizeBytes: 1000,
      duration: Duration(minutes: minutes),
      hasTranscript: hasTranscript,
    );

Transcript transcriptOf(String text) => Transcript(
      languageCode: 'hi',
      modelId: 'test',
      createdAt: DateTime(2026),
      audioDuration: const Duration(seconds: 8),
      segments: <TranscriptSegment>[
        TranscriptSegment(start: Duration.zero, end: const Duration(seconds: 8), text: text),
      ],
    );
