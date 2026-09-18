import 'package:crypto/crypto.dart';

import 'hashing.dart';

/// [Hashing] over `package:crypto`, the Dart team's own implementation.
///
/// The ONLY file that names the package.
class CryptoHashing implements Hashing {
  const CryptoHashing();

  @override
  Sha256Sink startSha256() => _CryptoSha256Sink();
}

class _CryptoSha256Sink implements Sha256Sink {
  _CryptoSha256Sink() {
    _input = sha256.startChunkedConversion(_output);
  }

  final _DigestHolder _output = _DigestHolder();
  late final Sink<List<int>> _input;
  bool _finished = false;

  @override
  void add(List<int> chunk) {
    if (_finished) throw StateError('this sha256 has already been finished');
    _input.add(chunk);
  }

  @override
  String finish() {
    if (_finished) throw StateError('this sha256 has already been finished');
    _finished = true;
    _input.close();
    // `Digest.toString()` is lowercase hex, which is what the catalogue holds.
    return _output.value!.toString();
  }
}

/// Keeps the one digest the chunked conversion emits.
///
/// `package:convert`'s `AccumulatorSink` does this too, but it is not a
/// dependency of this app and this is four lines.
class _DigestHolder implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
