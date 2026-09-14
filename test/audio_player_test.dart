import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/controller/app_controller.dart';
import 'package:voicenotetaker_app/drivers/audio_player.dart';
import 'package:voicenotetaker_app/drivers/ble_transport.dart';
import 'package:voicenotetaker_app/drivers/file_store.dart';
import 'package:voicenotetaker_app/model/audio_codec.dart';
import 'package:voicenotetaker_app/model/device_state.dart';
import 'package:voicenotetaker_app/model/recording_info.dart';
import 'package:voicenotetaker_app/model/stream_info.dart';

/// These tests are about the STATE MACHINE the [AudioPlayer] interface
/// describes - what load / play / pause / seek / stop / completion do to the
/// snapshot the app renders - and about the controller that drives it. They do
/// not test `just_audio`: that package has its own suite, it needs a platform
/// channel and an audio device, and testing it here would only assert that
/// somebody else's code still works.
///
/// [FakeAudioPlayer] is the contract written out as a machine. Any
/// implementation added next to `audio_player.dart` - the `just_audio` one
/// included - is expected to behave like this.
class FakeAudioPlayer implements AudioPlayer {
  FakeAudioPlayer({this.durations = const <String, Duration>{}});

  /// Length reported for each loadable path. A path that is not here fails to
  /// load, the way a missing or corrupt file does.
  final Map<String, Duration> durations;

  final StreamController<PlaybackState> _states =
      StreamController<PlaybackState>.broadcast();

  final List<String> calls = <String>[];

  String? _path;
  Duration? _duration;
  Duration _position = Duration.zero;
  bool _playing = false;
  bool _completed = false;
  bool _disposed = false;

  @override
  Stream<PlaybackState> get state => _states.stream;

  PlaybackState get snapshot => PlaybackState(
        isPlaying: _playing,
        position: _position,
        duration: _duration,
        path: _path,
      );

  @override
  Future<void> load(String path, {StreamInfo? info}) async {
    _check();
    calls.add('load($path)');
    final duration = durations[path];
    if (duration == null) {
      _path = null;
      _duration = null;
      throw AudioPlayerException('could not load $path');
    }
    _path = path;
    _duration = duration;
    _position = Duration.zero;
    _playing = false;
    _completed = false;
    _emit();
  }

  @override
  Future<void> play() async {
    _check();
    calls.add('play');
    if (_path == null) throw const AudioPlayerException('nothing is loaded');
    if (_completed) {
      _completed = false;
      _position = Duration.zero;
    }
    _playing = true;
    _emit();
  }

  @override
  Future<void> pause() async {
    _check();
    calls.add('pause');
    _playing = false;
    _emit();
  }

  @override
  Future<void> stop() async {
    _check();
    calls.add('stop');
    _playing = false;
    _completed = false;
    _position = Duration.zero;
    _emit();
  }

  /// Recorded so tests can assert the rate really reached the driver --
  /// the chip used to cycle a label and stop there.
  double speed = 1.0;

  @override
  Future<void> setSpeed(double value) async {
    _check();
    speed = value;
    calls.add('setSpeed($value)');
  }

  @override
  Future<void> seek(Duration position) async {
    _check();
    calls.add('seek($position)');
    final limit = _duration ?? Duration.zero;
    var target = position < Duration.zero ? Duration.zero : position;
    if (target > limit) target = limit;
    _position = target;
    _completed = false;
    _emit();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    calls.add('dispose');
    await _states.close();
  }

  /// Runs the clock forward, as the platform's position stream would.
  void advance(Duration by) {
    if (!_playing) return;
    final limit = _duration ?? Duration.zero;
    _position += by;
    if (_position >= limit) {
      _position = limit;
      _playing = false;
      _completed = true;
    }
    _emit();
  }

  void _check() {
    if (_disposed) {
      throw const AudioPlayerException('the player has been disposed');
    }
  }

  void _emit() {
    if (!_states.isClosed) _states.add(snapshot);
  }
}

class MockBleTransport extends Mock implements BleTransport {}

/// Enough of a store for the controller to build; the library is empty.
class EmptyFileStore implements FileStore {
  @override
  Future<FileSink> openWrite(String path) async => throw UnimplementedError();

  @override
  Future<Uint8List> read(String path) async => Uint8List(0);

  @override
  Future<Uint8List> readRange(String path, int start, int end) async =>
      Uint8List(0);

