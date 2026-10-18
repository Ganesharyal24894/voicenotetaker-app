import 'dart:async';

import 'package:flutter/foundation.dart';

import '../drivers/file_store.dart';
import '../model/enrolment_check.dart';
import '../model/voiceprint.dart';
import '../services/voices/enrolment_service.dart';
import '../services/voices/voice_library.dart';
import 'enrolment_state.dart';

export 'enrolment_state.dart';

/// Everything the Voices screens need: the owner's enrolment, the people the
/// owner has named, and how many notes are hidden as background.
///
/// No screen uses it yet; it is the seam they will be built against, and a
/// fake can stand in for it in their tests.
///
/// AFTER EVERY CHANGE TO THE VOICES, EVERY NOTE IS MATCHED AGAIN - enrolling,
/// naming, taking a name back, forgetting someone. It reads stored
/// embeddings only, and [rematchProgress] says how far it has got.
class VoicesController extends ChangeNotifier {
  VoicesController({
    required this._library,
    required this._enrolment,
    required this._recorder,
    required this._fileStore,
    required this._voicesDirectory,
    DateTime Function()? clock,
    this._tick = const Duration(seconds: 1),
  }) : _now = clock ?? DateTime.now {
    _recorder.addListener(_onRecorder);
    _changes = _library.changes.listen((_) => unawaited(_count()));
  }

  final VoiceLibrary _library;
  final EnrolmentService _enrolment;
  final VoiceSampleRecorder _recorder;
  final FileStore _fileStore;

  /// `<support>/voices`: the voiceprints, and the accepted enrolment WAV.
  final String _voicesDirectory;
  final DateTime Function() _now;
  final Duration _tick;

  late final StreamSubscription<void> _changes;
  EnrolmentState _state = const EnrolmentIdle();
  Timer? _ticker;
  DateTime? _startedAt;
  String? _take;
  int _background = 0;
  double? _rematch;
  String? _error;

  EnrolmentState get enrolment => _state;

  Voiceprints get prints => _library.prints;

  bool get isEnrolled => prints.isEnrolled;

  /// When the owner made the recording that counts, or null.
  DateTime? get enrolledAt {
    for (final s in prints.owner?.samples ?? const <VoiceSample>[]) {
      if (s.source == VoiceSampleSource.enrolment) return s.at;
    }
    return null;
  }

  /// Everyone named, the owner left out: the owner is always "You".
  List<VoicePerson> get people => <VoicePerson>[
    for (final p in prints.people)
      if (!p.owner) p,
  ];

  /// Notes hidden as background.
  int get backgroundCount => _background;

  /// `0.0`-`1.0` while notes are matched again; null otherwise.
  double? get rematchProgress => _rematch;

  /// The last thing that could not be saved, in a sentence.
  String? get error => _error;

  /// Reads the voices, and matches again any note matched against an older
  /// set of them.
  Future<void> load() async {
    await _library.load();
    await _count();
    await _rematchAll(staleOnly: true);
  }

  /// The intro, or why there cannot be one.
  Future<void> prepare() async {
    if (_state is EnrolmentRecording || _state is EnrolmentChecking) return;
    _set(await _blocked() ?? const EnrolmentIdle());
  }

  Future<void> startEnrolment() async {
    await prepare();
    if (_state is! EnrolmentIdle) return;
    final at = _now();
    final path = _fileStore.join(
      _voicesDirectory,
      'enrol-${at.millisecondsSinceEpoch}.wav',
    );
    if (!await _recorder.startVoiceSample(path)) {
      _set(
        const EnrolmentRetry(EnrolmentVerdict.retry(EnrolmentProblem.linkLost)),
      );
      return;
    }
    _take = path;
    _startedAt = at;
    _ticker = Timer.periodic(_tick, (_) => _set(_recording()));
    _set(_recording());
  }

  /// Done: the recording is checked, and becomes the owner's voice if good.
  Future<void> finishEnrolment() async {
    final path = _take;
    if (_state is! EnrolmentRecording || path == null) return;
    _stopTicking();
    _take = null;
    _set(const EnrolmentChecking());
    final take = await _recorder.stopVoiceSample();
    final verdict = await _enrolment.check(
      path,
      linkLost: take == null || take.linkLost,
      onProgress: (f) => _set(EnrolmentChecking(f)),
    );
    final embedding = verdict.embedding;
    if (embedding == null) {
      await _deleteQuietly(path);
      _set(EnrolmentRetry(verdict));
      return;
    }
    final saved = await _guard(() async {
      await _library.enrol(embedding, verdict.speech.inMilliseconds / 1000);
      // The one recording kept is the one that counts.
      await _deleteRecordings(except: path);
    });
    if (!saved) {
      _set(
        const EnrolmentRetry(
          EnrolmentVerdict.retry(EnrolmentProblem.couldNotCheck),
        ),
      );
      return;
    }
    _set(const EnrolmentDone());
    await _rematchAll();
  }

