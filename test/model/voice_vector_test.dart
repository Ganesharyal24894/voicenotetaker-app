import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/voice_vector.dart';

void main() {
  test('normalise scales to length one, and leaves nothing as nothing', () {
    final unit = VoiceVector.normalise(<double>[3, 4]);
    expect(unit[0], closeTo(0.6, 1e-6));
    expect(unit[1], closeTo(0.8, 1e-6));
    expect(VoiceVector.normalise(<double>[0, 0]), <double>[0, 0]);
  });

  test('cosine is direction only, and zero for nothing or a size mismatch', () {
    expect(VoiceVector.cosine(<double>[2, 0], <double>[5, 0]), 1);
    expect(VoiceVector.cosine(<double>[1, 0], <double>[0, 3]), 0);
    expect(
      VoiceVector.cosine(<double>[1, 1], <double>[1, 0]),
      closeTo(1 / math.sqrt(2), 1e-9),
    );
    expect(VoiceVector.cosine(<double>[0, 0], <double>[1, 0]), 0);
    expect(VoiceVector.cosine(<double>[1], <double>[1, 0]), 0);
  });

  test('weighted mean counts each vector by its weight', () {
    final mean = VoiceVector.weightedMean(<(List<double>, double)>[
      (<double>[1, 0], 3),
      (<double>[0, 1], 1),
    ], 2);
    expect(mean[0], closeTo(3 / math.sqrt(10), 1e-6));
    expect(mean[1], closeTo(1 / math.sqrt(10), 1e-6));
  });

  test('written as base64 of little-endian float32', () {
    // 1.0f is 00 00 80 3F in little-endian.
    expect(VoiceVector.encode(<double>[1]), 'AACAPw==');
    final vector = Float32List.fromList(<double>[0.25, -1.5, 3e-7]);
    expect(VoiceVector.decode(VoiceVector.encode(vector), 3), vector);
  });

  test('decode refuses anything that is not exactly dim finite floats', () {
    expect(VoiceVector.decode(null, 1), isNull);
    expect(VoiceVector.decode(42, 1), isNull);
    expect(VoiceVector.decode('not base64!', 1), isNull);
    expect(VoiceVector.decode('AACAPw==', 2), isNull);
    // NaN: 00 00 C0 7F.
    expect(VoiceVector.decode('AADAfw==', 1), isNull);
  });
}
