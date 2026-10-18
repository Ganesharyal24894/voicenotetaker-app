/// One known voice and the samples it is made of.
///
/// Pure data, split from `voiceprint.dart` - the store that holds these and
/// every rule about changing them - to keep each file readable.
library;

import 'dart:typed_data';

import 'voice_vector.dart';
import 'voiceprint.dart';

enum VoiceSampleSource { enrolment, note }

/// One embedding of one person, and where it came from.
class VoiceSample {
  VoiceSample.enrolment({
    required this.at,
    required this.seconds,
    required List<double> embedding,
  }) : source = VoiceSampleSource.enrolment,
       note = null,
       label = null,
       embedding = VoiceVector.normalise(embedding);

  VoiceSample.fromNote({
    required String this.note,
    required String this.label,
    required this.at,
    required this.seconds,
    required List<double> embedding,
  }) : source = VoiceSampleSource.note,
       embedding = VoiceVector.normalise(embedding);

  final VoiceSampleSource source;

  /// The note and label a tag came from; null for the enrolment sample.
  final String? note;
  final String? label;
  final DateTime at;

  /// Seconds of speech the embedding was computed from: its weight in the
  /// centroid.
  final double seconds;

  /// L2-normalised.
  final Float32List embedding;

  bool isFrom(String note, String label) =>
      source == VoiceSampleSource.note &&
      this.note == note &&
      this.label == label;

  Map<String, Object?> toJson() => <String, Object?>{
    'source': source.name,
    if (note != null) 'note': note,
    if (label != null) 'label': label,
    'at': at.toUtc().toIso8601String(),
    'seconds': seconds,
    'embedding': VoiceVector.encode(embedding),
  };

  static VoiceSample? fromJson(Object? json, int dim) {
    if (json is! Map<String, Object?>) return null;
    final at = DateTime.tryParse(json['at'] as String? ?? '');
    final seconds = json['seconds'];
    final embedding = VoiceVector.decode(json['embedding'], dim);
    if (at == null || seconds is! num || seconds <= 0 || embedding == null) {
      return null;
    }
    switch (json['source']) {
      case 'enrolment':
        return VoiceSample.enrolment(
          at: at,
          seconds: seconds.toDouble(),
          embedding: embedding,
        );
      case 'note':
        final note = json['note'];
        final label = json['label'];
        if (note is! String || label is! String) return null;
        return VoiceSample.fromNote(
          note: note,
          label: label,
          at: at,
          seconds: seconds.toDouble(),
          embedding: embedding,
        );
    }
    return null;
  }
}

/// One known voice.
class VoicePerson {
  VoicePerson({
    required this.id,
    required this.owner,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    required List<VoiceSample> samples,
    required int dim,
  }) : samples = List<VoiceSample>.unmodifiable(samples),
       seconds = samples.fold<double>(0, (sum, s) => sum + s.seconds),
       centroid = VoiceVector.weightedMean(
         samples.map((s) => (s.embedding, s.seconds)),
         dim,
       );

  final String id;
  final bool owner;

  /// What the user called them; null for the owner, who is always "You".
  final String? name;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Never empty: a person whose last sample goes is removed.
  final List<VoiceSample> samples;

  /// Total speech behind [centroid].
  final double seconds;

  /// normalise(sum of seconds x sample).
  final Float32List centroid;

  /// This person with [name], [samples] or both changed. [clearName] removes
  /// the name.
  VoicePerson changed({
    String? name,
    bool clearName = false,
    required DateTime updatedAt,
    List<VoiceSample>? samples,
  }) => VoicePerson(
    id: id,
    owner: owner,
    name: clearName ? null : name ?? this.name,
    createdAt: createdAt,
    updatedAt: updatedAt,
    samples: samples ?? this.samples,
    dim: centroid.length,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'owner': owner,
    'name': name,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'seconds': seconds,
    'centroid': VoiceVector.encode(centroid),
    'samples': <Object?>[for (final s in samples) s.toJson()],
  };

  static VoicePerson? fromJson(Object? json, int dim) {
    if (json is! Map<String, Object?>) return null;
    final id = json['id'];
    final name = json['name'];
    final createdAt = DateTime.tryParse(json['createdAt'] as String? ?? '');
    final updatedAt = DateTime.tryParse(json['updatedAt'] as String? ?? '');
    final rawSamples = json['samples'];
    if (id is! String || id.isEmpty) return null;
    if (createdAt == null || updatedAt == null || rawSamples is! List) {
      return null;
    }
    final samples = <VoiceSample>[
      for (final raw in rawSamples) ?VoiceSample.fromJson(raw, dim),
    ];
    if (samples.isEmpty) return null;
    return VoicePerson(
      id: id,
      owner: id == Voiceprints.ownerId,
      name: name is String && name.trim().isNotEmpty ? name.trim() : null,
      createdAt: createdAt,
      updatedAt: updatedAt,
      samples: samples,
      dim: dim,
    );
  }
}
