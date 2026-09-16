/// What the user decided about the speakers in ONE note: how many there are,
/// and which of them are really the same person.
///
/// Pure data: JSON in and out, no I/O. Saved beside the recording by
/// `services/transcription/speaker_settings_store.dart`, in its own sidecar so
/// that transcribing the note again - which replaces the transcript file whole
/// - cannot lose it.
///
/// SEPARATE FROM [SpeakerNames] on purpose. Names are what the speakers are
/// CALLED; this is how the note is SEPARATED. They are edited in the same
/// sheet but they survive different things: a merge changes which labels
/// exist, a rename does not.
library;

/// The speaker count and merges the user chose for one note.
class SpeakerSettings {
  const SpeakerSettings({
    this.speakerCount,
    this.merges = const <String, String>{},
  });

  static const SpeakerSettings empty = SpeakerSettings();

  static const int formatVersion = 1;

  /// The lowest and highest counts the sheet offers. 4 means "4 or more": the
  /// clustering takes a number, and five voices split into four still reads
  /// far better than one wall of text.
  static const int minCount = 2;
  static const int maxCount = 4;

  /// How many speakers the user says are in this note; null is Auto - let the
  /// clustering decide.
  final int? speakerCount;

  /// Label to the label it was merged into, already followed all the way
  /// through: no value here is itself a key. Never modified in place.
  final Map<String, String> merges;

  bool get isEmpty => speakerCount == null && merges.isEmpty;

  /// What [label] should be shown as, after every merge the user made.
  String resolve(String label) => merges[label] ?? label;

  /// These settings with the count set - [count] null is Auto. Out-of-range
  /// counts are refused rather than silently clamped.
  SpeakerSettings withCount(int? count) {
    if (count != null && (count < minCount || count > maxCount)) {
      throw ArgumentError.value(
        count,
        'count',
        'must be null (auto) or $minCount-$maxCount',
      );
    }
    return SpeakerSettings(speakerCount: count, merges: merges);
  }

  /// These settings with [from] merged into [into].
  ///
  /// TRANSITIVE, AND FLAT. Merging into a label that was itself merged away
  /// follows the chain to where it ended up, and anything that pointed at
  /// [from] is repointed, so [merges] never needs to be followed more than
  /// once. Merging a label into itself changes nothing.
  SpeakerSettings withMerge(String from, String into) {
    final target = resolve(into);
    if (from == target) return this;
    final next = <String, String>{};
    merges.forEach((label, to) {
      next[label] = to == from ? target : to;
    });
    next[from] = target;
    return SpeakerSettings(
      speakerCount: speakerCount,
      merges: Map<String, String>.unmodifiable(next),
    );
  }

  /// These settings with every merge forgotten.
  SpeakerSettings withoutMerges() =>
      SpeakerSettings(speakerCount: speakerCount);

  Map<String, Object?> toJson() => <String, Object?>{
        'version': formatVersion,
        if (speakerCount != null) 'count': speakerCount,
        if (merges.isNotEmpty) 'merges': <String, String>{...merges},
      };

  /// The settings in [json]; [empty] for anything unreadable. Never throws: a
  /// damaged sidecar costs the user's choice, never the note.
  static SpeakerSettings fromJson(Object? json) {
    if (json is! Map<String, Object?>) return empty;
    if (json['version'] != formatVersion) return empty;
    final count = json['count'];
    final rawMerges = json['merges'];
    final raw = <String, String>{};
    if (rawMerges is Map<String, Object?>) {
      rawMerges.forEach((label, into) {
        if (into is String && into.isNotEmpty && label != into) {
          raw[label] = into;
        }
      });
    }
    // A file written by another build - or edited by hand - may hold a chain
    // or a cycle; flatten it, so [resolve] never has to follow one.
    final merges = <String, String>{};
    for (final label in raw.keys) {
      var to = raw[label]!;
      final seen = <String>{label};
      while (raw[to] != null && seen.add(to)) {
        to = raw[to]!;
      }
      if (to != label) merges[label] = to;
    }
    return SpeakerSettings(
      speakerCount:
          count is int && count >= minCount && count <= maxCount ? count : null,
      merges: Map<String, String>.unmodifiable(merges),
    );
  }

  @override
  bool operator ==(Object other) {
    if (other is! SpeakerSettings ||
        other.speakerCount != speakerCount ||
        other.merges.length != merges.length) {
      return false;
    }
    for (final entry in merges.entries) {
      if (other.merges[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        speakerCount,
        Object.hashAllUnordered(
          merges.entries.map((e) => Object.hash(e.key, e.value)),
        ),
      );

  @override
  String toString() =>
      'SpeakerSettings(count: $speakerCount, merges: $merges)';
}
