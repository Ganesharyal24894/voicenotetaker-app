import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/diarization.dart';
import 'package:voicenotetaker_app/model/note_voices.dart';
import 'package:voicenotetaker_app/model/voiceprint.dart';
import 'package:voicenotetaker_app/services/library_service.dart';
import 'package:voicenotetaker_app/services/transcription/speaker_settings_store.dart';
import 'package:voicenotetaker_app/services/voices/note_voices_store.dart';
import 'package:voicenotetaker_app/services/voices/voice_library.dart';
import 'package:voicenotetaker_app/services/voices/voiceprint_store.dart';

import '../view/harness.dart' show MemoryFileStore;

const String rec = '/documents/recordings';
const String voicesDir = '/support/voices';
const DiarizationModel pack = DiarizationModels.pyannoteCamPlus;

/// A unit vector along [axis].
List<double> along(int axis) =>
    List<double>.generate(pack.embeddingDim, (i) => i == axis ? 1.0 : 0.0);

NoteVoices voicesOf(List<(String label, int axis)> turns) => NoteVoices(
  model: pack.id,
  dim: pack.embeddingDim,
  turns: <VoiceTurn>[
    for (var i = 0; i < turns.length; i++)
      VoiceTurn(
        startMs: i * 8000,
        endMs: (i + 1) * 8000,
        label: turns[i].$1,
        seconds: 8,
        embedding: along(turns[i].$2),
      ),
  ],
);

