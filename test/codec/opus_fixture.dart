import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:voicenotetaker_app/drivers/opus_library_native.dart';
import 'package:voicenotetaker_app/model/audio_frame.dart';
import 'package:voicenotetaker_app/services/codec/opus_stream_decoder.dart';

/// `test/fixtures/opus_vectors.json`, and the few ways the Opus tests read it.
///
/// WHERE THE PACKETS COME FROM. The fixture is generated outside git by
/// `notetaker-data/opus-golden/make_app_fixture.c` + `add_float_decoder.py`:
/// a fixed-point libopus 1.5.2 built from EXACTLY the firmware's file list and
/// defines (voiceNotetaker/lib/opus), configured with EXACTLY the firmware's
/// CTLs in opus_codec.c's order, encoding exactly the 5 s of voicenote.wav that
/// the silicon bench encoded. Its stream reproduces the silicon's measured
/// 20,649 bps / 51.62 B per frame / 45-61 B exactly - so these are the bytes
/// the device sends, not bytes that merely look like them.
class OpusFixture {
  OpusFixture.load()
    : json = jsonDecode(
        File('test/fixtures/opus_vectors.json').readAsStringSync(),
      ) as Map<String, dynamic> {
    final stream = json['stream'] as Map<String, dynamic>;
    packets = [
      for (final p in stream['packets_b64'] as List) base64Decode(p as String),
    ];
  }

  final Map<String, dynamic> json;
  late final List<Uint8List> packets;

  /// The app's real decoder: `OpusStreamDecoder` over the vendored libopus.
  static const NativeOpusLibrary library = NativeOpusLibrary();

  /// One stream through the app's decoder: every packet a notification,
  /// with the ones in [lost] never arriving - which the app learns from the
  /// next packet's sequence gap, exactly as `FrameReassembler` reports it.
  Int16List decodeStream({Set<int> lost = const {}, int? upTo}) {
    final decoder = OpusStreamDecoder(library: library);
    final out = BytesBuilder(copy: false);
    var dropped = 0;
    final last = upTo ?? packets.length;
    for (var i = 0; i < last; i++) {
      if (lost.contains(i)) {
        dropped++;
        continue;
      }
      out.add(
        decoder.decode(
          AudioFrame(sequence: i, payload: packets[i], droppedBefore: dropped),
        ),
      );
      dropped = 0;
    }
    decoder.dispose();
    return samples(out.toBytes());
  }
}

/// s16le bytes back to samples.
Int16List samples(Uint8List pcm) {
  final view = ByteData.sublistView(pcm);
  return Int16List.fromList([
    for (var i = 0; i < pcm.length; i += 2) view.getInt16(i, Endian.little),
  ]);
}

/// RMS of [s] over [start, end).
double rms(Int16List s, [int start = 0, int? end]) {
  end ??= s.length;
  var sum = 0.0;
  for (var i = start; i < end; i++) {
    sum += s[i] * s[i];
  }
  return math.sqrt(sum / (end - start));
}
