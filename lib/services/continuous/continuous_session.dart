import 'dart:async';
import 'dart:typed_data';

import '../../drivers/ble_transport.dart';
import '../../drivers/file_store.dart';
import '../../model/audio_codec.dart';
import '../../model/capture_flags.dart';
import '../../model/stream_info.dart';
import '../codec/frame_decoder.dart';
import '../frame_reassembler.dart';
import 'note_writer.dart';

/// Raised when always-listening cannot start on a link.
class ContinuousSessionException implements Exception {
  const ContinuousSessionException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => 'ContinuousSessionException: $message'
      '${cause == null ? '' : ' ($cause)'}';
}

/// Always-listening on ONE link: the device told to stream speech only, its
/// audio decoded into notes, and the link kept alive.
///
/// Domain logic only - [BleTransport] and [FileStore] through their
/// interfaces - so it runs in tests against a fake radio and an in-memory disk.
/// A new session is made for every connection; a dropped link ends this one.
///
/// NOTHING RUNS UNLESS REQUIRED: one periodic timer, once a minute, and it
/// exists because the firmware demands it (see [keepaliveInterval]). Audio
/// work happens only when the device sends audio, which it does only while it
/// hears speech.
class ContinuousSession {
  ContinuousSession({
    required this._transport,
    required this._fileStore,
    required this._directory,
    DateTime Function()? clock,
    this.keepaliveInterval = defaultKeepaliveInterval,
  }) : _clock = clock ?? DateTime.now;

  /// THE LIVENESS CONTRACT. The firmware drops a link that has had no GATT
  /// activity from the phone for ten minutes - a phone that went away without
  /// saying so must not hold the device's only connection forever. A read of
  /// `fe08` every minute is ten times inside that and costs one small packet.
  ///
  /// The same tick closes a note that has been quiet for two minutes, so there
  /// is no second timer.
  static const Duration defaultKeepaliveInterval = Duration(seconds: 60);

  final BleTransport _transport;
  final FileStore _fileStore;
  final String _directory;
  final DateTime Function() _clock;
  final Duration keepaliveInterval;

  final FrameReassembler _reassembler = FrameReassembler();
  final StreamController<void> _changes = StreamController<void>.broadcast();
  final StreamController<NoteChange> _notes =
      StreamController<NoteChange>.broadcast();

  String? _deviceId;
  StreamInfo? _format;
  ContinuousNoteWriter? _writer;
  CaptureFlags? _flags;
  StreamSubscription<Uint8List>? _frames;
  StreamSubscription<CaptureFlags>? _capture;
  Timer? _keepalive;

  /// Every write to the note goes through this chain, in arrival order, so a
  /// slow disk delays notes rather than interleaving them.
  Future<void> _work = Future<void>.value();

  /// Fires when [flags] or [currentNotePath] changes.
  Stream<void> get changes => _changes.stream;

  /// Notes started, kept and discarded.
  Stream<NoteChange> get notes => _notes.stream;

  bool get isRunning => _deviceId != null;

  /// The device's last reported capture state; null until it has answered.
  CaptureFlags? get flags => _flags;

  /// The note being written right now, or null between notes.
  String? get currentNotePath => _writer?.currentPath;

  /// Completes once every write queued so far has landed. For tests.
  Future<void> get idle => _work;

