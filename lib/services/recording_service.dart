import 'dart:async';
import 'dart:typed_data';

import '../drivers/ble_transport.dart';
import '../drivers/file_store.dart';
import '../model/audio_codec.dart';
import '../model/audio_frame.dart';
import '../model/level_reading.dart';
import '../model/recording_metadata.dart';
import '../model/stream_info.dart';
import 'codec/frame_decoder.dart';
import 'codec/stream_decoder.dart';
import 'frame_reassembler.dart';
import 'level_meter.dart';
import 'wav_writer.dart';

/// Raised when a capture cannot be started or finished.
class RecordingException implements Exception {
  const RecordingException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() =>
      'RecordingException: $message${cause == null ? '' : ' ($cause)'}';
}

/// Orchestrates capture -> decode -> file.
///
/// Domain logic only: it talks to [BleTransport] and [FileStore] through their
/// interfaces and imports no package and no `dart:io`, which is what makes it
/// testable against a fake transport and an in-memory store.
class RecordingService {
  /// Private initializing formals keep the public parameter names
  /// (`transport:`, `fileStore:`) while assigning the private fields.
  RecordingService({
    required this._transport,
    required this._fileStore,
    DateTime Function()? clock,
    LevelMeter? levelMeter,
    this._decoders = const FrameDecoders(),
  })  : _clock = clock ?? DateTime.now,
        _levelMeter = levelMeter ?? LevelMeter();

  final BleTransport _transport;
  final FileStore _fileStore;
  final DateTime Function() _clock;

  /// Where a decoder for the stream's codec comes from. One is opened per
  /// capture and released in [stop] and [abort], because an Opus decoder
  /// holds state across frames and native memory with it.
  final FrameDecoders _decoders;

  StreamDecoder? _decoder;

  /// Measures the PCM on its way to the file. Costs one pass over bytes that
  /// are already decoded and in memory, so the live meter needs no second
  /// source of audio and no change to the device.
  final LevelMeter _levelMeter;

  final FrameReassembler _reassembler = FrameReassembler();
  final StreamController<CaptureStats> _statsController =
      StreamController<CaptureStats>.broadcast();

  StreamSubscription<Uint8List>? _frames;
  FileSink? _sink;
  String? _deviceId;
  String? _path;
  StreamInfo? _streamInfo;
  DateTime? _startedAt;
  int _decodedBytes = 0;
  Object? _streamError;

  /// Counters pushed as each notification is processed.
  Stream<CaptureStats> get stats => _statsController.stream;

  /// Peak and RMS level of each decoded block.
  Stream<LevelReading> get levels => _levelMeter.levels;

  /// The most recent level, or `null` before any audio has been decoded.
  LevelReading? get level => _levelMeter.level;

  bool get isRecording => _sink != null;

  /// Stream info read from the device for the capture in progress.
  StreamInfo? get streamInfo => _streamInfo;

  /// Latest counters, whether or not a capture is running.
  CaptureStats get currentStats =>
      _reassembler.stats.copyWith(decodedBytes: _decodedBytes);

  /// Starts capturing from [deviceId] into a WAV file at [path].
  ///
  /// When [requestCodec] is given it is written to the device's control
  /// characteristic first; the stream info is then read back, so the codec the
  /// device actually reports always wins over the one that was asked for.
  Future<void> start({
    required String deviceId,
    required String path,
    AudioCodec? requestCodec,
  }) async {
    if (isRecording) {
      throw const RecordingException('a recording is already in progress');
    }

    if (requestCodec != null) {
      await _transport.selectCodec(deviceId, requestCodec);
    }

    StreamInfo info;
    try {
      info = await _transport.readStreamInfo(deviceId);
    } on BleTransportException {
      // The reference host tool assumes 16k/16/mono when the characteristic
      // cannot be read; do the same rather than failing the capture.
      info = StreamInfo.fallback;
    }

    if (info.codec == null) {
      throw RecordingException(
        'device reported unsupported codec ${info.rawCodec}',
      );
    }
    if (info.bitsPerSample != 16) {
      throw RecordingException(
        'only 16-bit audio is supported, device reported '
        '${info.bitsPerSample}-bit',
      );
    }

    _decoder?.dispose();
    _decoder = null;
    final StreamDecoder decoder;
    try {
      decoder = _decoders.open(
        codec: info.codec!,
        sampleRateHz: info.sampleRateHz,
        channels: info.channels,
      );
    } on Object catch (e) {
      // A build without libopus, or a format libopus refuses: the same
      // refusal as an unsupported codec, and said before a file exists.
      throw RecordingException('cannot decode $info', e);
    }
    _decoder = decoder;

    _reassembler.reset();
    _levelMeter.reset();
    _decodedBytes = 0;
    _streamError = null;
    _streamInfo = info;
    _deviceId = deviceId;
    _path = path;
    _startedAt = _clock();

    final FileSink sink;
    try {
      sink = await _fileStore.openWrite(path);
    } on Object {
      // No capture started, so nothing else will close the decoder.
      decoder.dispose();
      _decoder = null;
      rethrow;
    }
    _sink = sink;

    // Provisional header; the two length fields are patched on stop().
    await sink.add(
      WavWriter.buildHeader(
        sampleRateHz: info.sampleRateHz,
        channels: info.channels,
        bitsPerSample: info.bitsPerSample,
      ),
    );

    _frames = _transport.subscribeFrames(deviceId).listen(
          _onNotification,
          onError: (Object error) => _streamError ??= error,
        );
  }

