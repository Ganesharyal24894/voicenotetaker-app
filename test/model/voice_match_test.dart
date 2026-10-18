import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/note_voices.dart';
import 'package:voicenotetaker_app/model/voice_match.dart';
import 'package:voicenotetaker_app/model/voiceprint.dart';

/// Every rule of the matcher. The voices are built on axes - the owner on the
/// first, Priya on the second, Rahul on the third, nobody on the fourth - so a
/// turn's cosine to each person is exactly the number written in the test.
void main() {
  const model = 'pyannote-segmentation-3-campplus';
  const me = Voiceprints.ownerId;
  const priya = 'p-priya';
  const rahul = 'p-rahul';
  final t0 = DateTime.utc(2026, 10, 18);

  /// A voice [o] close to the owner, [p] to Priya, [r] to Rahul.
  List<double> v(double o, [double p = 0, double r = 0]) => <double>[
    o,
    p,
    r,
    math.sqrt(1 - o * o - p * p - r * r),
  ];

  VoiceTurn turn(String label, List<double>? voice, {double seconds = 5}) =>
      VoiceTurn(
        startMs: 0,
        endMs: 1000,
        label: label,
        seconds: seconds,
        embedding: voice,
      );

  NoteVoices note(List<VoiceTurn> turns, {String id = model}) =>
      NoteVoices(model: id, dim: 4, turns: turns);

  Voiceprints prints({
    bool owner = true,
    bool withPriya = false,
    bool withRahul = false,
  }) {
    var out = Voiceprints(revision: 0, model: model, dim: 4);
    if (owner) {
      out = out.withEnrolment(
        embedding: <double>[1, 0, 0, 0],
        seconds: 60,
        at: t0,
      );
    }
    if (withPriya) {
      out = out.withNoteSample(
        person: priya,
        name: 'Priya',
        note: 'n0',
        label: 'S2',
        seconds: 20,
        embedding: <double>[0, 1, 0, 0],
        at: t0,
      );
    }
    if (withRahul) {
      out = out.withNoteSample(
        person: rahul,
        name: 'Rahul',
        note: 'n0',
        label: 'S3',
        seconds: 20,
        embedding: <double>[0, 0, 1, 0],
        at: t0,
      );
    }
    return out;
  }

  /// One label of [voice], with enough speech to be evidence.
  NoteVoices one(List<double> voice) =>
      note(<VoiceTurn>[turn('S1', voice), turn('S1', voice)]);

  group('labels', () {
    test('the owner close enough is You', () {
      final result = VoiceMatch.match(one(v(0.63)), prints());
      expect(result.labels['S1']!.person, me);
      expect(result.labels['S1']!.sim, closeTo(0.63, 1e-5));
    });

    test('KEEP WHEN UNSURE: just over ownerKeep, far under ownerStrong, is '
        'still You', () {
      expect(VoiceMatch.ownerKeep, lessThan(VoiceMatch.ownerStrong));
      final result = VoiceMatch.match(one(v(0.305)), prints());
      expect(result.labels['S1']!.person, me);
      expect(result.tag, NoteVoiceTag.own);
    });

    test('just under ownerKeep, and nobody else, is Other', () {
      final result = VoiceMatch.match(one(v(0.295)), prints());
      expect(result.labels['S1']!.person, isNull);
      expect(result.labels['S1']!.sim, closeTo(0.295, 1e-5));
    });

    test('the score is the SECONDS-weighted mean of the label\'s turns', () {
      final mostlyOwner = note(<VoiceTurn>[
        turn('S1', v(1), seconds: 9),
        turn('S1', v(0), seconds: 1),
      ]);
      final mostlyNot = note(<VoiceTurn>[
        turn('S1', v(1), seconds: 1),
        turn('S1', v(0), seconds: 9),
      ]);
      expect(VoiceMatch.match(mostlyOwner, prints()).labels['S1']!.person, me);
      expect(
        VoiceMatch.match(mostlyNot, prints()).labels['S1']!.person,
        isNull,
      );
    });

    test('another person close enough, and clearly ahead, is them', () {
      final result = VoiceMatch.match(
        one(v(0.1, 0.7)),
        prints(withPriya: true),
      );
      expect(result.labels['S1']!.person, priya);
      expect(result.labels['S1']!.sim, closeTo(0.7, 1e-5));
    });

    test('the owner keeps a label unless someone beats them by the margin', () {
      final close = VoiceMatch.match(
        one(v(0.58, 0.62)),
        prints(withPriya: true),
      );
      expect(close.labels['S1']!.person, me);
      final clear = VoiceMatch.match(
        one(v(0.58, 0.64)),
        prints(withPriya: true),
      );
      expect(clear.labels['S1']!.person, priya);
    });

    test('another person under personMatch is Other', () {
      final result = VoiceMatch.match(
        one(v(0.1, 0.5)),
        prints(withPriya: true),
      );
      expect(result.labels['S1']!.person, isNull);
      expect(result.labels['S1']!.sim, closeTo(0.5, 1e-5));
    });

    test('two people too close to call is Other', () {
      final result = VoiceMatch.match(
        one(v(0.1, 0.6, 0.57)),
        prints(withPriya: true, withRahul: true),
      );
      expect(result.labels['S1']!.person, isNull);
    });

    test('other people are matched with no owner enrolled', () {
      final result = VoiceMatch.match(
        one(v(0, 0.7)),
        prints(owner: false, withPriya: true),
      );
      expect(result.labels['S1']!.person, priya);
    });

    test('a label with no embedded turns is Other, with nothing to score', () {
      final result = VoiceMatch.match(
        note(<VoiceTurn>[turn('S1', v(1)), turn('S2', null)]),
        prints(),
      );
      expect(result.labels['S2'], const VoiceAssignment());
    });
  });

  group('pins and merges', () {
    test('a pinned label is not scored', () {
      final result = VoiceMatch.match(
        one(v(0.9)),
        prints(withPriya: true),
        pins: const <String, String>{'S1': priya},
      );
      expect(result.labels['S1']!.person, priya);
      expect(result.labels['S1']!.sim, closeTo(0, 1e-5));
    });

    test('a pin naming a forgotten voice is ignored', () {
      final result = VoiceMatch.match(
        one(v(0.9)),
        prints(),
        pins: const <String, String>{'S1': 'p-gone'},
      );
      expect(result.labels['S1']!.person, me);
    });

    test('merged labels pool their turns', () {
      final voices = note(<VoiceTurn>[
        turn('S1', v(0.9), seconds: 6),
        turn('S2', v(0), seconds: 2),
      ]);
      final apart = VoiceMatch.match(voices, prints());
      expect(apart.labels.keys, <String>['S1', 'S2']);
      expect(apart.labels['S2']!.person, isNull);
      expect(apart.tag, NoteVoiceTag.mixed);

      String merged(String label) => label == 'S2' ? 'S1' : label;
      final together = VoiceMatch.match(voices, prints(), resolve: merged);
      expect(together.labels.keys, <String>['S1']);
      expect(together.labels['S1']!.person, me);
      expect(together.turns.map((t) => t.person), <String?>[me, me]);
      expect(together.tag, NoteVoiceTag.own);
    });

    test('a pin on a label merged away still holds for the merged label', () {
      final result = VoiceMatch.match(
        note(<VoiceTurn>[turn('S1', v(0.9)), turn('S2', v(0.9))]),
        prints(withPriya: true),
        resolve: (label) => label == 'S2' ? 'S1' : label,
        pins: const <String, String>{'S2': priya},
      );
      expect(result.labels['S1']!.person, priya);
    });
  });

  group('turns', () {
    test('a turn shows its label\'s person, scored against them', () {
      final result = VoiceMatch.match(
        note(<VoiceTurn>[turn('S1', v(0.1, 0.8)), turn('S1', v(0.1, 0.6))]),
        prints(withPriya: true),
      );
      expect(result.turns.map((t) => t.person), <String?>[priya, priya]);
      expect(result.turns[1].sim, closeTo(0.6, 1e-5));
    });

    test('a turn at ownerStrong shows as You inside an Other label', () {
      final result = VoiceMatch.match(
        note(<VoiceTurn>[
          turn('S1', v(0.6), seconds: 2),
          turn('S1', v(0), seconds: 8),
        ]),
        prints(),
      );
      expect(result.labels['S1']!.person, isNull);
      expect(result.turns[0].person, me);
      expect(result.turns[0].sim, closeTo(0.6, 1e-5));
      expect(result.turns[1].person, isNull);
    });

    test('an Other turn carries how close the nearest voice came', () {
      final result = VoiceMatch.match(
        note(<VoiceTurn>[turn('S1', v(0.1, 0.2)), turn('S1', v(0.1, 0.2))]),
        prints(withPriya: true),
      );
      expect(result.turns[0].person, isNull);
      expect(result.turns[0].sim, closeTo(0.2, 1e-5));
    });

    test('a turn without an embedding shows its label\'s person, unscored', () {
      final result = VoiceMatch.match(
        note(<VoiceTurn>[turn('S1', v(0.9)), turn('S1', null)]),
        prints(),
      );
      expect(result.turns[1], const VoiceAssignment(person: me));
    });

    test('the match records the store revision it was made against', () {
      final store = prints(withPriya: true);
      expect(VoiceMatch.match(one(v(0.9)), store).revision, store.revision);
    });
  });

  group('note tag', () {
    NoteVoices stranger({double seconds = 5}) => note(<VoiceTurn>[
      turn('S1', v(0.1), seconds: seconds),
      turn('S2', v(0.05), seconds: seconds),
    ]);

    test('only strangers, with enough speech, is background', () {
      final result = VoiceMatch.match(stranger(), prints());
      expect(result.tag, NoteVoiceTag.background);
      expect(result.labels.values.every((l) => l.person == null), isTrue);
    });

    test('NEVER background without an enrolled owner', () {
      final result = VoiceMatch.match(
        stranger(seconds: 60),
        prints(owner: false, withPriya: true),
      );
      expect(result.tag, NoteVoiceTag.unknown);
    });

    test('NEVER background with an owner known only from "It\'s me" tags', () {
      final tagged = Voiceprints(revision: 0, model: model, dim: 4)
          .withNoteSample(
            person: me,
            note: 'n0',
            label: 'S1',
            seconds: 30,
            embedding: <double>[1, 0, 0, 0],
            at: t0,
          );
      expect(tagged.owner, isNotNull);
      expect(tagged.isEnrolled, isFalse);
      expect(
        VoiceMatch.match(stranger(seconds: 60), tagged).tag,
        NoteVoiceTag.unknown,
      );
      // Their voice is still recognised as "You"; only the hiding waits.
      final theirs = VoiceMatch.match(one(v(0.8)), tagged);
      expect(theirs.labels['S1']!.person, me);
      expect(theirs.tag, NoteVoiceTag.unknown);
      // Once enrolled, the same note can be background.
      final enrolled = tagged.withEnrolment(
        embedding: <double>[1, 0, 0, 0],
        seconds: 60,
        at: t0,
      );
      expect(
        VoiceMatch.match(stranger(seconds: 60), enrolled).tag,
        NoteVoiceTag.background,
      );
    });

    test('NEVER background on too little evidence', () {
      // 2 x 2.9 s = 5.8 s embedded, under the 6 s minimum.
      expect(VoiceMatch.minEvidence, const Duration(seconds: 6));
      final result = VoiceMatch.match(stranger(seconds: 2.9), prints());
      expect(result.tag, NoteVoiceTag.unknown);
      expect(
        VoiceMatch.match(stranger(seconds: 3), prints()).tag,
        NoteVoiceTag.background,
      );
    });

    test('speech without an embedding is not evidence', () {
      final result = VoiceMatch.match(
        note(<VoiceTurn>[
          turn('S1', v(0.1), seconds: 4),
          turn('S1', null, seconds: 40),
        ]),
        prints(),
      );
      expect(result.tag, NoteVoiceTag.unknown);
    });

    test('no voices at all is unknown', () {
      expect(
        VoiceMatch.match(note(const <VoiceTurn>[]), prints()).tag,
        NoteVoiceTag.unknown,
      );
      expect(
        VoiceMatch.match(note(<VoiceTurn>[turn('S1', null)]), prints()).tag,
        NoteVoiceTag.unknown,
      );
    });

    test('voices from another model are not compared at all', () {
      final result = VoiceMatch.match(
        one(v(0.9)),
        prints(),
        pins: const {'S1': me},
      );
      expect(result.tag, NoteVoiceTag.own);
      final foreign = VoiceMatch.match(
        note(<VoiceTurn>[turn('S1', v(0.9)), turn('S1', v(0.9))], id: 'x'),
        prints(),
      );
      expect(foreign.tag, NoteVoiceTag.unknown);
      expect(foreign.labels['S1']!.person, isNull);
    });

    test('every label You is own', () {
      final result = VoiceMatch.match(
        note(<VoiceTurn>[turn('S1', v(0.7)), turn('S2', v(0.4))]),
        prints(),
      );
      expect(result.tag, NoteVoiceTag.own);
    });

    test('the owner and a stranger is mixed', () {
      final result = VoiceMatch.match(
        note(<VoiceTurn>[turn('S1', v(0.7)), turn('S2', v(0.1))]),
        prints(),
      );
      expect(result.tag, NoteVoiceTag.mixed);
    });

    test('someone known without the owner is mixed, not background', () {
      final result = VoiceMatch.match(
        note(<VoiceTurn>[turn('S1', v(0, 0.8)), turn('S2', v(0.1))]),
        prints(withPriya: true),
      );
      expect(result.tag, NoteVoiceTag.mixed);
    });

    test('one strong owner turn keeps the note out of background', () {
      final result = VoiceMatch.match(
        note(<VoiceTurn>[
          turn('S1', v(0.56), seconds: 2),
          turn('S1', v(0), seconds: 20),
        ]),
        prints(),
      );
      expect(result.labels['S1']!.person, isNull);
      expect(result.tag, NoteVoiceTag.mixed);
    });

    test('the user saying keep keeps it', () {
      final result = VoiceMatch.match(stranger(), prints(), keep: true);
      expect(result.tag, NoteVoiceTag.mixed);
    });

    test('a label pinned to someone keeps it', () {
      final result = VoiceMatch.match(
        stranger(),
        prints(withPriya: true),
        pins: const <String, String>{'S2': priya},
      );
      expect(result.tag, NoteVoiceTag.mixed);
    });
  });
}