  /// Starts always-listening on [deviceId].
  ///
  /// Throws [ContinuousSessionException] when the device will not take the
  /// command or reports audio this app cannot write; nothing is left running
  /// in that case.
  Future<void> start(String deviceId, {AudioCodec? requestCodec}) async {
    if (isRunning) {
      throw const ContinuousSessionException('already running');
    }
    try {
      if (requestCodec != null) {
        await _transport.selectCodec(deviceId, requestCodec);
      }
    } on BleTransportException catch (e) {
      throw ContinuousSessionException('could not select the codec', e);
    }
    StreamInfo format;
    try {
      format = await _transport.readStreamInfo(deviceId);
    } on BleTransportException {
      // The same fallback the manual recorder uses.
      format = StreamInfo.fallback;
    }
    if (format.codec == null || format.bitsPerSample != 16) {
      throw ContinuousSessionException('unsupported audio format: $format');
    }
    try {
      await _transport.writeCapture(deviceId, CaptureCommand.gateEnabled);
    } on BleTransportException catch (e) {
      throw ContinuousSessionException('the device refused speech-only', e);
    }

    _deviceId = deviceId;
    _format = format;
    _reassembler.reset();
    _writer = ContinuousNoteWriter(
      fileStore: _fileStore,
      directory: _directory,
      format: format,
      onChange: (change) {
        if (!_notes.isClosed) _notes.add(change);
        _notify();
      },
    );

    try {
      _onFlags(await _transport.readCapture(deviceId));
    } on BleTransportException {
      // Unknown until the first notification or keep-alive answers.
    }
    try {
      _capture = _transport.subscribeCapture(deviceId).listen(
            _onFlags,
            onError: (Object _) {},
          );
    } on BleTransportException {
      // The keep-alive read still reports the state, once a minute.
    }
    try {
      _frames = _transport.subscribeFrames(deviceId).listen(
            _onNotification,
            onError: (Object _) {},
          );
    } on BleTransportException catch (e) {
      await stop(linkUp: true);
      throw ContinuousSessionException('could not subscribe to audio', e);
    }
    _keepalive = Timer.periodic(keepaliveInterval, (_) => _keepaliveTick());
  }

  /// Ends the session: subscriptions down, the open note closed.
  ///
  /// [linkUp] says whether the device can still be talked to. When it can, it
  /// is told to stop gating, which is what a manual recording expects; the
  /// recorder's own default is the other way round, so this is a real change
  /// and not a tidy-up. Never throws.
  Future<void> stop({required bool linkUp}) async {
    final deviceId = _deviceId;
    if (deviceId == null) return;
    _deviceId = null;
    _keepalive?.cancel();
    _keepalive = null;
    await _frames?.cancel();
    _frames = null;
    await _capture?.cancel();
    _capture = null;
    if (linkUp) {
      try {
        await _transport.unsubscribeFrames(deviceId);
      } on BleTransportException {
        // Stopped either way.
      }
      try {
        await _transport.unsubscribeCapture(deviceId);
      } on BleTransportException {
        // Stopped either way.
      }
      try {
        await _transport.writeCapture(deviceId, CaptureCommand.gateDisabled);
      } on BleTransportException {
        // A manual recording asks for itself; this is only a courtesy.
      }
    }
    _enqueue((writer) => writer.finish());
    await _work;
    _writer = null;
    _flags = null;
    _notify();
  }

  Future<void> dispose() async {
    await stop(linkUp: false);
    await _changes.close();
    await _notes.close();
  }

  void _onNotification(Uint8List notification) {
    final format = _format;
    if (format == null) return;
    final frame = _reassembler.accept(notification);
    if (frame == null) return;
    final Uint8List pcm;
    try {
      pcm = FrameDecoder.decode(format.codec!, frame);
    } on Object {
      // One block this build cannot decode costs that block, not a day of
      // listening: an error thrown out of a stream listener has nowhere to go.
      return;
    }
    final arrivedAt = _clock();
    _enqueue((writer) => writer.addAudio(pcm, arrivedAt));
  }

  void _onFlags(CaptureFlags flags) {
    final wasPrivacyMode = _flags?.privacyMode ?? false;
    if (flags == _flags) return;
    _flags = flags;
    // A double tap into privacy mode is the wearer drawing a line, so the
    // note ends there rather than two minutes later.
    if (flags.privacyMode && !wasPrivacyMode) {
      _enqueue((writer) => writer.finish());
    }
    _notify();
  }

  Future<void> _keepaliveTick() async {
    final deviceId = _deviceId;
    if (deviceId == null) return;
    try {
      _onFlags(await _transport.readCapture(deviceId));
    } on BleTransportException {
      // A link that is going away reports itself on the connection stream.
    }
    final now = _clock();
    _enqueue((writer) => writer.tick(now));
  }

  void _enqueue(Future<void> Function(ContinuousNoteWriter writer) action) {
    final writer = _writer;
    if (writer == null) return;
    _work = _work.then((_) => action(writer)).catchError((Object error) {
      // A failed write loses that block, not the session: the next block may
      // well land, and the header repair pass tidies the file on next launch.
    });
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }
}
