/// One guided recording of the owner's voice, as it came off the recorder.
///
/// Pure data, handed from `AppController.stopVoiceSample` to whatever checks
/// it. The recording is never a note: it lives in `<support>/voices/`, which
/// the library never lists and Export never zips.
class VoiceSampleTake {
  const VoiceSampleTake({
    required this.path,
    required this.audio,
    required this.linkLost,
  });

  /// Where the WAV was written.
  final String path;

  /// Audio actually written, from the decoded byte count.
  final Duration audio;

  /// The recorder dropped the link, or the stream failed, before the user
  /// said Done: what is on disk is cut short and is not checked.
  final bool linkLost;

  @override
  String toString() =>
      'VoiceSampleTake($path, ${audio.inMilliseconds} ms'
      '${linkLost ? ', link lost' : ''})';
}
