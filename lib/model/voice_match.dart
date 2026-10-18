/// Whose voice is in a note: each label, each turn, and the note as a whole.
///
/// PURE: a note's stored embeddings and the voiceprint store in, a verdict
/// out. Nothing here looks at audio, so every note can be matched again in
/// milliseconds whenever the owner enrols, tags or forgets a voice.
///
/// LEANS TO KEEPING. The one verdict that hides anything is
/// [NoteVoiceTag.background], and every rule below that is unsure answers
/// with something shown. Hiding a note the owner spoke in is the failure that
/// matters; showing a stranger's chatter costs a swipe.
library;

import 'note_voices.dart';
import 'voice_vector.dart';
import 'voiceprint.dart';

abstract final class VoiceMatch {
  // PROVISIONAL, pending ground-truth measurement against the owner's own
  // labelled notes. What is known so far (notetaker-data/
  // voice-filter-20261018-171818): the owner's median cosine per segment is
  // 0.63, while other people's 95th percentile reaches 0.62. Per segment the
  // voices barely separate, so decisions are taken per LABEL and per NOTE,
  // where seconds of speech are averaged; a single turn is trusted only to
  // keep the owner visible ([ownerStrong]), never to hide anything.

  /// A label at least this close to the owner is "You". Low on purpose: the
  /// uncertain band counts as the owner.
  static const double ownerKeep = 0.30;

  /// One turn at least this close to the owner shows as "You" even inside a
  /// label matched to someone else, and keeps the note out of background.
  static const double ownerStrong = 0.55;

  /// Another person needs at least this...
  static const double personMatch = 0.55;

  /// ...and must lead the next-best voice - the owner included - by this.
  /// Also how far another person must lead the owner to take a label off
  /// them.
  static const double personMargin = 0.05;

  /// Less embedded speech than this in a note is never background: a few
  /// seconds is not enough to say nobody known is there.
  static const Duration minEvidence = Duration(seconds: 6);

  /// A piece of one voice shorter than this is not embedded.
  static const Duration minPiece = Duration(milliseconds: 1500);

  /// At most this much speech of one turn is embedded.
  static const Duration maxPerTurn = Duration(seconds: 8);

  /// At most this many turns of one note are embedded.
  static const int maxTurns = 64;

  /// Within [maxTurns], each label gets at least this many turns embedded
  /// where it has them.
  static const int minPerLabel = 3;

  static String _same(String label) => label;

  /// [voices] matched against [prints].
  ///
  /// [resolve] maps a turn's label to the label it is shown as - the user's
  /// merges, `SpeakerSettings.resolve` - so merged labels are scored on all
  /// their turns together. [pins] are labels the user said are a given
  /// person: they are not scored. A pin naming nobody in [prints] (a
  /// forgotten voice) is ignored. [keep] is the user saying this note is not
  /// background.
  ///
  /// THE RULES, each a test:
  ///   * a label's score against a person is the cosine of its turns'
  ///     seconds-weighted mean to that person's centroid;
  ///   * "You" if the owner scores at least [ownerKeep] and nobody else beats
  ///     the owner by [personMargin];
  ///   * else another person, if they score at least [personMatch] and lead
  ///     the next-best by [personMargin];
  ///   * else nobody ("Other");
  ///   * a turn shows its label's person, except that a turn at least
  ///     [ownerStrong] close to the owner shows as "You";
  ///   * the note is [NoteVoiceTag.unknown] with no owner enrolled - an
  ///     owner known only from "It's me" tags is not enrolled
  ///     ([Voiceprints.isEnrolled]), though their labels still show as
  ///     "You" - no embedded voices, or under [minEvidence] of them;
  ///     [NoteVoiceTag.own] when every label is "You";
  ///     [NoteVoiceTag.background] when no label is anyone, no turn reaches
  ///     [ownerStrong] and the user has not said keep;
  ///     [NoteVoiceTag.mixed] otherwise.
  static NoteVoiceMatch match(
    NoteVoices voices,
    Voiceprints prints, {
    String Function(String label) resolve = _same,
    Map<String, String> pins = const <String, String>{},
    bool keep = false,
  }) {
    final comparable = voices.model == prints.model && voices.dim == prints.dim;
    final people = comparable ? prints.people : const <VoicePerson>[];
    final owner = comparable ? prints.owner : null;

    final groups = <String, List<VoiceTurn>>{};
    for (final turn in voices.turns) {
      (groups[resolve(turn.label)] ??= <VoiceTurn>[]).add(turn);
    }
    final labels = <String, VoiceAssignment>{
      for (final entry in groups.entries)
        entry.key: _label(entry.key, entry.value, people, prints, pins),
    };

    var anyStrong = false;
    final turns = <VoiceAssignment>[];
    for (final turn in voices.turns) {
      final label = labels[resolve(turn.label)]!;
      final embedding = turn.embedding;
      if (embedding == null) {
        turns.add(VoiceAssignment(person: label.person));
        continue;
      }
      final ownerSim = owner == null
          ? null
          : VoiceVector.cosine(embedding, owner.centroid);
      if (ownerSim != null && ownerSim >= ownerStrong) {
        anyStrong = true;
        turns.add(VoiceAssignment(person: owner!.id, sim: ownerSim));
        continue;
      }
      final shown = label.person == null ? null : prints.person(label.person!);
      turns.add(
        VoiceAssignment(
          person: label.person,
          sim: shown != null
              ? VoiceVector.cosine(embedding, shown.centroid)
              : _closest(embedding, people),
        ),
      );
    }

    return NoteVoiceMatch(
      revision: prints.revision,
      tag: _tag(
        voices,
        comparable && prints.isEnrolled ? owner : null,
        labels,
        anyStrong: anyStrong,
        keep: keep,
      ),
      turns: turns,
      labels: labels,
    );
  }

