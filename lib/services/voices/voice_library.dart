import 'dart:async';

import '../../drivers/file_store.dart';
import '../../model/note_voices.dart';
import '../../model/voice_match.dart';
import '../../model/voice_vector.dart';
import '../../model/voiceprint.dart';
import '../library_service.dart';
import '../transcription/speaker_settings_store.dart';
import 'note_voices_store.dart';
import 'voiceprint_store.dart';

/// The known voices and every note's verdict against them, kept in step.
///
/// Three files move together here: the voiceprint store, each note's
/// `.voices.json` (its `match` block), and each note's background marker. The
/// user's answers about a note - "this is Priya", "keep this one" - go in its
/// `SpeakerSettings`, beside the merges, so transcribing again keeps them.
///
/// NEVER THE AUDIO. Matching reads stored embeddings only, so every note can
/// be matched again in milliseconds whenever a voice is enrolled, named or
/// forgotten - including notes whose audio the 24 h sweep already removed.
///
/// ONE THING AT A TIME. Every change goes through one queue: a note saved by
/// the transcription job while the whole library is being re-matched must not
/// be overwritten by the re-match's older copy of it.
class VoiceLibrary {
  VoiceLibrary({
    required this._fileStore,
    required this._recordingsDirectory,
    required this._store,
    NoteVoicesStore? notes,
    SpeakerSettingsStore? settings,
    DateTime Function()? clock,
  }) : _notes = notes ?? NoteVoicesStore(fileStore: _fileStore),
       _settings = settings ?? SpeakerSettingsStore(fileStore: _fileStore),
       _now = clock ?? DateTime.now;

  final FileStore _fileStore;
  final String _recordingsDirectory;
  final VoiceprintStore _store;
  final NoteVoicesStore _notes;
  final SpeakerSettingsStore _settings;
  final DateTime Function() _now;

  final StreamController<void> _changes = StreamController<void>.broadcast();
  Future<void> _queue = Future<void>.value();
  Voiceprints? _prints;

  /// Something a list shows moved: a background marker, or the voices.
  Stream<void> get changes => _changes.stream;

  /// The voices as last read; empty before [load].
  Voiceprints get prints => _prints ?? _store.empty();

  Future<Voiceprints> load() => _serial(_loaded);

  /// Saves the voices a transcription found in the note at [audioPath],
  /// matched against the known ones, and marks or unmarks it background.
  ///
  /// Never throws: it runs unattended after a transcript is saved, and a
  /// note whose voices could not be written is simply not filtered. Answers
  /// whether they were written.
  Future<bool> noteHeard(String audioPath, NoteVoices voices) =>
      _serial(() async {
        await _match(audioPath, await _loaded(), voices);
        return true;
      }).catchError((Object _) => false);

  Future<NoteVoices?> voicesOf(String audioPath) => _notes.load(audioPath);

  /// The owner's guided recording becomes their enrolment sample.
  Future<void> enrol(List<double> embedding, double seconds) => _change(
    (p) => p.withEnrolment(embedding: embedding, seconds: seconds, at: _now()),
  );

  /// Says [label] of the note at [audioPath] is [person] - an id from
  /// [prints], [Voiceprints.ownerId] for "It's me" - or, with no [person],
  /// someone new called [name]. The label's voice becomes a sample of theirs
  /// and the label is pinned. Answers the person's id; null when the note
  /// has no stored voice for that label, so there is nothing to learn from.
  Future<String?> tag(
    String audioPath,
    String label, {
    String? person,
    String? name,
  }) => _serial(() async {
    final prints = await _loaded();
    final voices = await _notes.load(audioPath);
    if (voices == null) return null;
    final settings = await _settings.load(audioPath);
    final turns = <VoiceTurn>[
      for (final t in voices.turns)
        if (settings.resolve(t.label) == label && t.embedding != null) t,
    ];
    final seconds = turns.fold<double>(0, (sum, t) => sum + t.seconds);
    if (turns.isEmpty || seconds <= 0) return null;
    final id = person ?? _newId(prints);
    final next = prints.withNoteSample(
      person: id,
      name: name,
      note: _noteId(audioPath),
      label: label,
      seconds: seconds,
      embedding: VoiceVector.weightedMean(
        turns.map((t) => (t.embedding!, t.seconds)),
        prints.dim,
      ),
      at: _now(),
    );
    await _save(next);
    await _settings.save(audioPath, settings.withPerson(label, id));
    await _match(audioPath, next, voices);
    return id;
  });

  /// Takes back a [tag]: the sample goes, and so does the pin.
  Future<void> untag(String audioPath, String label) => _serial(() async {
    final prints = await _loaded();
    final next = prints.withoutNoteSample(
      note: _noteId(audioPath),
      label: label,
      at: _now(),
    );
    if (!identical(next, prints)) await _save(next);
    final settings = await _settings.load(audioPath);
    await _settings.save(audioPath, settings.withPerson(label, null));
    await _rematch(audioPath, next);
  });

