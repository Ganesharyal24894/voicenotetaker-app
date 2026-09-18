/// How much room is left where the app writes.
///
/// Abstract like every other driver. A platform that cannot say answers null,
/// and the downloader then starts anyway: refusing to install a model because
/// the phone would not report its free space would be worse than running out
/// and saying so.
abstract class DiskSpace {
  /// Free bytes on the filesystem holding [path], or null when the platform
  /// did not say. Never throws.
  Future<int?> freeBytesFor(String path);
}

/// A [DiskSpace] that always answers the same thing. For tests, and for a
/// platform with no handler.
class FixedDiskSpace implements DiskSpace {
  const FixedDiskSpace([this.freeBytes]);

  final int? freeBytes;

  @override
  Future<int?> freeBytesFor(String path) async => freeBytes;
}
