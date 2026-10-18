import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/voiceprint.dart';

/// The voiceprint store: who is known, how their centroid is made, what is
/// kept, and what survives a restart.
void main() {
  const model = 'pyannote-segmentation-3-campplus';
  final t0 = DateTime.utc(2026, 10, 18, 9);
  DateTime at(int minutes) => t0.add(Duration(minutes: minutes));
  Voiceprints empty() => Voiceprints(revision: 0, model: model, dim: 4);
  const e1 = <double>[1, 0, 0, 0];
  const e2 = <double>[0, 1, 0, 0];
  const e3 = <double>[0, 0, 1, 0];

  Voiceprints tag(
    Voiceprints prints,
    String person,
    String note,
    String label, {
    List<double> embedding = e2,
    double seconds = 10,
    DateTime? time,
    String? name,
  }) => prints.withNoteSample(
    person: person,
    name: name,
    note: note,
    label: label,
    seconds: seconds,
    embedding: embedding,
    at: time ?? t0,
  );

  group('enrolment', () {
    test('an empty store has no owner', () {
      expect(empty().isEnrolled, isFalse);
      expect(empty().people, isEmpty);
    });

    test('creates the owner, who is "me", has no name and is marked owner', () {
      final prints = empty().withEnrolment(
        embedding: e1,
        seconds: 58.2,
        at: t0,
      );
      final owner = prints.owner!;
      expect(prints.isEnrolled, isTrue);
      expect(owner.id, Voiceprints.ownerId);
      expect(owner.owner, isTrue);
      expect(owner.name, isNull);
      expect(owner.seconds, 58.2);
      expect(owner.centroid, e1);
      expect(prints.revision, 1);
    });

    test('recording again replaces the enrolment sample, keeps the tags', () {
      final prints = tag(
        empty().withEnrolment(embedding: e1, seconds: 60, at: t0),
        Voiceprints.ownerId,
        'n1',
        'S1',
      ).withEnrolment(embedding: e3, seconds: 50, at: at(5));
      final samples = prints.owner!.samples;
      expect(samples, hasLength(2));
      expect(
        samples
            .where((s) => s.source == VoiceSampleSource.enrolment)
            .single
            .embedding,
        e3,
      );
    });
  });

  group('centroid', () {
    test('is normalise(sum of seconds x sample)', () {
      final prints = tag(
        empty().withEnrolment(embedding: e1, seconds: 30, at: t0),
        Voiceprints.ownerId,
        'n1',
        'S1',
        embedding: e2,
        seconds: 10,
      );
      final owner = prints.owner!;
      expect(owner.seconds, 40);
      expect(owner.centroid[0], closeTo(30 / math.sqrt(1000), 1e-6));
      expect(owner.centroid[1], closeTo(10 / math.sqrt(1000), 1e-6));
    });

    test('samples are stored normalised, so loudness does not weigh', () {
      final prints = empty().withEnrolment(
        embedding: <double>[3, 4, 0, 0],
        seconds: 1,
        at: t0,
      );
      expect(prints.owner!.samples.single.embedding[0], closeTo(0.6, 1e-6));
      expect(prints.owner!.samples.single.embedding[1], closeTo(0.8, 1e-6));
    });
  });

  group('tags', () {
    test('a new person is created with their name', () {
      final prints = tag(empty(), 'p-1', 'n1', 'S2', name: ' Priya ');
      final priya = prints.person('p-1')!;
      expect(priya.name, 'Priya');
      expect(priya.owner, isFalse);
      expect(prints.owner, isNull);
      expect(prints.isEnrolled, isFalse);
    });

    test('"It\'s me" before enrolment makes an owner from the tag alone, '
        'who is NOT enrolled until the guided recording', () {
      var prints = tag(empty(), Voiceprints.ownerId, 'n1', 'S1', name: 'x');
      expect(prints.owner!.name, isNull);
      expect(prints.owner!.owner, isTrue);
      expect(prints.isEnrolled, isFalse);
      prints = prints.withEnrolment(embedding: e1, seconds: 60, at: t0);
      expect(prints.isEnrolled, isTrue);
      expect(prints.owner!.samples, hasLength(2));
    });

    test('tagging the same note and label again replaces it, even as '
        'someone else; a person left with nothing goes', () {
      var prints = tag(empty(), 'p-1', 'n1', 'S2', name: 'Priya');
      prints = tag(prints, 'p-1', 'n1', 'S2', embedding: e3);
      expect(prints.person('p-1')!.samples, hasLength(1));
      expect(prints.person('p-1')!.centroid, e3);

      prints = tag(prints, 'p-2', 'n1', 'S2', name: 'Rahul');
      expect(prints.person('p-1'), isNull);
      expect(prints.person('p-2')!.samples.single.isFrom('n1', 'S2'), isTrue);
    });

    test('untag removes the sample keyed by note and label', () {
      var prints = tag(empty(), 'p-1', 'n1', 'S2', name: 'Priya');
      prints = tag(prints, 'p-1', 'n2', 'S1', embedding: e3);
      prints = prints.withoutNoteSample(note: 'n1', label: 'S2', at: at(1));
      expect(prints.person('p-1')!.samples.single.isFrom('n2', 'S1'), isTrue);
      expect(prints.person('p-1')!.centroid, e3);
    });

    test(
      'untagging what was never tagged changes nothing, revision included',
      () {
        final prints = tag(empty(), 'p-1', 'n1', 'S2');
        final same = prints.withoutNoteSample(note: 'n9', label: 'S2', at: t0);
        expect(identical(same, prints), isTrue);
      },
    );

    test('untag never removes the enrolment sample', () {
      final prints = empty()
          .withEnrolment(embedding: e1, seconds: 60, at: t0)
          .withoutNoteSample(note: 'n1', label: 'S1', at: t0);
      expect(prints.owner!.samples, hasLength(1));
    });

    test('an embedding of the wrong size is refused', () {
      expect(
        () => tag(empty(), 'p-1', 'n1', 'S1', embedding: <double>[1, 0]),
        throwsArgumentError,
      );
    });
  });

  group('cap', () {
    test('over ${Voiceprints.maxSamples} the oldest NOTE sample goes; the '
        'enrolment, older still, stays', () {
      var prints = empty().withEnrolment(embedding: e1, seconds: 60, at: t0);
      for (var i = 1; i < Voiceprints.maxSamples; i++) {
        prints = tag(prints, Voiceprints.ownerId, 'n$i', 'S1', time: at(i));
      }
      expect(prints.owner!.samples, hasLength(Voiceprints.maxSamples));
      prints = tag(prints, Voiceprints.ownerId, 'n40', 'S1', time: at(40));
      final samples = prints.owner!.samples;
      expect(samples, hasLength(Voiceprints.maxSamples));
      expect(
        samples.where((s) => s.source == VoiceSampleSource.enrolment),
        hasLength(1),
      );
      expect(samples.any((s) => s.isFrom('n1', 'S1')), isFalse);
      expect(samples.any((s) => s.isFrom('n2', 'S1')), isTrue);
      expect(samples.any((s) => s.isFrom('n40', 'S1')), isTrue);
    });
  });

  group('people', () {
    test('rename, and a blank name clears it', () {
      var prints = tag(empty(), 'p-1', 'n1', 'S2', name: 'Priya');
      prints = prints.withName('p-1', 'Priya S', at(1));
      expect(prints.person('p-1')!.name, 'Priya S');
      expect(prints.person('p-1')!.updatedAt, at(1));
      prints = prints.withName('p-1', '  ', at(2));
      expect(prints.person('p-1')!.name, isNull);
    });

    test('forget removes the person and all their samples', () {
      final prints = tag(
        empty().withEnrolment(embedding: e1, seconds: 60, at: t0),
        'p-1',
        'n1',
        'S2',
      ).withoutPerson(Voiceprints.ownerId);
      expect(prints.isEnrolled, isFalse);
      expect(prints.owner, isNull);
      expect(prints.person('p-1'), isNotNull);
    });

    test('every change moves the revision on', () {
      var prints = empty();
      final revisions = <int>[prints.revision];
      prints = prints.withEnrolment(embedding: e1, seconds: 60, at: t0);
      revisions.add(prints.revision);
      prints = tag(prints, 'p-1', 'n1', 'S2', name: 'Priya');
      revisions.add(prints.revision);
      prints = prints.withName('p-1', 'P', t0);
      revisions.add(prints.revision);
      prints = prints.withoutNoteSample(note: 'n1', label: 'S2', at: t0);
      revisions.add(prints.revision);
      prints = prints.withoutPerson(Voiceprints.ownerId);
      revisions.add(prints.revision);
      expect(revisions, <int>[0, 1, 2, 3, 4, 5]);
    });
  });

  group('json', () {
    Voiceprints read(Object? json, {String id = model, int dim = 4}) =>
        Voiceprints.fromJson(json, model: id, dim: dim);
    Object? roundTrip(Voiceprints prints) =>
        jsonDecode(jsonEncode(prints.toJson()));

    test('round-trips people, samples and embeddings exactly', () {
      final prints = tag(
        tag(
          empty().withEnrolment(
            embedding: <double>[0.1, 0.2, 0.3, 0.4],
            seconds: 58.2,
            at: t0,
          ),
          Voiceprints.ownerId,
          'voicenote-20261018-101500',
          'S1',
          seconds: 34,
          time: at(3),
        ),
        'p-20261018T1015',
        'voicenote-20261018-101500',
        'S2',
        name: 'Priya',
        embedding: e3,
        time: at(4),
      );
      final back = read(roundTrip(prints));
      expect(back.revision, prints.revision);
      expect(back.people.map((p) => p.id), prints.people.map((p) => p.id));
      for (final person in prints.people) {
        final other = back.person(person.id)!;
        expect(other.name, person.name);
        expect(other.owner, person.owner);
        expect(other.createdAt, person.createdAt);
        expect(other.updatedAt, person.updatedAt);
        expect(other.seconds, person.seconds);
        expect(other.centroid, person.centroid);
        for (var i = 0; i < person.samples.length; i++) {
          final a = person.samples[i];
          final b = other.samples[i];
          expect(b.source, a.source);
          expect(b.note, a.note);
          expect(b.label, a.label);
          expect(b.at, a.at);
          expect(b.seconds, a.seconds);
          expect(b.embedding, a.embedding);
        }
      }
    });

    test('the file carries version, model, dim and each centroid', () {
      final json = empty()
          .withEnrolment(embedding: e1, seconds: 60, at: t0)
          .toJson();
      expect(json['version'], 1);
      expect(json['model'], model);
      expect(json['dim'], 4);
      final person = (json['people']! as List).single as Map;
      expect(person['centroid'], isA<String>());
    });

    test('a store for another model reads as empty, its revision moved on', () {
      final old = roundTrip(
        empty().withEnrolment(embedding: e1, seconds: 60, at: t0),
      );
      final other = read(old, id: 'some-other-model');
      expect(other.people, isEmpty);
      expect(other.model, 'some-other-model');
      expect(other.revision, 2);
      expect(read(old, dim: 192).people, isEmpty);
    });

    test('anything unreadable is an empty store, never a throw', () {
      for (final json in <Object?>[
        null,
        'x',
        <String, Object?>{'version': 2},
        <String, Object?>{'version': 1, 'model': model, 'dim': 4},
      ]) {
        final prints = read(json);
        expect(prints.people, isEmpty);
        expect(prints.model, model);
      }
    });

    test('a damaged sample is left out; a person left with none goes', () {
      final json =
          roundTrip(
                tag(
                  tag(
                    empty().withEnrolment(embedding: e1, seconds: 60, at: t0),
                    Voiceprints.ownerId,
                    'n1',
                    'S1',
                  ),
                  'p-1',
                  'n1',
                  'S2',
                ),
              )!
              as Map<String, Object?>;
      final people = json['people']! as List;
      final owner = people[0] as Map<String, Object?>;
      ((owner['samples']! as List)[1] as Map)['embedding'] = 'broken';
      final priya = people[1] as Map<String, Object?>;
      ((priya['samples']! as List)[0] as Map)['seconds'] = -1;
      final back = read(json);
      expect(back.owner!.samples, hasLength(1));
      expect(back.person('p-1'), isNull);
    });
  });
}
