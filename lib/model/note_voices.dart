/// The voices heard in ONE note, and who they were matched to.
///
/// Pure data: JSON in and out, no I/O. Saved beside the recording as
/// `voicenote-X.voices.json` by the transcription job, and it outlives the
/// audio: once the WAV is swept away this is all that is left to match the
/// note against a voice the owner names later.
///
/// TWO HALVES THAT AGE DIFFERENTLY. [NoteVoices.turns] is what the audio said
/// and never changes after the job. [NoteVoices.match] is a verdict against
/// one revision of the voiceprint store and is rewritten whenever the store
/// moves on - re-matching never needs the audio or the diarizer again.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'voice_vector.dart';

/// One cleaned turn of the note.
class VoiceTurn {
  VoiceTurn({
    required this.startMs,
    required this.endMs,
    required this.label,
    required this.seconds,
    List<double>? embedding,
  }) : embedding = embedding == null ? null : VoiceVector.normalise(embedding);

  final int startMs;
  final int endMs;

  /// The label the diarizer's cleaned turns gave it (`S1`, `S2`, ...), before
  /// any merge the user made - merges are applied when matching.
  final String label;

  /// Seconds of speech [embedding] was computed from; its weight in the
  /// label's mean.
  final double seconds;

  /// L2-normalised; null when the turn had too little clean speech, or the
  /// note had already reached its cap of embedded turns.
  final Float32List? embedding;

  Map<String, Object?> toJson() => <String, Object?>{
    'start': startMs,
    'end': endMs,
    'label': label,
    'seconds': seconds,
    'emb': embedding == null ? null : VoiceVector.encode(embedding!),
  };
}

/// How a note reads against the known voices.
///
/// Only [background] is hidden; everything else is shown.
enum NoteVoiceTag {
  /// Nothing to go on: no owner enrolled, no voices, or too little speech.
  unknown,

  /// Every voice is the owner's.
  own,

  /// The owner, or someone they know, and others.
  mixed,

  /// Nobody the owner knows, and not even one turn that sounds like them.
  background,
}

/// Who one turn or label was matched to.
class VoiceAssignment {
  const VoiceAssignment({this.person, this.sim});

  /// A person's id from the voiceprint store; null is "Other".
  final String? person;

  /// Cosine to [person]'s centroid - or, for "Other", to the closest voice
  /// there was. Null when there was nothing to score.
  final double? sim;

  Map<String, Object?> toJson() => <String, Object?>{
    'person': person,
    'sim': sim,
  };

