import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/drivers/speech_recognizer.dart';

void main() {
  group('pcm16leToFloat32', () {
    test('scales the full int16 range into [-1, 1)', () {
      final bytes = Uint8List(8);
      ByteData.sublistView(bytes)
        ..setInt16(0, 0, Endian.little)
        ..setInt16(2, 16384, Endian.little)
        ..setInt16(4, -32768, Endian.little)
        ..setInt16(6, 32767, Endian.little);
      final samples = pcm16leToFloat32(bytes);
      expect(samples, hasLength(4));
      expect(samples[0], 0.0);
      expect(samples[1], 0.5);
      expect(samples[2], -1.0);
      expect(samples[3], closeTo(1.0, 1e-4));
      expect(samples[3], lessThan(1.0));
    });

    test('reads little-endian, not host order by accident', () {
      // 0x0102 little-endian is bytes 02 01.
      final samples = pcm16leToFloat32(Uint8List.fromList(<int>[0x02, 0x01]));
      expect(samples[0], 0x0102 / 32768.0);
    });

    test('ignores a trailing half sample', () {
      expect(pcm16leToFloat32(Uint8List(5)), hasLength(2));
      expect(pcm16leToFloat32(Uint8List(0)), isEmpty);
    });
  });

  // The swap-layer rule, enforced: the engine package is named in ONE file.
  test('sherpa_onnx is imported by exactly one file under lib/', () {
    final importers = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .where(
          (file) => file.readAsStringSync().contains('package:sherpa_onnx/'),
        )
        .map((file) => file.path.replaceAll(r'\', '/'))
        .toList();
    expect(importers, <String>['lib/drivers/speech_recognizer_sherpa.dart']);
  });
}
