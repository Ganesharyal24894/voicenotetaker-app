/// Arithmetic on voice embeddings, and how one is written down.
///
/// PURE: lists of numbers in, numbers out. Shared by the voiceprint store, the
/// per-note sidecar and the matcher so all three agree on what "the same
/// direction" and "the same bytes" mean.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

abstract final class VoiceVector {
  /// [vector] scaled to length 1; all zeros when it has no length.
  ///
  /// Every embedding is stored normalised, so a cosine is a plain dot product
  /// and a weighted sum of samples weighs them by seconds, not by how loud the
  /// network happened to make each vector.
  static Float32List normalise(List<double> vector) {
    var sum = 0.0;
    for (final value in vector) {
      sum += value * value;
    }
    final out = Float32List(vector.length);
    if (sum <= 0 || !sum.isFinite) return out;
    final scale = 1 / math.sqrt(sum);
    for (var i = 0; i < vector.length; i++) {
      out[i] = vector[i] * scale;
    }
    return out;
  }

  /// Cosine similarity of [a] and [b]; 0 when either has no length or the two
  /// differ in size.
  ///
  /// Computed in full rather than as a dot product, so a vector that was never
  /// normalised still scores what it should.
  static double cosine(List<double> a, List<double> b) {
    if (a.length != b.length || a.isEmpty) return 0;
    var dot = 0.0;
    var aa = 0.0;
    var bb = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      aa += a[i] * a[i];
      bb += b[i] * b[i];
    }
    if (aa <= 0 || bb <= 0) return 0;
    return dot / math.sqrt(aa * bb);
  }

  /// normalise(sum of weight x vector): the direction a set of samples points
  /// in, each counted by how much speech it came from.
  ///
  /// Empty, or every weight zero, gives all zeros of [dim].
  static Float32List weightedMean(
    Iterable<(List<double>, double)> parts,
    int dim,
  ) {
    final sum = Float64List(dim);
    for (final (vector, weight) in parts) {
      if (vector.length != dim || weight <= 0) continue;
      for (var i = 0; i < dim; i++) {
        sum[i] += vector[i] * weight;
      }
    }
    return normalise(sum);
  }

  /// [vector] as base64 of little-endian float32: 1 kB of text for 192
  /// numbers, and the same bytes on every phone whatever its byte order.
  static String encode(List<double> vector) {
    final bytes = ByteData(vector.length * 4);
    for (var i = 0; i < vector.length; i++) {
      bytes.setFloat32(i * 4, vector[i], Endian.little);
    }
    return base64.encode(bytes.buffer.asUint8List());
  }

  /// The vector [encode] wrote, or null unless [value] is exactly [dim]
  /// finite floats. Never throws.
  static Float32List? decode(Object? value, int dim) {
    if (value is! String) return null;
    final Uint8List bytes;
    try {
      bytes = base64.decode(value);
    } on FormatException {
      return null;
    }
    if (bytes.length != dim * 4) return null;
    final view = ByteData.sublistView(bytes);
    final out = Float32List(dim);
    for (var i = 0; i < dim; i++) {
      final number = view.getFloat32(i * 4, Endian.little);
      if (!number.isFinite) return null;
      out[i] = number;
    }
    return out;
  }
}
