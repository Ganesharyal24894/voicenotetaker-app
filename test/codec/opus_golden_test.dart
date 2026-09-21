import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/audio_frame.dart';
import 'package:voicenotetaker_app/services/codec/opus_stream_decoder.dart';

import 'opus_fixture.dart';

/// The app's real Opus path - `OpusStreamDecoder` over `NativeOpusLibrary`,
/// i.e. the vendored libopus 1.5.2 that packages/opus_native compiles - fed
/// the firmware's real bitstream. See `opus_fixture.dart` for where that comes
/// from; `opus_native_driver_test.dart` covers bad input and the lifecycle.
///
/// WHY SOME CHECKS ARE TOLERANCES. The device encodes in fixed point; the app
/// decodes in float (see packages/opus_native/hook/build.dart for why). Float
/// is not bit-exact across compilers and CPUs, so the expected PCM is the
/// fixed-point decoder's and the check is a measured bound: float and fixed
/// decodes of these packets differ by at most 1 LSB on x86-64.
void main() {
  late OpusFixture fx;
  late List<Uint8List> packets;
  const library = OpusFixture.library;

  setUpAll(() {
    fx = OpusFixture.load();
    packets = fx.packets;
  });

  Int16List decodeStream({Set<int> lost = const {}, int? upTo}) =>
      fx.decodeStream(lost: lost, upTo: upTo);

  test('the loaded libopus is the vendored float 1.5.2, not the host one', () {
    // The host has a system libopus 1.4; a test passing against that would
    // say nothing about what the phone runs.
    expect(library.version, 'libopus 1.5.2');
  });

  group('the device bitstream', () {
    test('is the stream the silicon measured: 20,649 bps, 45-61 B', () {
      final stream = fx.json['stream'] as Map<String, dynamic>;
      final lengths = packets.map((p) => p.length).toList();
      final total = lengths.reduce((a, b) => a + b);
      expect(packets, hasLength(250));
      expect(total, stream['total_bytes']);
      expect(total, 12906);
      expect(lengths.reduce(math.min), 45);
      expect(lengths.reduce(math.max), 61);
      // 12,906 bytes over 5 s.
      expect(total * 8 / 5, closeTo(20649.6, 1e-9));
    });

    test('is CELT-only 20 ms mono in every packet (TOC 0xb8)', () {
      // Config 23: CELT, fullband, 20 ms; mono; one frame. A SILK or hybrid
      // TOC here would mean RESTRICTED_LOWDELAY was not what ran.
      expect(packets.map((p) => p.first).toSet(), {0xb8});
    });
  });

  group('decoding', () {
    test('every packet decodes to exactly 320 samples', () {
      final decoder = OpusStreamDecoder(library: library);
      addTearDown(decoder.dispose);
      for (var i = 0; i < packets.length; i++) {
        final pcm = decoder.decode(
          AudioFrame(sequence: i, payload: packets[i], droppedBefore: 0),
        );
        expect(pcm, hasLength(640), reason: 'packet $i');
      }
    });

    test('matches the reference decode to within 1 LSB, sample for sample', () {
      final decoded = fx.json['decoded'] as Map<String, dynamic>;
      final head = samples(base64Decode(decoded['head_pcm_b64'] as String));
      final ours = decodeStream(upTo: decoded['head_frames'] as int);
      expect(ours, hasLength(head.length));
      var worst = 0;
      for (var i = 0; i < head.length; i++) {
        worst = math.max(worst, (ours[i] - head[i]).abs());
      }
      expect(worst, lessThanOrEqualTo(1));
    });

    test('every one of the 250 frames has the reference energy', () {
      final expected = (fx.json['decoded']['frame_rms'] as List).cast<num>();
      final ours = decodeStream();
      expect(ours, hasLength(250 * 320));
      for (var f = 0; f < 250; f++) {
        expect(
          rms(ours, f * 320, (f + 1) * 320),
          closeTo(expected[f].toDouble(), 0.05 * expected[f] + 1),
          reason: 'frame $f',
        );
      }
    });

    test('two streams decoded interleaved do not contaminate each other', () {
      // Isolation, not just repeatability: both decoders open at once and fed
      // alternately, each must still match its own solo decode exactly.
      final solo = decodeStream(upTo: 40);
      final a = OpusStreamDecoder(library: library);
      final b = OpusStreamDecoder(library: library);
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      final outA = BytesBuilder(copy: false);
      final outB = BytesBuilder(copy: false);
      for (var i = 0; i < 40; i++) {
        outA.add(
          a.decode(
            AudioFrame(sequence: i, payload: packets[i], droppedBefore: 0),
          ),
        );
        // b runs the stream from its far end, so its state differs throughout.
        final j = 249 - i;
        outB.add(
          b.decode(
            AudioFrame(sequence: i, payload: packets[j], droppedBefore: 0),
          ),
        );
      }
      expect(samples(outA.toBytes()), solo);
    });
  });

  group('packet loss concealment', () {
    // Frame 60 is the fixture's chosen loss: real speech, above the median
    // frame energy. The fixed-point decoder conceals it at 5.40 RMS against
    // a true 182.25 - near silence - which is why the app decodes in float.
    late Map<String, dynamic> plc;
    late List<double> trueRms;

    setUpAll(() {
      plc = fx.json['plc'] as Map<String, dynamic>;
      trueRms = [
        for (final r in fx.json['decoded']['frame_rms'] as List)
          (r as num).toDouble(),
      ];
    });

    test(
      'a lost packet is replaced by a frame, so the note keeps its length',
      () {
        final lost = plc['lost'] as int;
        expect(decodeStream(lost: {lost}), hasLength(250 * 320));
      },
    );

    test('the concealed frame carries speech energy, not silence', () {
      final lost = plc['lost'] as int;
      final ours = decodeStream(lost: {lost});
      final ratio = rms(ours, lost * 320, (lost + 1) * 320) / trueRms[lost];
      // Float 1.5.2 on x86-64: 0.835. Fixed point: 0.030. The bar sits well
      // between the two, so it catches a decoder that conceals with silence.
      expect(ratio, greaterThan(0.5));
      expect(ratio, lessThan(1.5));
    });

    test('three losses in a row fade rather than drop out', () {
      final lost = plc['lost'] as int;
      final ours = decodeStream(lost: {lost, lost + 1, lost + 2});
      final ratios = [
        for (var f = lost; f < lost + 3; f++)
          rms(ours, f * 320, (f + 1) * 320) / trueRms[f],
      ];
      // Float: 0.84, 0.57, 0.39. Fixed point: 0.03, 0.00, 0.00.
      for (final r in ratios) {
        expect(r, greaterThan(0.2), reason: '$ratios');
      }
      expect(ratios.first, greaterThan(ratios.last), reason: '$ratios');
    });

    test('the stream recovers after the gap', () {
      final lost = plc['lost'] as int;
      final ours = decodeStream(lost: {lost});
      // Within 15 % of the lossless energy by the fifth frame after; float
      // measured 1.4 % off at lost+5.
      final f = lost + 5;
      expect(
        rms(ours, f * 320, (f + 1) * 320),
        closeTo(trueRms[f], 0.15 * trueRms[f]),
      );
    });

    test('no single loss anywhere in the 5 s conceals as near-silence', () {
      // The fixture's own scan of the same thing: float 0 of 230 positions
      // below 0.1 of the true energy, fixed point 84 of 230. This runs the
      // whole scan through the app's decoder.
      final quiet = <int>[];
      for (var k = 10; k < 240; k++) {
        // Up to the packet AFTER the loss: the gap is only known, and
        // concealed, when the next packet arrives with a skipped sequence.
        final ours = decodeStream(lost: {k}, upTo: k + 2);
        if (rms(ours, k * 320, (k + 1) * 320) < 0.1 * trueRms[k]) quiet.add(k);
      }
      expect(quiet, isEmpty);
    });
  });
}
