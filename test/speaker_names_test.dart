import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/speaker_names.dart';
import 'package:voicenotetaker_app/services/library_service.dart';
import 'package:voicenotetaker_app/services/transcription/speaker_names_store.dart';

import 'view/harness.dart';

void main() {
  setUpAll(registerViewFallbacks);

  group('SpeakerNames', () {
    test('unnamed speakers are Speaker N by the order they first speak', () {
      const names = SpeakerNames.empty;
      expect(names.labelFor('S7', <String>['S7', 'S2']), 'Speaker 1');
      expect(names.labelFor('S2', <String>['S7', 'S2']), 'Speaker 2');
    });

    test('changes are trimmed, and a blank name clears one', () {
      final names = SpeakerNames.empty
          .withChanges(<String, String>{'S1': '  Priya ', 'S2': 'Amit'})
          .withChanges(<String, String>{'S2': '   '});

      expect(names.customName('S1'), 'Priya');
      expect(names.customName('S2'), isNull);
      expect(names.labelFor('S2', <String>['S1', 'S2']), 'Speaker 2');
    });

    test('round trips, and anything unreadable is empty rather than a throw',
        () {
      final names = SpeakerNames.empty
          .withChanges(<String, String>{'S1': 'प्रिया'});
      expect(
        SpeakerNames.fromJson(jsonDecode(jsonEncode(names.toJson()))),
        names,
      );
      expect(SpeakerNames.fromJson('nope'), SpeakerNames.empty);
      expect(
        SpeakerNames.fromJson(<String, Object?>{'version': 9, 'names': {}}),
        SpeakerNames.empty,
      );
    });
  });

  group('SpeakerNamesStore', () {
    const wav = '/rec/voicenote-20260914-120000.wav';

    test('lives beside the recording', () {
      expect(
        RecordingNaming.speakerNamesPathOf(wav),
        '/rec/voicenote-20260914-120000.speakers.json',
      );
    });

    test('saves, loads, and removes the file when no names are left',
        () async {
      final files = MemoryFileStore();
      final store = SpeakerNamesStore(fileStore: files);
      final names =
          SpeakerNames.empty.withChanges(<String, String>{'S1': 'Priya'});

      await store.save(wav, names);
      expect(await store.load(wav), names);

      await store.save(wav, SpeakerNames.empty);
      expect(files.files, isEmpty);
      expect(await store.load(wav), SpeakerNames.empty);
    });

    test('a damaged file reads as no names', () async {
      final files = MemoryFileStore()
        ..files[RecordingNaming.speakerNamesPathOf(wav)] = utf8.encode('{');
      expect(
        await SpeakerNamesStore(fileStore: files).load(wav),
        SpeakerNames.empty,
      );
    });
  });

  group('renaming through the controller', () {
    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

    test('persists across a restart and survives a transcript made again',
        () async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      final path = await harness.seedRecording();

      await harness.controller.renameSpeakers(
        path,
        <String, String>{'S1': 'Priya', 'S2': 'Amit'},
      );
      expect(harness.controller.speakerNamesFor(path).customName('S1'), 'Priya');

      // Transcribing again replaces the transcript file whole; the names are
      // a separate file and are not touched.
      harness.fileStore.files[RecordingNaming.transcriptPathOf(path)] =
          utf8.encode('{"version":1}');

      final restarted = ViewHarness();
      addTearDown(restarted.dispose);
      restarted.fileStore.files.addAll(harness.fileStore.files);
      await restarted.controller.refreshLibrary();
      await restarted.controller.loadSpeakerNames(path);
      await settle();

      final names = restarted.controller.speakerNamesFor(path);
      expect(names.customName('S1'), 'Priya');
      expect(names.customName('S2'), 'Amit');
    });

    test('deleting the note deletes its speaker names', () async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);
      final path = await harness.seedRecording();
      await harness.controller
          .renameSpeakers(path, <String, String>{'S1': 'Priya'});
      expect(
        harness.fileStore.files,
        contains(RecordingNaming.speakerNamesPathOf(path)),
      );

      await harness.controller
          .deleteRecording(harness.controller.recordings.single);

      expect(harness.fileStore.files, isEmpty);
    });
  });
}
