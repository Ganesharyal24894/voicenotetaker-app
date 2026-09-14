import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/transcript.dart';
import 'package:voicenotetaker_app/model/transcription.dart';
import 'package:voicenotetaker_app/services/library_service.dart';
import 'package:voicenotetaker_app/services/transcription/transcript_store.dart';
import 'package:voicenotetaker_app/services/wav_writer.dart';

import 'library_service_test.dart' show InMemoryFileStore;

const String _dir = '/rec';
const String _wav = '$_dir/voicenote-20260914-120000.wav';

Transcript _transcript(List<String> texts) => Transcript(
      languageCode: 'hi',
      modelId: 'indicconformer-hi-int8',
      createdAt: DateTime.utc(2026, 9, 14, 12, 30),
      audioDuration: Duration(seconds: 8 * texts.length),
      segments: <TranscriptSegment>[
        for (var i = 0; i < texts.length; i++)
          TranscriptSegment(
            start: Duration(seconds: 8 * i),
            end: Duration(seconds: 8 * (i + 1)),
            text: texts[i],
          ),
      ],
    );

void main() {
  late InMemoryFileStore files;
  late TranscriptStore store;

  setUp(() {
    files = InMemoryFileStore();
    store = TranscriptStore(fileStore: files);
  });

  group('where a transcript lives', () {
    test('beside the recording, .wav swapped for .transcript.json', () {
      expect(
        RecordingNaming.transcriptPathOf(_wav),
        '$_dir/voicenote-20260914-120000.transcript.json',
      );
      expect(store.pathFor(_wav), RecordingNaming.transcriptPathOf(_wav));
    });

    test('an upper-case extension is swapped too', () {
      expect(
        RecordingNaming.transcriptPathOf('/rec/NOTE.WAV'),
        '/rec/NOTE.transcript.json',
      );
    });
  });

  group('save and load', () {
    test('a saved transcript comes back as it was', () async {
      await store.save(_wav, _transcript(<String>['नमस्ते दोस्त', '', 'कहानी']));

      expect(files.files.keys, contains(store.pathFor(_wav)));
      final loaded = await store.load(_wav);

      expect(loaded, isNotNull);
      expect(loaded!.text, 'नमस्ते दोस्त कहानी');
      expect(loaded.hasSpeech, isTrue);
      expect(loaded.languageCode, 'hi');
      expect(loaded.modelId, 'indicconformer-hi-int8');
      expect(loaded.createdAt, DateTime.utc(2026, 9, 14, 12, 30));
      expect(loaded.audioDuration, const Duration(seconds: 24));
      expect(loaded.segments, hasLength(3));
      expect(loaded.segments[2].start, const Duration(seconds: 16));
      expect(loaded.segments[1].text, '');
    });

    test('a transcript with no speech is saved and loaded as one', () async {
      await store.save(_wav, _transcript(<String>['', ' ']));

      final loaded = await store.load(_wav);
      expect(loaded, isNotNull);
      expect(loaded!.hasSpeech, isFalse);
      expect(loaded.text, isEmpty);
    });

    test('saving again replaces the old transcript', () async {
      await store.save(_wav, _transcript(<String>['पहला']));
      await store.save(_wav, _transcript(<String>['दूसरा']));

      expect((await store.load(_wav))!.text, 'दूसरा');
    });

    test('no file is no transcript', () async {
      expect(await store.load(_wav), isNull);
    });

    test('a damaged file is no transcript, not an error', () async {
      files.put(store.pathFor(_wav), utf8.encode('{"version": 1, "segm'));
      expect(await store.load(_wav), isNull);

      files.put(store.pathFor(_wav), <int>[0xff, 0xfe, 0x00]);
      expect(await store.load(_wav), isNull);
    });

    test('a file from another format version is ignored', () async {
      final json = _transcript(<String>['नमस्ते']).toJson()..['version'] = 99;
      files.put(store.pathFor(_wav), utf8.encode(jsonEncode(json)));

      expect(await store.load(_wav), isNull);
    });

    test('delete removes it, and deleting nothing is fine', () async {
      await store.save(_wav, _transcript(<String>['नमस्ते']));
      await store.delete(_wav);
      await store.delete(_wav);

      expect(await store.load(_wav), isNull);
    });
  });

  group('with the library', () {
    late LibraryService library;

    setUp(() {
      library = LibraryService(fileStore: files, directory: _dir);
      files.put(
        _wav,
        WavWriter.wrapPcm(
          Uint8List(16000),
          sampleRateHz: 16000,
          channels: 1,
          bitsPerSample: 16,
        ),
      );
    });

    tearDown(() => library.dispose());

    test('a transcript is never listed as a recording', () async {
      await store.save(_wav, _transcript(<String>['नमस्ते']));

      final listed = await library.refresh();
      expect(listed.map((r) => r.path), <String>[_wav]);
    });

    test('deleting a recording deletes its transcript', () async {
      await store.save(_wav, _transcript(<String>['नमस्ते']));
      await library.refresh();

      await library.delete(_wav);

      expect(files.files.containsKey(_wav), isFalse);
      expect(files.files.containsKey(store.pathFor(_wav)), isFalse);
      expect(library.current, isEmpty);
    });

    test('deleting a recording that has no transcript still works', () async {
      await library.refresh();
      await library.delete(_wav);
      expect(library.current, isEmpty);
    });
  });
}
