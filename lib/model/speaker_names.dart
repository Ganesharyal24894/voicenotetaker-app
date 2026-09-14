/// The names a user gave the speakers in one note.
///
/// Pure data: JSON in and out, no I/O. Saved beside the recording by
/// `services/transcription/speaker_names_store.dart`.
///
/// KEYED BY SPEAKER LABEL, NOT BY POSITION. A transcript made again keeps the
/// names of every label it still uses; a label it no longer uses is simply not
/// shown, and comes back named if a later run brings it back.
class SpeakerNames {
  const SpeakerNames([this._names = const <String, String>{}]);

  static const SpeakerNames empty = SpeakerNames();

  static const int formatVersion = 1;

  final Map<String, String> _names;

  bool get isEmpty => _names.isEmpty;

  /// The name given to [speaker], or null when it has none.
  String? customName(String speaker) => _names[speaker];

  /// What the screen calls [speaker]: its given name, or `Speaker N` by the
  /// order it first speaks in [order].
  String labelFor(String speaker, List<String> order) {
    final custom = _names[speaker];
    if (custom != null) return custom;
    final index = order.indexOf(speaker);
    return 'Speaker ${index < 0 ? order.length + 1 : index + 1}';
  }

  /// These names with [changes] applied. A blank name clears that speaker's
  /// name; names are trimmed.
  SpeakerNames withChanges(Map<String, String> changes) {
    final next = <String, String>{..._names};
    changes.forEach((speaker, name) {
      final trimmed = name.trim();
      if (trimmed.isEmpty) {
        next.remove(speaker);
      } else {
        next[speaker] = trimmed;
      }
    });
    return SpeakerNames(Map<String, String>.unmodifiable(next));
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'version': formatVersion,
        'names': <String, String>{..._names},
      };

  /// The names in [json]; [empty] for anything unreadable. Never throws.
  static SpeakerNames fromJson(Object? json) {
    if (json is! Map<String, Object?>) return empty;
    if (json['version'] != formatVersion) return empty;
    final raw = json['names'];
    if (raw is! Map<String, Object?>) return empty;
    final names = <String, String>{};
    raw.forEach((speaker, name) {
      if (name is String && name.trim().isNotEmpty) {
        names[speaker] = name.trim();
      }
    });
    return SpeakerNames(Map<String, String>.unmodifiable(names));
  }

  @override
  bool operator ==(Object other) {
    if (other is! SpeakerNames || other._names.length != _names.length) {
      return false;
    }
    for (final entry in _names.entries) {
      if (other._names[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAllUnordered(
        _names.entries.map((e) => Object.hash(e.key, e.value)),
      );
}
