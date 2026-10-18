import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/note_voices.dart';
import 'package:voicenotetaker_app/model/voice_vector.dart';

/// The per-note sidecar: what it keeps, and that a damaged one costs the
/// match, never the note.
void main() {
  NoteVoices sample({NoteVoiceMatch? match}) => NoteVoices(
    model: 'pyannote-segmentation-3-campplus',
    dim: 2,
    turns: <VoiceTurn>[
      VoiceTurn(
        startMs: 0,
        endMs: 5230,
        label: 'S1',
        seconds: 4.1,
        embedding: <double>[3, 4],
      ),
      VoiceTurn(startMs: 5230, endMs: 6000, label: 'S2', seconds: 0),
    ],
    match: match,
  );
  final match = NoteVoiceMatch(
    revision: 7,
    tag: NoteVoiceTag.mixed,
    turns: const <VoiceAssignment>[
      VoiceAssignment(person: 'me', sim: 0.71),
      VoiceAssignment(),
    ],
    labels: const <String, VoiceAssignment>{
      'S1': VoiceAssignment(person: 'me', sim: 0.69),
      'S2': VoiceAssignment(sim: 0.31),
    },
  );
  String text(NoteVoices voices) => jsonEncode(voices.toJson());
  Map<String, Object?> json(NoteVoices voices) =>
      jsonDecode(text(voices)) as Map<String, Object?>;

  test('embeddings are stored normalised', () {
    final embedding = sample().turns.first.embedding!;
    expect(embedding[0], closeTo(0.6, 1e-6));
    expect(embedding[1], closeTo(0.8, 1e-6));
  });

  test('embedded seconds count only turns with an embedding', () {
    expect(sample().embeddedSeconds, 4.1);
  });

  test('round-trips turns and match', () {
    final back = NoteVoices.decode(text(sample(match: match)))!;
    expect(back.model, 'pyannote-segmentation-3-campplus');
    expect(back.dim, 2);
    expect(back.turns, hasLength(2));
    final first = back.turns.first;
    expect(
      (first.startMs, first.endMs, first.label, first.seconds),
      (0, 5230, 'S1', 4.1),
    );
    expect(first.embedding, sample().turns.first.embedding);
    expect(back.turns.last.embedding, isNull);
    expect(back.match!.revision, 7);
    expect(back.match!.tag, NoteVoiceTag.mixed);
    expect(back.match!.turns, match.turns);
    expect(back.match!.labels, match.labels);
  });

  test('a note not matched yet has no match block', () {
    expect(json(sample()).containsKey('match'), isFalse);
    expect(NoteVoices.decode(text(sample()))!.match, isNull);
  });

  test('withMatch keeps the turns', () {
    final matched = sample().withMatch(match);
    expect(matched.match, same(match));
    expect(matched.turns, hasLength(2));
  });

  group('damaged', () {
    test('text that is not JSON is null, never a throw', () {
      expect(NoteVoices.decode(''), isNull);
      expect(NoteVoices.decode('{"version":1,'), isNull);
      expect(NoteVoices.decode('[]'), isNull);
    });

    void broken(String why, void Function(Map<String, Object?> json) damage) {
      test(why, () {
        final value = json(sample(match: match));
        damage(value);
        expect(NoteVoices.fromJson(value), isNull);
      });
    }

    Map<String, Object?> turn0(Map<String, Object?> json) =>
        (json['turns']! as List).first as Map<String, Object?>;

    broken('another version', (j) => j['version'] = 2);
    broken('no model', (j) => j.remove('model'));
    broken('no dim', (j) => j['dim'] = 'two');
    broken('turns not a list', (j) => j['turns'] = <String, Object?>{});
    broken('a turn not an object', (j) => (j['turns']! as List)[0] = 1);
    broken('a turn ending before it starts', (j) => turn0(j)['end'] = -1);
    broken('a negative start', (j) => turn0(j)['start'] = -5);
    broken('no label', (j) => turn0(j).remove('label'));
    broken('seconds not a number', (j) => turn0(j)['seconds'] = '4');
    broken('an embedding that is not base64', (j) => turn0(j)['emb'] = '!');
    broken(
      'an embedding of the wrong size',
      (j) => turn0(j)['emb'] = VoiceVector.encode(<double>[1, 0, 0]),
    );

    test('a damaged match alone is dropped; the turns survive', () {
      for (final damage in <void Function(Map<String, Object?>)>[
        (m) => m['tag'] = 'hidden',
        (m) => m['revision'] = 'seven',
        (m) => (m['turns']! as List).removeLast(),
        (m) => (m['labels']! as Map)['S1'] = <String, Object?>{'person': 3},
        (m) => m['labels'] = <Object?>[],
      ]) {
        final value = json(sample(match: match));
        damage(value['match']! as Map<String, Object?>);
        final back = NoteVoices.fromJson(value)!;
        expect(back.turns, hasLength(2));
        expect(back.match, isNull);
      }
    });
  });
}