  static VoiceAssignment? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final person = json['person'];
    final sim = json['sim'];
    if (person != null && person is! String) return null;
    if (sim != null && sim is! num) return null;
    return VoiceAssignment(
      person: person as String?,
      sim: (sim as num?)?.toDouble(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is VoiceAssignment && other.person == person && other.sim == sim;

  @override
  int get hashCode => Object.hash(person, sim);

  @override
  String toString() => 'VoiceAssignment($person, $sim)';
}

/// One note's verdict against one revision of the voiceprint store.
class NoteVoiceMatch {
  NoteVoiceMatch({
    required this.revision,
    required this.tag,
    required List<VoiceAssignment> turns,
    required Map<String, VoiceAssignment> labels,
  }) : turns = List<VoiceAssignment>.unmodifiable(turns),
       labels = Map<String, VoiceAssignment>.unmodifiable(labels);

  final int revision;
  final NoteVoiceTag tag;

  /// One per [NoteVoices.turns], in the same order.
  final List<VoiceAssignment> turns;

  /// Keyed by the label as shown - after the user's merges.
  final Map<String, VoiceAssignment> labels;

  Map<String, Object?> toJson() => <String, Object?>{
    'revision': revision,
    'tag': tag.name,
    'turns': <Object?>[for (final t in turns) t.toJson()],
    'labels': <String, Object?>{
      for (final e in labels.entries) e.key: e.value.toJson(),
    },
  };

  static NoteVoiceMatch? fromJson(Object? json, int turnCount) {
    if (json is! Map<String, Object?>) return null;
    final revision = json['revision'];
    final tag = NoteVoiceTag.values.asNameMap()[json['tag']];
    final rawTurns = json['turns'];
    final rawLabels = json['labels'];
    if (revision is! int || tag == null) return null;
    if (rawTurns is! List || rawTurns.length != turnCount) return null;
    if (rawLabels is! Map<String, Object?>) return null;
    final turns = <VoiceAssignment>[];
    for (final raw in rawTurns) {
      final turn = VoiceAssignment.fromJson(raw);
      if (turn == null) return null;
      turns.add(turn);
    }
    final labels = <String, VoiceAssignment>{};
    for (final entry in rawLabels.entries) {
      final label = VoiceAssignment.fromJson(entry.value);
      if (label == null) return null;
      labels[entry.key] = label;
    }
    return NoteVoiceMatch(
      revision: revision,
      tag: tag,
      turns: turns,
      labels: labels,
    );
  }
}

/// The voices of one note.
class NoteVoices {
  NoteVoices({
    required this.model,
    required this.dim,
    required List<VoiceTurn> turns,
    this.match,
  }) : turns = List<VoiceTurn>.unmodifiable(turns);

  static const int formatVersion = 1;

  /// The embedding model [turns] came from; matched only against a store of
  /// the same model.
  final String model;
  final int dim;
  final List<VoiceTurn> turns;

  /// Null until the note has been matched.
  final NoteVoiceMatch? match;

  NoteVoices withMatch(NoteVoiceMatch match) =>
      NoteVoices(model: model, dim: dim, turns: turns, match: match);

  /// Seconds of speech behind an embedding.
  double get embeddedSeconds => turns.fold<double>(
    0,
    (sum, t) => t.embedding == null ? sum : sum + t.seconds,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'version': formatVersion,
    'model': model,
    'dim': dim,
    'turns': <Object?>[for (final t in turns) t.toJson()],
    if (match != null) 'match': match!.toJson(),
  };

  /// The voices in [text], or null for anything damaged. Never throws.
  static NoteVoices? decode(String text) {
    try {
      return fromJson(jsonDecode(text));
    } on FormatException {
      return null;
    }
  }

  /// The voices in [json], or null for anything damaged. Never throws.
  ///
  /// ALL OR NOTHING for the turns: a note half-read would be matched on half
  /// its voices and could be hidden for it. A damaged [match] alone is
  /// dropped, which only means the note is matched again.
  static NoteVoices? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    if (json['version'] != formatVersion) return null;
    final model = json['model'];
    final dim = json['dim'];
    final rawTurns = json['turns'];
    if (model is! String || dim is! int || dim <= 0 || rawTurns is! List) {
      return null;
    }
    final turns = <VoiceTurn>[];
    for (final raw in rawTurns) {
      final turn = _turnFromJson(raw, dim);
      if (turn == null) return null;
      turns.add(turn);
    }
    return NoteVoices(
      model: model,
      dim: dim,
      turns: turns,
      match: NoteVoiceMatch.fromJson(json['match'], turns.length),
    );
  }

  static VoiceTurn? _turnFromJson(Object? json, int dim) {
    if (json is! Map<String, Object?>) return null;
    final start = json['start'];
    final end = json['end'];
    final label = json['label'];
    final seconds = json['seconds'];
    final rawEmbedding = json['emb'];
    if (start is! int || end is! int || start < 0 || end < start) return null;
    if (label is! String || seconds is! num || seconds < 0) return null;
    final embedding = rawEmbedding == null
        ? null
        : VoiceVector.decode(rawEmbedding, dim);
    if (rawEmbedding != null && embedding == null) return null;
    return VoiceTurn(
      startMs: start,
      endMs: end,
      label: label,
      seconds: seconds.toDouble(),
      embedding: embedding,
    );
  }
}