/// The voice library over an in-memory disk: what it writes beside each
/// note, and how every note follows the known voices.
void main() {
  late MemoryFileStore disk;
  late VoiceLibrary library;
  late NoteVoicesStore notes;
  late SpeakerSettingsStore settings;
  late int changes;

  String note(String stamp) => '$rec/voicenote-$stamp.wav';
  final tv = note('20261018-090000');
  final mine = note('20261018-100000');

  VoiceLibrary open() => VoiceLibrary(
    fileStore: disk,
    recordingsDirectory: rec,
    store: VoiceprintStore(fileStore: disk, directory: voicesDir),
    clock: () => DateTime(2026, 10, 18, 10, 15),
  );

  Future<void> enrolOwner() async {
    await library.enrol(along(0), 58);
    await library.rematchAll();
  }

  setUp(() {
    disk = MemoryFileStore();
    notes = NoteVoicesStore(fileStore: disk);
    settings = SpeakerSettingsStore(fileStore: disk);
    library = open();
    changes = 0;
    library.changes.listen((_) => changes++);
  });

  tearDown(() => library.dispose());

  bool marked(String path) =>
      disk.files.containsKey(RecordingNaming.backgroundPathOf(path));

  group('before enrolment', () {
    test('voices are saved and matched, and nothing is hidden', () async {
      await library.noteHeard(tv, voicesOf(<(String, int)>[('S1', 5)]));

      final saved = await notes.load(tv);
      expect(saved!.turns.single.embedding, isNotNull);
      expect(saved.match!.tag, NoteVoiceTag.unknown);
      expect(marked(tv), isFalse);
    });
  });

  group('the background marker', () {
    setUp(() async {
      await library.noteHeard(tv, voicesOf(<(String, int)>[('S1', 5)]));
      await library.noteHeard(mine, voicesOf(<(String, int)>[('S1', 0)]));
    });

    test('enrolling marks the note with nobody known, and only that one',
        () async {
      await enrolOwner();

      expect(marked(tv), isTrue);
      expect(marked(mine), isFalse);
      expect((await notes.load(mine))!.match!.tag, NoteVoiceTag.own);
      expect(await library.backgroundCount(), 1);
      expect(changes, greaterThan(0));
    });

    test('a note heard after enrolment is marked as it is saved', () async {
      await enrolOwner();
      final later = note('20261018-110000');

      await library.noteHeard(later, voicesOf(<(String, int)>[('S1', 7)]));

      expect(marked(later), isTrue);
    });

    test('rematchAll with staleOnly passes over notes already up to date',
        () async {
      await enrolOwner();
      final before = (await notes.load(tv))!.match!.revision;
      // Changed behind the library's back: a stale-only pass must not see it.
      await disk.delete(RecordingNaming.backgroundPathOf(tv));

      await library.rematchAll(staleOnly: true);
      expect(marked(tv), isFalse);
      expect(library.prints.revision, before);

      await library.rematchAll();
      expect(marked(tv), isTrue);
    });

    test('progress counts every note with voices', () async {
      final seen = <(int, int)>[];

      final count = await library.rematchAll(
        onProgress: (done, total) => seen.add((done, total)),
      );

      expect(count, 2);
      expect(seen.last, (2, 2));
    });

    test('"keep" clears the marker, and taking it back sets it again',
        () async {
      await enrolOwner();

      await library.keep(tv, true);
      expect(marked(tv), isFalse);
      expect((await settings.load(tv)).keep, isTrue);

      await library.keep(tv, false);
      expect(marked(tv), isTrue);
    });
  });

  group('tagging', () {
    setUp(() async {
      await library.noteHeard(tv, voicesOf(<(String, int)>[('S1', 5)]));
      await enrolOwner();
    });

    test('"It\'s me" pins the label, learns the voice and unhides the note',
        () async {
      final id = await library.tag(tv, 'S1', person: Voiceprints.ownerId);

      expect(id, Voiceprints.ownerId);
      expect(marked(tv), isFalse);
      expect((await settings.load(tv)).people, {'S1': Voiceprints.ownerId});
      final owner = library.prints.owner!;
      expect(owner.samples, hasLength(2));
      expect(owner.samples.last.note, 'voicenote-20261018-090000');
    });

    test('untag takes the sample and the pin back, and the marker returns',
        () async {
      await library.tag(tv, 'S1', person: Voiceprints.ownerId);

      await library.untag(tv, 'S1');

      expect(library.prints.owner!.samples, hasLength(1));
      expect((await settings.load(tv)).people, isEmpty);
      expect(marked(tv), isTrue);
    });

    test('someone new is created with their name, and found in other notes',
        () async {
      final other = note('20261018-120000');
      await library.noteHeard(other, voicesOf(<(String, int)>[('S1', 5)]));
      expect(marked(other), isTrue);

      final id = await library.tag(tv, 'S1', name: 'Priya');
      await library.rematchAll();

      expect(id, 'p-20261018T101500');
      expect(library.prints.person(id!)!.name, 'Priya');
      expect(marked(tv), isFalse);
      expect(marked(other), isFalse);
      expect((await notes.load(other))!.match!.labels['S1']!.person, id);
    });

    test('forgetting a person puts their notes back in the background',
        () async {
      final id = await library.tag(tv, 'S1', name: 'Priya');

      await library.forget(id!);
      await library.rematchAll();

      expect(library.prints.person(id), isNull);
      expect(marked(tv), isTrue);
    });

    test('renaming changes the name and nothing else', () async {
      final id = await library.tag(tv, 'S1', name: 'Priya');

      await library.rename(id!, 'Priya S');

      expect(library.prints.person(id)!.name, 'Priya S');
      expect(library.prints.person(id)!.samples, hasLength(1));
    });

    test('a label with no stored voice teaches nothing', () async {
      expect(await library.tag(tv, 'S9', name: 'Nobody'), isNull);
      expect(await library.tag(note('20261018-130000'), 'S1'), isNull);
      expect(library.prints.people, hasLength(1));
    });

    test('a merge is matched again on asking: the pooled label is You',
        () async {
      final two = note('20261018-150000');
      await library.noteHeard(
        two,
        voicesOf(<(String, int)>[('S1', 0), ('S2', 0), ('S3', 5)]),
      );
      await settings.save(
        two,
        (await settings.load(two)).withMerge('S2', 'S1'),
      );

      await library.rematch(two);

      final labels = (await notes.load(two))!.match!.labels;
      expect(labels.keys, unorderedEquals(<String>['S1', 'S3']));
      expect(labels['S1']!.person, Voiceprints.ownerId);
    });

    test('merged labels are tagged together', () async {
      final two = note('20261018-140000');
      await library.noteHeard(
        two,
        voicesOf(<(String, int)>[('S1', 5), ('S2', 6)]),
      );
      await settings.save(
        two,
        (await settings.load(two)).withMerge('S2', 'S1'),
      );

      await library.tag(two, 'S1', name: 'Priya');

      final sample = library.prints.people.last.samples.single;
      expect(sample.seconds, 16);
    });
  });

  group('the voiceprint file', () {
    test('is written whole, through a temporary file, and read back',
        () async {
      await library.enrol(along(0), 58);

      expect(disk.files.keys, contains('$voicesDir/voiceprints.json'));
      expect(disk.files.keys, isNot(contains('$voicesDir/voiceprints.json.tmp')));
      final again = open();
      expect((await again.load()).isEnrolled, isTrue);
      await again.dispose();
    });

    test('a file from another model reads as nobody enrolled', () async {
      await library.enrol(along(0), 58);
      final path = '$voicesDir/voiceprints.json';
      final json = jsonDecode(utf8.decode(disk.files[path]!)) as Map;
      json['model'] = 'another-network';
      disk.files[path] = utf8.encode(jsonEncode(json));

      final again = open();
      expect((await again.load()).people, isEmpty);
      await again.dispose();
    });
  });
}
