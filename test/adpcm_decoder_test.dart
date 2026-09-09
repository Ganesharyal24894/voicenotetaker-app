import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/services/codec/adpcm_decoder.dart';

/// THE test that matters most.
///
/// The golden vectors in `test/fixtures/adpcm_vectors.json` are produced by the
/// firmware's own Python reference decoder (`host/adpcm.py`) via
/// `tool/generate_adpcm_fixtures.py`. A codec mismatch between device and app
/// does not fail loudly - it degrades audio silently - so the Dart port is
/// asserted to reproduce the reference output EXACTLY, sample for sample.
void main() {
  late Map<String, dynamic> fixtures;

  setUpAll(() {
    final file = File('test/fixtures/adpcm_vectors.json');
    expect(
      file.existsSync(),
      isTrue,
      reason: 'run tool/generate_adpcm_fixtures.py to create the golden data',
    );
    fixtures = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  });

  Uint8List hexToBytes(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  List<Map<String, dynamic>> cases() =>
      (fixtures['cases'] as List).cast<Map<String, dynamic>>();

  Uint8List blockFor(String name) => hexToBytes(
        cases().firstWhere((c) => c['name'] == name)['block_hex'] as String,
      );

  group('cross-language golden vectors', () {
    test('the fixture file covers the cases the device can produce', () {
      final names = cases().map((c) => c['name'] as String).toSet();
      expect(
        names,
        containsAll(<String>[
          'tone_320',
          'silence_320',
          'noise_320',
          'step_index_clamp_low',
          'step_index_clamp_low_active',
          'step_index_clamp_high',
          'step_index_header_above_max',
          'predictor_clamp_positive',
          'predictor_clamp_negative',
          'nibble_order_probe',
          'odd_five_samples',
          'independent_block_a',
          'independent_block_b',
        ]),
      );
      expect(cases().length, greaterThanOrEqualTo(20));
    });

    test('the Dart step and index tables match the reference tables', () {
      expect(
        AdpcmDecoder.stepTable,
        equals((fixtures['step_table'] as List).cast<int>()),
      );
      expect(
        AdpcmDecoder.indexTable,
        equals((fixtures['index_table'] as List).cast<int>()),
      );
      expect(AdpcmDecoder.stepTable.length, 89);
      expect(AdpcmDecoder.indexTable.length, 16);
    });

    test('every golden block decodes to exactly the reference samples', () {
      var checked = 0;
      for (final testCase in cases()) {
        final name = testCase['name'] as String;
        final expected = (testCase['expected_samples'] as List).cast<int>();
        final decoded = AdpcmDecoder.decodeBlock(
          hexToBytes(testCase['block_hex'] as String),
        );

        expect(
          decoded.length,
          expected.length,
          reason: '$name: sample count differs (${testCase['note']})',
        );
        for (var i = 0; i < expected.length; i++) {
          expect(
            decoded[i],
            expected[i],
            reason: '$name: sample $i differs (${testCase['note']})',
          );
        }
        checked += expected.length;
      }
      expect(checked, greaterThan(2000));
    });
  });

  group('firmware block geometry', () {
    test('a 320-sample block is 164 bytes and decodes to 320 samples', () {
      final block = blockFor('tone_320');
      expect(block.length, 164);
      expect(AdpcmDecoder.decodeBlock(block).length, 320);
    });
  });

  group('nibble ordering', () {
    test('the low nibble of each byte is decoded first', () {
      // Header: predictor 0, index 0. Payload: one byte 0x71 -> low nibble 1,
      // high nibble 7. At index 0 the step is 7, so code 1 moves the predictor
      // by 7>>2 = 1 and code 7 by 7>>3 + 7 + 3 + 1 = 11.
      final block = Uint8List.fromList([0, 0, 0, 0, 0x71]);
      final decoded = AdpcmDecoder.decodeBlock(block);
      expect(decoded, hasLength(2));
      expect(decoded[0], 1, reason: 'low nibble (code 1) must come first');
      expect(decoded[1], isNot(1), reason: 'high nibble (code 7) comes second');
    });

    test('swapping the nibbles of a byte changes the output', () {
      final asIs = AdpcmDecoder.decodeBlock(
        Uint8List.fromList([0, 0, 0, 0, 0x71]),
      );
      final swapped = AdpcmDecoder.decodeBlock(
        Uint8List.fromList([0, 0, 0, 0, 0x17]),
      );
      expect(asIs, isNot(equals(swapped)));
    });
  });

  group('clamping at table bounds', () {
    test('the predictor saturates at +32767', () {
      final decoded = AdpcmDecoder.decodeBlock(blockFor('predictor_clamp_positive'));
      expect(decoded.every((s) => s <= 32767), isTrue);
      expect(decoded.last, 32767);
    });

    test('the predictor saturates at -32768', () {
      final decoded =
          AdpcmDecoder.decodeBlock(blockFor('predictor_clamp_negative'));
      expect(decoded.every((s) => s >= -32768), isTrue);
      expect(decoded.last, -32768);
    });

    test('the step index never goes below 0', () {
      // Codes 1 and 9 nudge the predictor by +-1 while pushing the index down
      // every step; if the index went negative the table lookup would throw.
      final decoded =
          AdpcmDecoder.decodeBlock(blockFor('step_index_clamp_low_active'));
      expect(decoded.first, 501);
      expect(decoded.toSet(), <int>{500, 501});
    });

    test('the step index never goes above 88', () {
      // Code 7 adds 8 to the index each time; the table has 89 entries, so an
      // unclamped index would run off the end.
      expect(
        () => AdpcmDecoder.decodeBlock(blockFor('step_index_clamp_high')),
        returnsNormally,
      );
      expect(
        AdpcmDecoder.decodeBlock(blockFor('step_index_clamp_high')).last,
        32767,
      );
    });

    test('an out-of-range header index is clamped on entry', () {
      // Header index 200 has no table entry; the reference clamps it to 88
      // before decoding rather than rejecting the block.
      expect(
        () => AdpcmDecoder.decodeBlock(blockFor('step_index_header_above_max')),
        returnsNormally,
      );
    });

    test('a header index of exactly 88 is valid', () {
      final block = Uint8List.fromList([0, 0, 88, 0, 0x00]);
      expect(AdpcmDecoder.decodeBlock(block), hasLength(2));
    });
  });

  group('block independence', () {
    test('identical nibbles with different headers decode differently', () {
      final a = AdpcmDecoder.decodeBlock(blockFor('independent_block_a'));
      final b = AdpcmDecoder.decodeBlock(blockFor('independent_block_b'));
      expect(a, isNot(equals(b)));
    });

    test('decoding is stateless across calls', () {
      // Decoding an unrelated block in between must not change the result: a
      // dropped packet has to cost one block, never the rest of the stream.
      final target = blockFor('tone_320');
      final first = AdpcmDecoder.decodeBlock(target);
      AdpcmDecoder.decodeBlock(blockFor('noise_320'));
      final second = AdpcmDecoder.decodeBlock(target);
      expect(second, equals(first));
    });
  });

  group('edge cases', () {
    test('a block shorter than the 4-byte header decodes to nothing', () {
      for (final length in [0, 1, 2, 3]) {
        expect(
          AdpcmDecoder.decodeBlock(Uint8List(length)),
          isEmpty,
          reason: '$length-byte block',
        );
      }
    });

    test('a header with no payload decodes to nothing', () {
      expect(AdpcmDecoder.decodeBlock(blockFor('empty_payload')), isEmpty);
    });

    test('an odd sample count yields one padding sample', () {
      // 5 encoded samples occupy 3 bytes, so 6 samples come back; the caller is
      // expected to know the block length, not the decoder.
      final decoded = AdpcmDecoder.decodeBlock(blockFor('odd_five_samples'));
      expect(decoded, hasLength(6));
      expect(decoded.length.isEven, isTrue);
    });

    test('the decoded sample count is always twice the payload length', () {
      for (final testCase in cases()) {
        final block = hexToBytes(testCase['block_hex'] as String);
        if (block.length < AdpcmDecoder.headerBytes) continue;
        expect(
          AdpcmDecoder.decodeBlock(block).length,
          (block.length - AdpcmDecoder.headerBytes) * 2,
          reason: testCase['name'] as String,
        );
      }
    });

    test('every decoded sample fits in int16', () {
      for (final testCase in cases()) {
        for (final sample
            in AdpcmDecoder.decodeBlock(hexToBytes(testCase['block_hex'] as String))) {
          expect(sample, inInclusiveRange(-32768, 32767));
        }
      }
    });
  });

  group('decodeBlockToPcmBytes', () {
    test('emits little-endian s16 matching decodeBlock', () {
      final block = blockFor('noise_320');
      final samples = AdpcmDecoder.decodeBlock(block);
      final bytes = AdpcmDecoder.decodeBlockToPcmBytes(block);

      expect(bytes.length, samples.length * 2);
      final view = ByteData.sublistView(bytes);
      for (var i = 0; i < samples.length; i++) {
        expect(view.getInt16(i * 2, Endian.little), samples[i]);
      }
    });

    test('a negative sample is encoded little-endian', () {
      // -32768 is 0x8000 -> bytes 0x00 0x80 in little-endian order.
      final bytes =
          AdpcmDecoder.decodeBlockToPcmBytes(blockFor('predictor_clamp_negative'));
      expect(bytes[0], 0x00);
      expect(bytes[1], 0x80);
    });
  });
}