  static VoiceAssignment _label(
    String label,
    List<VoiceTurn> turns,
    List<VoicePerson> people,
    Voiceprints prints,
    Map<String, String> pins,
  ) {
    final embedded = <VoiceTurn>[
      for (final t in turns)
        if (t.embedding != null) t,
    ];
    final mean = embedded.isEmpty
        ? null
        : VoiceVector.weightedMean(
            embedded.map((t) => (t.embedding!, t.seconds)),
            prints.dim,
          );

    var pin = pins[label];
    for (final t in turns) {
      pin ??= pins[t.label];
    }
    final pinned = pin == null ? null : prints.person(pin);
    if (pinned != null && people.contains(pinned)) {
      return VoiceAssignment(
        person: pinned.id,
        sim: mean == null ? null : VoiceVector.cosine(mean, pinned.centroid),
      );
    }
    if (mean == null || people.isEmpty) return const VoiceAssignment();

    final scores = <VoicePerson, double>{
      for (final p in people) p: VoiceVector.cosine(mean, p.centroid),
    };
    final ranked = scores.keys.toList()
      ..sort((a, b) => scores[b]!.compareTo(scores[a]!));
    final ownerSim = scores.entries
        .where((e) => e.key.owner)
        .map((e) => e.value)
        .firstOrNull;
    final others = <VoicePerson>[
      for (final p in ranked)
        if (!p.owner) p,
    ];
    final bestOther = others.isEmpty ? null : scores[others.first]!;

    if (ownerSim != null &&
        ownerSim >= ownerKeep &&
        (bestOther == null || bestOther - ownerSim < personMargin)) {
      return VoiceAssignment(person: Voiceprints.ownerId, sim: ownerSim);
    }
    if (bestOther != null && bestOther >= personMatch) {
      // The next-best is whoever ranks second overall, owner included.
      final next = ranked.length > 1 ? scores[ranked[1]]! : null;
      if (identical(ranked.first, others.first) &&
          (next == null || bestOther - next >= personMargin)) {
        return VoiceAssignment(person: others.first.id, sim: bestOther);
      }
    }
    return VoiceAssignment(sim: scores[ranked.first]);
  }

  static double? _closest(List<double> embedding, List<VoicePerson> people) {
    double? best;
    for (final p in people) {
      final sim = VoiceVector.cosine(embedding, p.centroid);
      if (best == null || sim > best) best = sim;
    }
    return best;
  }

  /// [owner] is null unless the owner is enrolled.
  static NoteVoiceTag _tag(
    NoteVoices voices,
    VoicePerson? owner,
    Map<String, VoiceAssignment> labels, {
    required bool anyStrong,
    required bool keep,
  }) {
    final evidence = voices.embeddedSeconds;
    if (owner == null ||
        evidence <= 0 ||
        evidence * 1000 < minEvidence.inMilliseconds) {
      return NoteVoiceTag.unknown;
    }
    if (labels.values.every((l) => l.person == owner.id)) {
      return NoteVoiceTag.own;
    }
    final anyone = labels.values.any((l) => l.person != null);
    if (!anyone && !anyStrong && !keep) return NoteVoiceTag.background;
    return NoteVoiceTag.mixed;
  }
}
