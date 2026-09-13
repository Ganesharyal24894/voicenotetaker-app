import 'dart:async';

import 'package:just_audio/just_audio.dart' as ja;

import '../model/stream_info.dart';
import 'audio_player.dart';

/// [AudioPlayer] backed by `just_audio` (MIT).
///
/// This is the ONLY file in the app that may name a playback package: the
/// interface next door is written in plain Dart and `lib/model/` types, so
/// swapping `just_audio` out means writing one new class here and changing one
/// line in `main.dart`.
///
/// Recordings are ordinary WAV files - `RecordingService` writes a 44-byte
/// RIFF header in front of the decoded PCM - so the file player handles them
/// directly and [StreamInfo] is not needed. It stays in the signature because
/// a future raw-PCM source would need it.
class JustAudioPlayer implements AudioPlayer {
  JustAudioPlayer({ja.AudioPlayer? player})
      : _player = player ?? ja.AudioPlayer() {
    // Three sources move the snapshot the app renders: the transport (play /
    // pause / completion), the clock, and the duration arriving once the file
    // has been parsed. Each of them re-publishes the whole state, so a listener
    // never has to merge partial updates itself.
    _subscriptions.addAll(<StreamSubscription<Object?>>[
      _player.playerStateStream.listen((state) {
        if (state.processingState == ja.ProcessingState.completed) {
          _completed = true;
        }
        _emit();
      }, onError: _onPlayerError),
      _player.positionStream.listen((_) => _emit(), onError: _onPlayerError),
      _player.durationStream.listen((_) => _emit(), onError: _onPlayerError),
    ]);
  }

  final ja.AudioPlayer _player;
  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];
  final StreamController<PlaybackState> _states =
      StreamController<PlaybackState>.broadcast();

  String? _path;
  bool _completed = false;
  bool _disposed = false;

  @override
  Stream<PlaybackState> get state => _states.stream;

  /// The most recent snapshot, for callers that need a value before the first
  /// event arrives.
  PlaybackState get current => _snapshot();

  @override
  Future<void> load(String path, {StreamInfo? info}) async {
    _ensureUsable();
    _completed = false;
    try {
      await _player.setFilePath(path);
    } on Object catch (error) {
      _path = null;
      _emit();
      throw AudioPlayerException('could not load $path', error);
    }
    _path = path;
    _emit();
  }

  @override
  Future<void> play() async {
    _ensureUsable();
    if (_path == null) {
      throw const AudioPlayerException('nothing is loaded');
    }
    // Playing again after the file ran to the end restarts it; `just_audio`
    // otherwise sits at the end and reports playing with nothing audible.
    if (_completed) {
      _completed = false;
      await _player.seek(Duration.zero);
    }
    try {
      // Deliberately not awaited: `just_audio`'s play() completes when playback
      // *finishes*, so awaiting it would hang until the end of the recording.
      unawaited(_player.play().catchError(_onPlayerError));
    } on Object catch (error) {
      throw AudioPlayerException('could not start playback', error);
    }
    _emit();
  }

  @override
  Future<void> pause() async {
    _ensureUsable();
    await _player.pause();
    _emit();
  }

  @override
  Future<void> stop() async {
    _ensureUsable();
    await _player.stop();
    _completed = false;
    // stop() keeps the source but leaves the cursor where it was; rewind so a
    // later play() starts at the beginning, which is what "stopped" means to
    // the rest of the app.
    try {
      await _player.seek(Duration.zero);
    } on Object catch (_) {
      // A platform that refuses to seek while idle still counts as stopped.
    }
    _emit();
  }

  @override
  Future<void> seek(Duration position) async {
    _ensureUsable();
    final duration = _player.duration;
    var target = position < Duration.zero ? Duration.zero : position;
    if (duration != null && target > duration) target = duration;
    _completed = false;
    await _player.seek(target);
    _emit();
  }

  @override
  Future<void> setSpeed(double speed) async {
    _ensureUsable();
    try {
      // just_audio applies this to the player, not to the item, so it
      // survives a later setFilePath -- which is the behaviour the
      // interface asks for.
      await _player.setSpeed(speed);
    } on Object catch (e) {
      throw AudioPlayerException('could not change playback speed', e);
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await _player.dispose();
    await _states.close();
  }

  void _ensureUsable() {
    if (_disposed) {
      throw const AudioPlayerException('the player has been disposed');
    }
  }

  PlaybackState _snapshot() => PlaybackState(
        isPlaying: _player.playing && !_completed,
        position: _completed
            ? (_player.duration ?? _player.position)
            : _player.position,
        duration: _player.duration,
        path: _path,
      );

  void _emit() {
    if (_disposed || _states.isClosed) return;
    _states.add(_snapshot());
  }

  /// Player errors are surfaced on the state stream rather than thrown into the
  /// zone: nothing is awaiting the platform's own streams.
  void _onPlayerError(Object error, [StackTrace? stackTrace]) {
    if (_disposed || _states.isClosed) return;
    _states.addError(AudioPlayerException('playback failed', error));
  }
}
