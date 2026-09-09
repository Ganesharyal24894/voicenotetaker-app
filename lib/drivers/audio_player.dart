import '../model/stream_info.dart';

/// Playback position/'`is playing`' snapshot pushed by an [AudioPlayer].
class PlaybackState {
  const PlaybackState({
    required this.isPlaying,
    required this.position,
    this.duration,
    this.path,
  });

  static const PlaybackState idle =
      PlaybackState(isPlaying: false, position: Duration.zero);

  final bool isPlaying;
  final Duration position;
  final Duration? duration;

  /// File currently loaded, if any.
  final String? path;

  @override
  String toString() => 'PlaybackState(playing: $isPlaying, '
      'position: $position, duration: $duration, path: $path)';
}

/// Playback of a recorded file.
///
/// Interface only, by design: no playback package has been chosen yet, so
/// nothing outside `lib/drivers/` may assume one. When an implementation lands
/// it goes next to this file (e.g. `audio_player_just_audio.dart`) and nothing
/// else has to change.
abstract class AudioPlayer {
  /// Position and playing/stopped transitions.
  Stream<PlaybackState> get state;

  /// Loads [path]. [info] describes the PCM when the file carries no header;
  /// for a WAV file it may be ignored.
  Future<void> load(String path, {StreamInfo? info});

  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);

  /// Releases platform resources. The player is unusable afterwards.
  Future<void> dispose();
}

/// Failure raised by an [AudioPlayer] implementation.
class AudioPlayerException implements Exception {
  const AudioPlayerException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() =>
      'AudioPlayerException: $message${cause == null ? '' : ' ($cause)'}';
}