  /// [person] and every sample of theirs; for the owner, "Remove my voice".
  Future<void> forget(String person) => _change((p) => p.withoutPerson(person));

  Future<void> rename(String person, String? name) =>
      _change((p) => p.withName(person, name, _now()));

  /// The user saying the note at [audioPath] is - or is no longer - one to
  /// show whoever is in it.
  Future<void> keep(String audioPath, bool keep) => _serial(() async {
    final settings = await _settings.load(audioPath);
    await _settings.save(audioPath, settings.withKeep(keep));
    await _rematch(audioPath, await _loaded());
  });

  /// Matches the note at [audioPath] again: after the user merged two of its
  /// speakers, which changes what each label's voice is but not the voices.
  Future<void> rematch(String audioPath) =>
      _serial(() async => _rematch(audioPath, await _loaded()));

  /// Matches every note with stored voices again; with [staleOnly], only
  /// those last matched against another revision of the voices - what a
  /// start-up needs. Answers how many notes were looked at.
  Future<int> rematchAll({
    bool staleOnly = false,
    void Function(int done, int total)? onProgress,
  }) => _serial(() async {
    final prints = await _loaded();
    final notes = <String>[
      for (final path in await _fileStore.list(_recordingsDirectory))
        if (path.endsWith(RecordingNaming.voicesSuffix))
          RecordingNaming.audioPathOfSidecar(
            path,
            RecordingNaming.voicesSuffix,
          ),
    ];
    var changed = false;
    for (var i = 0; i < notes.length; i++) {
      onProgress?.call(i, notes.length);
      final voices = await _notes.load(notes[i]);
      if (voices == null) continue;
      if (staleOnly && voices.match?.revision == prints.revision) continue;
      changed = await _match(notes[i], prints, voices, quiet: true) || changed;
    }
    onProgress?.call(notes.length, notes.length);
    if (changed) _tell();
    return notes.length;
  });

  /// How many notes are marked background.
  Future<int> backgroundCount() async =>
      (await _fileStore.list(_recordingsDirectory))
          .where((p) => p.endsWith(RecordingNaming.backgroundSuffix))
          .length;

  Future<void> dispose() async {
    if (!_changes.isClosed) await _changes.close();
  }

  Future<Voiceprints> _loaded() async => _prints ??= await _store.load();

  Future<void> _change(Voiceprints Function(Voiceprints prints) change) =>
      _serial(() async {
        final prints = await _loaded();
        final next = change(prints);
        if (!identical(next, prints)) await _save(next);
      });

  Future<void> _save(Voiceprints next) async {
    await _store.save(next);
    _prints = next;
    _tell();
  }

  Future<void> _rematch(String audioPath, Voiceprints prints) async {
    final voices = await _notes.load(audioPath);
    if (voices != null) await _match(audioPath, prints, voices);
  }

  /// Writes [voices] matched against [prints] and sets the marker to suit.
  /// Answers whether the marker moved; [quiet] leaves telling anyone to the
  /// caller.
  Future<bool> _match(
    String audioPath,
    Voiceprints prints,
    NoteVoices voices, {
    bool quiet = false,
  }) async {
    final settings = await _settings.load(audioPath);
    final match = VoiceMatch.match(
      voices,
      prints,
      resolve: settings.resolve,
      pins: settings.people,
      keep: settings.keep,
    );
    await _notes.save(audioPath, voices.withMatch(match));
    final moved = await _notes.setBackground(
      audioPath,
      match.tag == NoteVoiceTag.background,
    );
    if (moved && !quiet) _tell();
    return moved;
  }

  /// `voicenote-20261018-101500`: what a sample says it came from.
  static String _noteId(String audioPath) {
    final slash = audioPath.lastIndexOf(RegExp(r'[/\\]'));
    final name = slash < 0 ? audioPath : audioPath.substring(slash + 1);
    return name.endsWith(RecordingNaming.extension)
        ? name.substring(0, name.length - RecordingNaming.extension.length)
        : name;
  }

  /// `p-20261018T101500`, with a number after it in the rare second that
  /// already has one.
  String _newId(Voiceprints prints) {
    final at = _now();
    String two(int v) => v.toString().padLeft(2, '0');
    final base =
        'p-${at.year}${two(at.month)}${two(at.day)}'
        'T${two(at.hour)}${two(at.minute)}${two(at.second)}';
    var id = base;
    for (var n = 2; prints.person(id) != null; n++) {
      id = '$base-$n';
    }
    return id;
  }

  void _tell() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}
