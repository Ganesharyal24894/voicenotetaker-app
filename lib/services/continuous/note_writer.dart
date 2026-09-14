import 'dart:async';
import 'dart:typed_data';

import '../../drivers/file_store.dart';
import '../../model/stream_info.dart';
import '../library_service.dart';
import '../wav_writer.dart';

/// What happened to a note.
enum NoteChangeKind {
  /// A new file was opened and is being written.
  started,

  /// The note was closed and kept.
  finished,

  /// The note was closed with too little speech in it and deleted.
  discarded,
}

class NoteChange {
  const NoteChange(this.kind, this.path);

  final NoteChangeKind kind;
  final String path;

  @override
  String toString() => 'NoteChange(${kind.name}, $path)';
}

/// Turns the speech-only stream of always-listening into notes on disk.
///
/// PURE DOMAIN LOGIC. It is handed decoded PCM with the time each block
/// arrived, and reaches the disk only through [FileStore]; no timer, no radio.
/// The session calls [tick] from its keep-alive, which is what closes a note
/// that has gone quiet.
///
/// THE NOTES ARE ORDINARY RECORDINGS: the same folder, the same
/// `voicenote-YYYYMMDD-HHMMSS.wav` name (the time the first speech arrived)
/// and the same 44-byte header, so the library, playback and transcription
/// take them unchanged.
///
/// Not safe for overlapping calls - each method must complete before the next
/// starts. `ContinuousSession` serialises them.
class ContinuousNoteWriter {
  ContinuousNoteWriter({
    required this._fileStore,
    required this._directory,
    required this._format,
    this._onChange,
  });

  /// A note ends after this long with no audio, and the next speech starts a
  /// new one.
  ///
  /// TWO MINUTES. The firmware already cuts the silence out, so this is not
  /// about file size; it is about what a "note" is. Pauses inside a
  /// conversation or while thinking run to tens of seconds, and a split there
  /// scatters one thought over several notes. Much longer, and separate
  /// conversations run together. Omi, the nearest shipped product, defaults
  /// to the same 120 s.
  static const Duration newNoteAfter = Duration(minutes: 2);

  /// A pause at least this long gets [insertedGap] of silence in the file.
  ///
  /// One second, because shorter holes are the radio: notifications arrive in
  /// bursts, tens of milliseconds apart, and padding those would stretch the
  /// speech itself.
  ///
  /// ARRIVAL TIMES DECIDE ONLY WHERE PAUSES ARE, NEVER HOW LONG AUDIO IS. When
  /// the gate opens the device flushes its 500 ms pre-roll at about three
  /// times real time, so arrivals at the start of speech are compressed.
  /// Lengths - the two-second minimum, the hour - are counted in samples.
  static const Duration gapThreshold = Duration(seconds: 1);

  /// The silence written in place of a pause, however long it really was.
  ///
  /// The firmware removes silence; writing a minute of zeroes back in would
  /// make the note tedious to listen to, and writing nothing runs the end of
  /// one sentence into the start of the next with no breath between them.
  /// 300 ms reads as a natural pause and costs 9.6 KB.
  static const Duration insertedGap = Duration(milliseconds: 300);

  /// A note that reaches this length is closed and the next audio starts a
  /// new one, so one long meeting is not one unplayable, untranscribable file.
  static const Duration maxNoteLength = Duration(minutes: 60);

  /// A note with less speech than this is deleted when it closes. A cough, a
  /// door, a word said to nobody - not worth a row in the library or a
  /// transcription.
  static const Duration minSpeech = Duration(seconds: 2);

  /// How much audio may be appended before the header's lengths are brought up
  /// to date again. The app can be killed at any moment, so the header is
  /// never more than this far behind the file; the startup repair pass in
  /// `WavRepair` covers the rest.
  static const Duration headerRefresh = Duration(seconds: 5);

  final FileStore _fileStore;
  final String _directory;
  final StreamInfo _format;
  final void Function(NoteChange change)? _onChange;

  FileSink? _sink;
  String? _path;
  DateTime? _lastAudioAt;

  /// Payload bytes in the open note, inserted gaps included.
  int _payloadBytes = 0;

  /// Payload bytes that were real audio from the device.
  int _speechBytes = 0;

  /// [_payloadBytes] as of the last header patch.
  int _patchedBytes = 0;

