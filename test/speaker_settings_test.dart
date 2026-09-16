import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/speaker_settings.dart';
import 'package:voicenotetaker_app/services/library_service.dart';
import 'package:voicenotetaker_app/services/transcription/speaker_settings_store.dart';

import 'library_service_test.dart' show InMemoryFileStore;

/// The speaker count and the merges: what they mean, and how they survive a
/// restart.
void main() {
  const wav = '/rec/voicenote-20260916-090000.wav';

  group('count', () {
    test('auto by default', () {
      expect(SpeakerSettings.empty.speakerCount, isNull);
      expect(SpeakerSettings.empty.isEmpty, isTrue);
    });

    test('2, 3 and 4 are taken; 4 means four or more', () {
      for (final count in <int>[2, 3, 4]) {
        expect(SpeakerSettings.empty.withCount(count).speakerCount, count);
      }
    });

    test('back to auto', () {
      expect(
        SpeakerSettings.empty.withCount(3).withCount(null).speakerCount,
        isNull,
      );
    });

    test('anything else is refused rather than quietly clamped', () {
      expect(() => SpeakerSettings.empty.withCount(1), throwsArgumentError);
      expect(() => SpeakerSettings.empty.withCount(5), throwsArgumentError);
    });

    test('the merges are kept when the count changes', () {
      final settings = SpeakerSettings.empty.withMerge('S2', 'S1').withCount(2);

      expect(settings.merges, <String, String>{'S2': 'S1'});
      expect(settings.speakerCount, 2);
    });
  });

  group('merges', () {
    test('a label reads as the one it was merged into', () {
      final settings = SpeakerSettings.empty.withMerge('S2', 'S1');

      expect(settings.resolve('S2'), 'S1');
      expect(settings.resolve('S1'), 'S1');
      expect(settings.resolve('S3'), 'S3');
    });

    test('merging into a label that was itself merged follows the chain', () {
      final settings = SpeakerSettings.empty
          .withMerge('S2', 'S1')
          .withMerge('S3', 'S2');

      // S3 was merged into S2, which is really S1: both read as S1, and the
      // map never needs following twice.
      expect(settings.resolve('S3'), 'S1');
      expect(settings.merges, <String, String>{'S2': 'S1', 'S3': 'S1'});
    });

    test('merging a label that others already point at repoints them', () {
      final settings = SpeakerSettings.empty
          .withMerge('S2', 'S1')
          .withMerge('S1', 'S3');

      expect(settings.resolve('S1'), 'S3');
      expect(settings.resolve('S2'), 'S3');
    });

    test('merging a label into itself changes nothing', () {
      final once = SpeakerSettings.empty.withMerge('S2', 'S1');

      expect(once.withMerge('S2', 'S1'), once);
      expect(once.withMerge('S2', 'S2'), once);
      expect(SpeakerSettings.empty.withMerge('S1', 'S1'), SpeakerSettings.empty);
    });

    test('merging back the other way does not make a loop', () {
      final settings = SpeakerSettings.empty
          .withMerge('S2', 'S1')
          .withMerge('S1', 'S2');

      // S1 is already what S2 reads as, so there is nothing left to do.
      expect(settings.resolve('S1'), 'S1');
      expect(settings.resolve('S2'), 'S1');
    });

    test('they can be forgotten', () {
      expect(
        SpeakerSettings.empty.withCount(2).withMerge('S2', 'S1').withoutMerges(),
        SpeakerSettings.empty.withCount(2),
      );
    });
  });

  group('json', () {
    test('a round trip keeps both', () {
      final settings =
          SpeakerSettings.empty.withCount(3).withMerge('S3', 'S1');

      expect(SpeakerSettings.fromJson(settings.toJson()), settings);
    });

    test('nothing chosen writes neither key', () {
      expect(SpeakerSettings.empty.toJson(), <String, Object?>{'version': 1});
    });

    test('anything unreadable is nothing chosen', () {
      expect(SpeakerSettings.fromJson(null), SpeakerSettings.empty);
      expect(SpeakerSettings.fromJson('nonsense'), SpeakerSettings.empty);
      expect(
        SpeakerSettings.fromJson(<String, Object?>{'version': 99, 'count': 2}),
        SpeakerSettings.empty,
      );
      expect(
        SpeakerSettings.fromJson(<String, Object?>{'version': 1, 'count': 9}),
        SpeakerSettings.empty,
      );
    });

    test('a chain written by another build is flattened when read', () {
      final settings = SpeakerSettings.fromJson(<String, Object?>{
        'version': 1,
        'merges': <String, Object?>{'S3': 'S2', 'S2': 'S1'},
      });

      expect(settings.resolve('S3'), 'S1');
      expect(settings.resolve('S2'), 'S1');
    });

    test('a loop written by another build is dropped, not followed', () {
      final settings = SpeakerSettings.fromJson(<String, Object?>{
        'version': 1,
        'merges': <String, Object?>{'S1': 'S2', 'S2': 'S1'},
      });

      // Two labels each merged into the other says nothing; both keep their
      // own name rather than the reader spinning.
      expect(settings.merges, isEmpty);
      expect(settings.resolve('S1'), 'S1');
    });
  });

  group('the sidecar', () {
    late InMemoryFileStore store;
    late SpeakerSettingsStore settings;

    setUp(() {
      store = InMemoryFileStore();
      settings = SpeakerSettingsStore(fileStore: store);
    });

    test('nothing saved reads as nothing chosen', () async {
      expect(await settings.load(wav), SpeakerSettings.empty);
    });

    test('saved beside the recording, and read back', () async {
      final chosen = SpeakerSettings.empty.withCount(2).withMerge('S3', 'S1');

      await settings.save(wav, chosen);

      expect(
        store.files.keys,
        contains(RecordingNaming.speakerSettingsPathOf(wav)),
      );
      expect(await settings.load(wav), chosen);
    });

    test('choosing nothing removes the file', () async {
      await settings.save(wav, SpeakerSettings.empty.withCount(2));
      await settings.save(wav, SpeakerSettings.empty);

      expect(
        store.files.keys,
        isNot(contains(RecordingNaming.speakerSettingsPathOf(wav))),
      );
    });

    test('a damaged file costs the choice, not the note', () async {
      store.put(
        RecordingNaming.speakerSettingsPathOf(wav),
        utf8.encode('{ not json'),
      );

      expect(await settings.load(wav), SpeakerSettings.empty);
    });

    test('the sidecar goes with the recording', () async {
      await settings.save(wav, SpeakerSettings.empty.withCount(2));
      store.put(wav, <int>[1, 2, 3]);

      await LibraryService.deleteFiles(store, wav);

      expect(store.files, isEmpty);
    });
  });
}