  /// Cancel: nothing is kept.
  Future<void> cancelEnrolment() async {
    final path = _take;
    if (_state is EnrolmentRecording && path != null) {
      _stopTicking();
      _take = null;
      await _recorder.stopVoiceSample();
      await _deleteQuietly(path);
    }
    _set(const EnrolmentIdle());
  }

  /// "Remove my voice": notes go back to showing everything.
  Future<void> removeMyVoice() => _changeVoices(() async {
    await _library.forget(Voiceprints.ownerId);
    await _deleteRecordings();
  });

  /// "Who's this?": [label] of the note at [path] is [person], or someone
  /// new called [name].
  Future<String?> tag(
    String path,
    String label, {
    String? person,
    String? name,
  }) async {
    String? id;
    await _changeVoices(() async {
      id = await _library.tag(path, label, person: person, name: name);
    });
    return id;
  }

  Future<void> untag(String path, String label) =>
      _changeVoices(() => _library.untag(path, label));

  Future<void> forget(String person) =>
      _changeVoices(() => _library.forget(person));

  Future<void> rename(String person, String? name) =>
      _guard(() => _library.rename(person, name))
          .then((_) => notifyListeners());

  /// "Show in notes", or taking it back: this note only.
  Future<void> keep(String path, bool keep) =>
      _guard(() => _library.keep(path, keep)).then((_) => _count());

  @override
  void dispose() {
    _stopTicking();
    _recorder.removeListener(_onRecorder);
    unawaited(_changes.cancel());
    super.dispose();
  }

  Future<EnrolmentState?> _blocked() async {
    if (!_recorder.isConnected) {
      return const EnrolmentBlocked(EnrolmentBlock.notConnected);
    }
    if (!await _enrolment.modelsReady()) {
      return const EnrolmentBlocked(EnrolmentBlock.modelsMissing);
    }
    return null;
  }

  EnrolmentRecording _recording() =>
      EnrolmentRecording(_now().difference(_startedAt ?? _now()));

  /// A link lost mid-recording ends it at once, with that as the reason.
  void _onRecorder() {
    if (_state is EnrolmentRecording && _recorder.voiceSampleInterrupted) {
      unawaited(finishEnrolment());
    }
  }

  Future<void> _changeVoices(Future<void> Function() change) async {
    if (await _guard(change)) await _rematchAll();
  }

  Future<void> _rematchAll({bool staleOnly = false}) async {
    await _guard(
      () => _library.rematchAll(
        staleOnly: staleOnly,
        onProgress: (done, total) {
          _rematch = total == 0 ? 1 : done / total;
          notifyListeners();
        },
      ),
    );
    _rematch = null;
    await _count();
  }

  Future<void> _count() async {
    try {
      _background = await _library.backgroundCount();
    } on Object {
      // Kept as it was; the next change counts again.
    }
    notifyListeners();
  }

  /// Runs [action]; a failure is said in [error] rather than thrown at a
  /// screen. Answers whether it succeeded.
  Future<bool> _guard(Future<void> Function() action) async {
    try {
      await action();
      _error = null;
      return true;
    } on Object catch (error) {
      _error = 'Could not save your voices: $error';
      notifyListeners();
      return false;
    }
  }

  Future<void> _deleteRecordings({String? except}) async {
    for (final path in await _fileStore.list(_voicesDirectory)) {
      final name = path.substring(path.lastIndexOf(RegExp(r'[/\\]')) + 1);
      if (path != except &&
          name.startsWith('enrol-') &&
          name.endsWith('.wav')) {
        await _fileStore.delete(path);
      }
    }
  }

  Future<void> _deleteQuietly(String path) async {
    try {
      await _fileStore.delete(path);
    } on Object {
      // A stray take in voices/ is never listed or exported; the next
      // accepted recording clears it.
    }
  }

  void _stopTicking() {
    _ticker?.cancel();
    _ticker = null;
  }

  void _set(EnrolmentState state) {
    _state = state;
    notifyListeners();
  }
}
