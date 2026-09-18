/// A sha256 being computed a chunk at a time.
///
/// Chunked because the thing being hashed is a 197 MB file: it is read and fed
/// through this a few megabytes at a time, so verifying a download never needs
/// the download in memory.
abstract class Sha256Sink {
  void add(List<int> chunk);

  /// Lowercase hex of everything added, and the sink is finished. Calling it
  /// twice is a programming error.
  String finish();
}

/// Hashing, behind an interface like every other thing that comes from a
/// package.
///
/// It is here rather than in `services/` for the usual reason - the domain
/// layer names no package - and it earns its keep twice over: a fake that
/// returns the wrong digest is how "the download arrived corrupt" is tested
/// without corrupting 197 MB of anything.
abstract class Hashing {
  Sha256Sink startSha256();
}