  /// Stops capture, finalises the WAV header and returns what was recorded.
  Future<RecordingMetadata> stop() async {
    final sink = _sink;
    final deviceId = _deviceId;
    final path = _path;
    final info = _streamInfo;
    final startedAt = _startedAt;

    if (sink == null ||
        deviceId == null ||
        path == null ||
        info == null ||
        startedAt == null) {
      throw const RecordingException('no recording in progress');
    }

    await _frames?.cancel();
    _frames = null;
    _sink = null;
    _deviceId = null;
    _decoder?.dispose();
    _decoder = null;

    try {
      await _transport.unsubscribeFrames(deviceId);
    } on BleTransportException {
      // The notifications have stopped either way; finish writing the file.
    }

    await sink.patch(
      WavWriter.chunkSizeOffset,
      WavWriter.chunkSizeBytes(_decodedBytes),
    );
    await sink.patch(
      WavWriter.dataSizeOffset,
      WavWriter.dataSizeBytes(_decodedBytes),
    );
    await sink.close();

    final error = _streamError;
    if (error != null) {
      _streamError = null;
      throw RecordingException('audio stream failed', error);
    }

    return RecordingMetadata(
      path: path,
      startedAt: startedAt,
      endedAt: _clock(),
      streamInfo: info,
      stats: currentStats,
    );
  }

  /// Stops without finalising, for teardown paths where the file does not
  /// matter. Never throws.
  Future<void> abort() async {
    final deviceId = _deviceId;
    await _frames?.cancel();
    _frames = null;
    if (deviceId != null) {
      try {
        await _transport.unsubscribeFrames(deviceId);
      } catch (_) {
        // Best effort.
      }
    }
    try {
      await _sink?.close();
    } catch (_) {
      // Best effort.
    }
    _sink = null;
    _deviceId = null;
    _decoder?.dispose();
    _decoder = null;
  }

  Future<void> dispose() async {
    await abort();
    await _levelMeter.dispose();
    await _statsController.close();
  }

  void _onNotification(Uint8List notification) {
    final frame = _reassembler.accept(notification);
    if (frame == null) {
      _emitStats();
      return;
    }

    final pcm = _decode(frame);
    // Measured before the write, so the meter keeps moving even if the disk
    // stalls; an empty block is ignored by the meter rather than divided by.
    _levelMeter.addPcmS16le(pcm);
    final sink = _sink;
    if (pcm.isNotEmpty && sink != null) {
      _decodedBytes += pcm.length;
      // Fire and forget: the sink serialises its own writes, and awaiting here
      // would stall the notification stream behind disk I/O. A write failure is
      // captured rather than left as an unhandled async error, and surfaces
      // from stop().
      unawaited(
        sink.add(pcm).catchError((Object error) => _streamError ??= error),
      );
    }
    _emitStats();
  }

  Uint8List _decode(AudioFrame frame) =>
      _decoder?.decode(frame) ?? Uint8List(0);

  void _emitStats() {
    if (!_statsController.isClosed) {
      _statsController.add(currentStats);
    }
  }
}