  @override
  Future<FileInfo?> stat(String path) async => null;

  @override
  Future<void> writeBytes(String path, List<int> bytes) async {}

  @override
  Future<void> patchBytes(String path, int offset, List<int> bytes) async {}

  @override
  Future<bool> exists(String path) async => false;

  @override
  Future<void> delete(String path) async {}

  @override
  Future<List<String>> list(String directory) async => const <String>[];

  @override
  String join(String directory, String name) => '$directory/$name';
}

const String path1 = '/documents/recordings/voicenote-20260910-091400.wav';
const String path2 = '/documents/recordings/voicenote-20260910-101500.wav';

RecordingInfo infoFor(String path, Duration duration) => RecordingInfo(
      path: path,
      name: path.split('/').last,
      recordedAt: DateTime(2026, 9, 10, 9, 14),
      sizeBytes: 44 + duration.inMilliseconds * 32,
      duration: duration,
    );

void main() {
  setUpAll(() => registerFallbackValue(AudioCodec.imaAdpcm));

  group('the state machine an AudioPlayer must implement', () {
    late FakeAudioPlayer player;

    setUp(() {
      player = FakeAudioPlayer(
        durations: const <String, Duration>{
          path1: Duration(minutes: 4, seconds: 12),
          path2: Duration(seconds: 30),
        },
      );
    });

    tearDown(() async => player.dispose());

    test('starts with nothing loaded', () {
      expect(player.snapshot.path, isNull);
      expect(player.snapshot.isPlaying, isFalse);
      expect(player.snapshot.position, Duration.zero);
      expect(PlaybackState.idle.isPlaying, isFalse);
      expect(PlaybackState.idle.position, Duration.zero);
      expect(PlaybackState.idle.duration, isNull);
    });

    test('load publishes the file, its length and a zero position', () async {
      final states = <PlaybackState>[];
      final subscription = player.state.listen(states.add);

      await player.load(path1);
      await Future<void>.delayed(Duration.zero);

      expect(states.single.path, path1);
      expect(states.single.duration, const Duration(minutes: 4, seconds: 12));
      expect(states.single.position, Duration.zero);
      expect(states.single.isPlaying, isFalse);

      await subscription.cancel();
    });

    test('play, pause and resume move only the playing flag', () async {
      await player.load(path1);
      await player.play();
      expect(player.snapshot.isPlaying, isTrue);

      player.advance(const Duration(seconds: 5));
      await player.pause();
      expect(player.snapshot.isPlaying, isFalse);
      expect(player.snapshot.position, const Duration(seconds: 5));

      await player.play();
      expect(player.snapshot.isPlaying, isTrue);
      expect(player.snapshot.position, const Duration(seconds: 5));
    });

    test('a paused player does not advance', () async {
      await player.load(path1);
      await player.play();
      player.advance(const Duration(seconds: 3));
      await player.pause();
      player.advance(const Duration(seconds: 30));

      expect(player.snapshot.position, const Duration(seconds: 3));
    });

    test('seek moves the position and is clamped at both ends', () async {
      await player.load(path2); // 30 s.

      await player.seek(const Duration(seconds: 10));
      expect(player.snapshot.position, const Duration(seconds: 10));

      await player.seek(const Duration(seconds: -5));
      expect(player.snapshot.position, Duration.zero);

      await player.seek(const Duration(minutes: 9));
      expect(player.snapshot.position, const Duration(seconds: 30));
    });

    test('stop rewinds, so the next play starts at the beginning', () async {
      await player.load(path2);
      await player.play();
      player.advance(const Duration(seconds: 12));

      await player.stop();
      expect(player.snapshot.isPlaying, isFalse);
      expect(player.snapshot.position, Duration.zero);

      await player.play();
      expect(player.snapshot.position, Duration.zero);
      expect(player.snapshot.isPlaying, isTrue);
    });

    test('reaching the end stops playing and pins the position', () async {
      final states = <PlaybackState>[];
      final subscription = player.state.listen(states.add);

      await player.load(path2);
      await player.play();
      player.advance(const Duration(seconds: 45));
      await Future<void>.delayed(Duration.zero);

      expect(player.snapshot.isPlaying, isFalse);
      expect(player.snapshot.position, const Duration(seconds: 30));
      expect(states.last.isPlaying, isFalse);
      expect(states.last.position, const Duration(seconds: 30));

      await subscription.cancel();
    });

    test('playing again after the end restarts the file', () async {
      await player.load(path2);
      await player.play();
      player.advance(const Duration(seconds: 30));

      await player.play();
      expect(player.snapshot.position, Duration.zero);
      expect(player.snapshot.isPlaying, isTrue);
    });

    test('loading another file replaces the whole snapshot', () async {
      await player.load(path1);
      await player.play();
      player.advance(const Duration(seconds: 20));

      await player.load(path2);
      expect(player.snapshot.path, path2);
      expect(player.snapshot.position, Duration.zero);
      expect(player.snapshot.duration, const Duration(seconds: 30));
      expect(player.snapshot.isPlaying, isFalse);
    });

    test('playing with nothing loaded is an AudioPlayerException', () async {
      await expectLater(player.play, throwsA(isA<AudioPlayerException>()));
    });

    test('a file that will not load throws and loads nothing', () async {
      await expectLater(
        () => player.load('/documents/recordings/gone.wav'),
        throwsA(isA<AudioPlayerException>()),
      );
      expect(player.snapshot.path, isNull);
    });

    test('a disposed player refuses further work', () async {
      await player.load(path1);
      await player.dispose();

      await expectLater(player.play, throwsA(isA<AudioPlayerException>()));
      expect(player.calls, contains('dispose'));
    });

    test('AudioPlayerException carries its cause into toString', () {
      const failure = AudioPlayerException('could not load', 'ENOENT');
      expect(failure.message, 'could not load');
      expect(failure.cause, 'ENOENT');
      expect('$failure', contains('could not load'));
      expect('$failure', contains('ENOENT'));
    });

    test('PlaybackState describes itself for the developer screen', () {
      const state = PlaybackState(
        isPlaying: true,
        position: Duration(seconds: 5),
        duration: Duration(seconds: 30),
        path: path1,
      );
      expect('$state', contains('playing: true'));
      expect('$state', contains(path1));
    });
  });

  group('the controller drives the player', () {
    late FakeAudioPlayer player;
    late MockBleTransport transport;
    late AppController controller;

    setUp(() async {
      player = FakeAudioPlayer(
        durations: const <String, Duration>{
          path1: Duration(minutes: 4, seconds: 12),
          path2: Duration(seconds: 30),
        },
      );
      transport = MockBleTransport();
      when(() => transport.currentAvailability())
          .thenAnswer((_) async => BleAvailability.poweredOn);
      when(() => transport.availability)
          .thenAnswer((_) => const Stream<BleAvailability>.empty());
      when(() => transport.dispose()).thenAnswer((_) async {});

      controller = AppController(
        transport: transport,
        fileStore: EmptyFileStore(),
        audioPlayer: player,
        recordingsDirectory: '/documents/recordings',
      );
      await controller.initialise();
    });

    tearDown(() async => controller.teardown());

    test('playRecording loads, plays and publishes the state', () async {
      final recording =
          infoFor(path1, const Duration(minutes: 4, seconds: 12));
      await controller.playRecording(recording);
      await Future<void>.delayed(Duration.zero);

      // setSpeed sits between them on purpose: the rate is re-applied after
      // every load so opening another note cannot silently reset it.
      expect(
        player.calls,
        <String>['load($path1)', 'setSpeed(1.0)', 'play'],
      );
      expect(controller.nowPlaying, recording);
      expect(controller.isPlaying, isTrue);
      expect(
        controller.playbackState.duration,
        const Duration(minutes: 4, seconds: 12),
      );
      expect(controller.playbackError, isNull);
    });

    test('resuming the same recording does not reload it', () async {
      final recording =
          infoFor(path1, const Duration(minutes: 4, seconds: 12));
      await controller.playRecording(recording);
      await controller.pausePlayback();
      await controller.playRecording(recording);

      expect(
        player.calls.where((c) => c.startsWith('load')).length,
        1,
      );
      expect(controller.isPlaying, isTrue);
    });

    test('opening a different recording loads the new one', () async {
      await controller
          .playRecording(infoFor(path1, const Duration(minutes: 4)));
      await controller
          .playRecording(infoFor(path2, const Duration(seconds: 30)));

      expect(player.calls.where((c) => c.startsWith('load')).length, 2);
      expect(controller.nowPlaying!.path, path2);
    });

    test('toggle plays then pauses the same recording', () async {
      final recording = infoFor(path2, const Duration(seconds: 30));

      await controller.togglePlayback(recording);
      await Future<void>.delayed(Duration.zero);
      expect(controller.isPlaying, isTrue);

      await controller.togglePlayback(recording);
      await Future<void>.delayed(Duration.zero);
      expect(controller.isPlaying, isFalse);
    });

    test('position updates from the driver reach the controller', () async {
      await controller
          .playRecording(infoFor(path2, const Duration(seconds: 30)));
      player.advance(const Duration(seconds: 7));
      await Future<void>.delayed(Duration.zero);

      expect(controller.playbackState.position, const Duration(seconds: 7));
    });

    test('completion leaves the controller not playing', () async {
      await controller
          .playRecording(infoFor(path2, const Duration(seconds: 30)));
      player.advance(const Duration(seconds: 31));
      await Future<void>.delayed(Duration.zero);

      expect(controller.isPlaying, isFalse);
      expect(controller.playbackState.position, const Duration(seconds: 30));
    });

    test('seekPlayback forwards to the driver and clamps below zero', () async {
      await controller
          .playRecording(infoFor(path2, const Duration(seconds: 30)));

      await controller.seekPlayback(const Duration(seconds: 12));
      expect(controller.playbackState.position, const Duration(seconds: 12));

      await controller.seekPlayback(const Duration(seconds: -30));
      expect(controller.playbackState.position, Duration.zero);
    });

    test('seeking with nothing loaded does nothing', () async {
      await controller.seekPlayback(const Duration(seconds: 5));
      expect(player.calls, isEmpty);
    });

    test('stopPlayback rewinds and stops', () async {
      await controller
          .playRecording(infoFor(path2, const Duration(seconds: 30)));
      player.advance(const Duration(seconds: 9));

      await controller.stopPlayback();
      await Future<void>.delayed(Duration.zero);

      expect(controller.isPlaying, isFalse);
      expect(controller.playbackState.position, Duration.zero);
    });

    test('a file that will not load is reported, not thrown', () async {
      await controller.playRecording(
        infoFor('/documents/recordings/gone.wav', const Duration(seconds: 5)),
      );

      expect(controller.playbackError, isNotNull);
      expect(controller.nowPlaying, isNull);
      expect(controller.isPlaying, isFalse);
    });

    test('a later successful play clears the error', () async {
      await controller.playRecording(
        infoFor('/documents/recordings/gone.wav', const Duration(seconds: 5)),
      );
      await controller
          .playRecording(infoFor(path2, const Duration(seconds: 30)));

      expect(controller.playbackError, isNull);
    });

    test('deleting what is playing stops playback first', () async {
      final recording = infoFor(path2, const Duration(seconds: 30));
      await controller.playRecording(recording);

      await controller.deleteRecording(recording);
      await Future<void>.delayed(Duration.zero);

      expect(player.calls, contains('stop'));
      expect(controller.isPlaying, isFalse);
    });

    test('every listener is notified as playback moves', () async {
      var notifications = 0;
      controller.addListener(() => notifications++);

      await controller
          .playRecording(infoFor(path2, const Duration(seconds: 30)));
      player.advance(const Duration(seconds: 1));
      await Future<void>.delayed(Duration.zero);

      expect(notifications, greaterThan(0));
    });

    test('teardown disposes the player', () async {
      await controller.teardown();
      expect(player.calls, contains('dispose'));
    });
  });

  group('an app built without a playback driver', () {
    late AppController controller;
    late MockBleTransport transport;

    setUp(() async {
      transport = MockBleTransport();
      when(() => transport.currentAvailability())
          .thenAnswer((_) async => BleAvailability.poweredOn);
      when(() => transport.availability)
          .thenAnswer((_) => const Stream<BleAvailability>.empty());
      when(() => transport.dispose()).thenAnswer((_) async {});

      controller = AppController(
        transport: transport,
        fileStore: EmptyFileStore(),
        recordingsDirectory: '/documents/recordings',
      );
      await controller.initialise();
    });

    tearDown(() async => controller.teardown());

    test('says so, and every transport call is a no-op', () async {
      expect(controller.canPlay, isFalse);

      await controller
          .playRecording(infoFor(path1, const Duration(seconds: 5)));
      await controller.pausePlayback();
      await controller.stopPlayback();
      await controller.seekPlayback(const Duration(seconds: 1));

      expect(controller.isPlaying, isFalse);
      expect(controller.nowPlaying, isNull);
      expect(controller.playbackState.path, isNull);
    });
  });
}
