/// The voices the app knows: the owner's, and anyone the owner has named.
///
/// Pure data: JSON in and out, no I/O, no clock - every change is told what
/// time it is. Saved as `<support>/voices/voiceprints.json`.
///
/// A PERSON IS THEIR SAMPLES. Each sample is one embedding with the seconds of
/// speech behind it; the centroid is derived from them and never edited, so
/// removing a sample is exact and the stored centroid cannot drift from the
/// samples it claims to summarise. It is written to the file for anyone
/// reading it, and recomputed on read.
///
/// TIED TO ONE MODEL. Embeddings from two different networks - or two builds
/// of the same one - are not comparable, so a store written for another model
/// reads as empty and the owner enrols again. There is no conversion.
library;

import 'voice_person.dart';

export 'voice_person.dart';

/// Every known voice, for one embedding model.
class Voiceprints {
  Voiceprints({
    required this.revision,
    required this.model,
    required this.dim,
    List<VoicePerson> people = const <VoicePerson>[],
  }) : people = List<VoicePerson>.unmodifiable(people);

  static const int formatVersion = 1;

  /// The owner's id. There is one owner, and they are always "You".
  static const String ownerId = 'me';

  /// Samples kept per person.
  ///
  /// Enough that a dozen tagged notes and the enrolment all count; few enough
  /// that one mis-tag cannot outweigh them. Over the cap the OLDEST NOTE
  /// sample goes first - a voice recorded long ago is the least like today's -
  /// and the enrolment sample never goes: it is the one sample the owner made
  /// on purpose, alone and in quiet.
  static const int maxSamples = 40;

  /// Bumped on every change, so a note matched against an older store knows
  /// to be matched again.
  final int revision;

  /// The embedding model these voices came from.
  final String model;
  final int dim;
  final List<VoicePerson> people;

  VoicePerson? get owner => person(ownerId);

  /// Whether the owner has made the guided recording.
  ///
  /// NOT merely whether the owner exists: an "It's me" tag before enrolment
  /// creates the owner from that one note, and one tagged note is too little
  /// to start hiding others' notes on. Only the enrolment - made on purpose,
  /// alone and in quiet - makes background possible.
  bool get isEnrolled =>
      owner?.samples.any((s) => s.source == VoiceSampleSource.enrolment) ??
      false;