  /// The note being written, or null between notes.
  String? get currentPath => _path;

  bool get isWriting => _sink != null;

  int get _blockAlign => _format.channels * (_format.bitsPerSample ~/ 8);

  /// Bytes of audio in [duration], whole samples only.
  int _bytesFor(Duration duration) {
    final bytesPerSecond = _format.sampleRateHz * _blockAlign;
    final raw = duration.inMicroseconds * bytesPerSecond ~/
        Duration.microsecondsPerSecond;
    return raw - raw % _blockAlign;
  }

  /// Appends one decoded block that arrived at [arrivedAt].
  Future<void> addAudio(Uint8List pcm, DateTime arrivedAt) async {
    if (pcm.isEmpty) return;
    final last = _lastAudioAt;
    if (_sink != null && last != null) {
      final gap = arrivedAt.difference(last);
      if (gap >= newNoteAfter ||
          _payloadBytes + pcm.length > _bytesFor(maxNoteLength)) {
        await finish();
      } else if (gap >= gapThreshold) {
        await _append(Uint8List(_bytesFor(insertedGap)), speech: false);
      }
    }
    if (_sink == null) await _open(arrivedAt);
    await _append(pcm, speech: true);
    _lastAudioAt = arrivedAt;
    if (_payloadBytes - _patchedBytes >= _bytesFor(headerRefresh)) {
      await _patchHeader();
    }
  }

  /// Closes the open note if nothing has arrived for [newNoteAfter].
  Future<void> tick(DateTime now) async {
    final last = _lastAudioAt;
    if (_sink == null || last == null) return;
    if (now.difference(last) >= newNoteAfter) await finish();
  }

  /// Closes the open note now: header final, file closed, and deleted if it
  /// holds less than [minSpeech]. Does nothing between notes.
  Future<void> finish() async {
    final sink = _sink;
    final path = _path;
    if (sink == null || path == null) return;
    _sink = null;
    _path = null;
    _lastAudioAt = null;
    final kept = _speechBytes >= _bytesFor(minSpeech);
    try {
      await sink.patch(
        WavWriter.chunkSizeOffset,
        WavWriter.chunkSizeBytes(_payloadBytes),
      );
      await sink.patch(
        WavWriter.dataSizeOffset,
        WavWriter.dataSizeBytes(_payloadBytes),
      );
    } finally {
      await sink.close();
      _payloadBytes = 0;
      _speechBytes = 0;
      _patchedBytes = 0;
    }
    if (kept) {
      _onChange?.call(NoteChange(NoteChangeKind.finished, path));
    } else {
      await _fileStore.delete(path);
      _onChange?.call(NoteChange(NoteChangeKind.discarded, path));
    }
  }

  Future<void> _open(DateTime startedAt) async {
    var when = startedAt;
    var path = _pathFor(when);
    // Two notes cannot normally start in the same second - one would have to
    // be discarded and the next begin at once - but a name that is taken must
    // never be truncated.
    while (await _fileStore.exists(path)) {
      when = when.add(const Duration(seconds: 1));
      path = _pathFor(when);
    }
    final sink = await _fileStore.openWrite(path);
    _sink = sink;
    _path = path;
    _payloadBytes = 0;
    _speechBytes = 0;
    _patchedBytes = 0;
    await sink.add(
      WavWriter.buildHeader(
        sampleRateHz: _format.sampleRateHz,
        channels: _format.channels,
        bitsPerSample: _format.bitsPerSample,
      ),
    );
    _onChange?.call(NoteChange(NoteChangeKind.started, path));
  }

  String _pathFor(DateTime when) =>
      _fileStore.join(_directory, RecordingNaming.fileName(when));

  Future<void> _append(Uint8List bytes, {required bool speech}) async {
    final sink = _sink;
    if (sink == null) return;
    await sink.add(bytes);
    _payloadBytes += bytes.length;
    if (speech) _speechBytes += bytes.length;
  }

  Future<void> _patchHeader() async {
    final sink = _sink;
    if (sink == null) return;
    await sink.patch(
      WavWriter.chunkSizeOffset,
      WavWriter.chunkSizeBytes(_payloadBytes),
    );
    await sink.patch(
      WavWriter.dataSizeOffset,
      WavWriter.dataSizeBytes(_payloadBytes),
    );
    _patchedBytes = _payloadBytes;
  }
}