  VoicePerson? person(String id) {
    for (final p in people) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// The owner's enrolment sample set to [embedding], replacing any earlier
  /// one; the owner is created when absent.
  Voiceprints withEnrolment({
    required List<double> embedding,
    required double seconds,
    required DateTime at,
  }) {
    final sample = VoiceSample.enrolment(
      at: at,
      seconds: seconds,
      embedding: embedding,
    );
    return _withSampleOf(
      ownerId,
      null,
      at,
      (samples) => <VoiceSample>[
        sample,
        for (final s in samples)
          if (s.source != VoiceSampleSource.enrolment) s,
      ],
    );
  }

  /// A note's [label] tagged as [person], who is created - named [name] -
  /// when not known yet.
  ///
  /// KEYED BY NOTE AND LABEL across the whole store: tagging a label again,
  /// as the same person or another, replaces what it said before.
  Voiceprints withNoteSample({
    required String person,
    String? name,
    required String note,
    required String label,
    required double seconds,
    required List<double> embedding,
    required DateTime at,
  }) {
    final sample = VoiceSample.fromNote(
      note: note,
      label: label,
      at: at,
      seconds: seconds,
      embedding: embedding,
    );
    final cleared = _withoutSample(note, label, at) ?? this;
    return cleared._withSampleOf(
      person,
      name,
      at,
      (samples) => _capped(<VoiceSample>[...samples, sample]),
    );
  }

  /// The sample a note's [label] gave, removed; a person left with no samples
  /// is removed with it. Unchanged - same revision - when there was none.
  Voiceprints withoutNoteSample({
    required String note,
    required String label,
    required DateTime at,
  }) => _withoutSample(note, label, at) ?? this;

  /// [person] renamed; a blank [name] clears it.
  Voiceprints withName(String person, String? name, DateTime at) {
    final found = this.person(person);
    if (found == null) return this;
    final trimmed = name?.trim() ?? '';
    return _replace(
      found.changed(
        name: trimmed.isEmpty ? null : trimmed,
        clearName: trimmed.isEmpty,
        updatedAt: at,
      ),
    );
  }

  /// [person] and every sample of theirs forgotten.
  Voiceprints withoutPerson(String person) {
    if (this.person(person) == null) return this;
    return _next(<VoicePerson>[
      for (final p in people)
        if (p.id != person) p,
    ]);
  }

  Voiceprints _withSampleOf(
    String id,
    String? name,
    DateTime at,
    List<VoiceSample> Function(List<VoiceSample> samples) change,
  ) {
    final found = person(id);
    if (found != null) {
      return _replace(
        found.changed(updatedAt: at, samples: change(found.samples)),
      );
    }
    final trimmed = name?.trim() ?? '';
    final created = VoicePerson(
      id: id,
      owner: id == ownerId,
      name: id == ownerId || trimmed.isEmpty ? null : trimmed,
      createdAt: at,
      updatedAt: at,
      samples: change(const <VoiceSample>[]),
      dim: dim,
    );
    _checkDim(created);
    return _next(<VoicePerson>[...people, created]);
  }

  Voiceprints? _withoutSample(String note, String label, DateTime at) {
    var changed = false;
    final next = <VoicePerson>[];
    for (final p in people) {
      if (!p.samples.any((s) => s.isFrom(note, label))) {
        next.add(p);
        continue;
      }
      changed = true;
      final kept = <VoiceSample>[
        for (final s in p.samples)
          if (!s.isFrom(note, label)) s,
      ];
      if (kept.isNotEmpty) next.add(p.changed(updatedAt: at, samples: kept));
    }
    return changed ? _next(next) : null;
  }

  static List<VoiceSample> _capped(List<VoiceSample> samples) {
    final out = <VoiceSample>[...samples];
    while (out.length > maxSamples) {
      VoiceSample? oldest;
      for (final s in out) {
        if (s.source != VoiceSampleSource.note) continue;
        if (oldest == null || s.at.isBefore(oldest.at)) oldest = s;
      }
      if (oldest == null) break;
      out.remove(oldest);
    }
    return out;
  }

  void _checkDim(VoicePerson person) {
    for (final s in person.samples) {
      if (s.embedding.length != dim) {
        throw ArgumentError.value(
          s.embedding.length,
          'embedding',
          'must have $dim values',
        );
      }
    }
  }

  Voiceprints _replace(VoicePerson changed) {
    _checkDim(changed);
    return _next(<VoicePerson>[
      for (final p in people) p.id == changed.id ? changed : p,
    ]);
  }

  Voiceprints _next(List<VoicePerson> people) => Voiceprints(
    revision: revision + 1,
    model: model,
    dim: dim,
    people: people,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'version': formatVersion,
    'revision': revision,
    'model': model,
    'dim': dim,
    'people': <Object?>[for (final p in people) p.toJson()],
  };

  /// The store in [json], for embeddings from [model] of size [dim]. Never
  /// throws.
  ///
  /// Unreadable, or written for another model: empty. In the second case the
  /// revision still moves on from the old one, so every note matched against
  /// the old voices is matched again rather than keeping a verdict nothing
  /// can now explain. A person or sample that does not parse is left out.
  static Voiceprints fromJson(
    Object? json, {
    required String model,
    required int dim,
  }) {
    if (json is! Map<String, Object?> || json['version'] != formatVersion) {
      return Voiceprints(revision: 0, model: model, dim: dim);
    }
    final revision = json['revision'] is int ? json['revision'] as int : 0;
    if (json['model'] != model || json['dim'] != dim) {
      return Voiceprints(revision: revision + 1, model: model, dim: dim);
    }
    final rawPeople = json['people'];
    final people = <VoicePerson>[];
    if (rawPeople is List) {
      for (final raw in rawPeople) {
        final person = VoicePerson.fromJson(raw, dim);
        if (person == null || people.any((p) => p.id == person.id)) continue;
        people.add(person);
      }
    }
    return Voiceprints(
      revision: revision,
      model: model,
      dim: dim,
      people: people,
    );
  }
}
