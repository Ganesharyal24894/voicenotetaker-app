/// What kind of connection the phone has, as far as a download cares.
enum NetworkKind {
  /// Nothing. A download cannot start.
  none,

  /// Wi-Fi, or anything else that does not come out of a data allowance -
  /// ethernet on a desktop, a wired dock.
  unmetered,

  /// Mobile data. A 197 MB model is not something to spend someone's data
  /// allowance on without asking.
  metered,

  /// The platform did not say. Treated as [unmetered], because refusing to
  /// download on a phone that simply cannot report its radio would leave the
  /// feature permanently unreachable.
  unknown,
}

/// Whether the phone is on Wi-Fi or on mobile data.
///
/// Abstract like every other driver: the downloader is tested against a fake
/// that answers whatever the test needs.
abstract class NetworkStatus {
  Future<NetworkKind> current();

  /// Changes, for a screen that wants to stop saying "waiting for Wi-Fi" the
  /// moment Wi-Fi arrives. Never errors.
  Stream<NetworkKind> get changes;
}

/// A [NetworkStatus] that always answers the same thing.
///
/// For a platform with no connectivity plugin wired in, and for tests.
class FixedNetworkStatus implements NetworkStatus {
  const FixedNetworkStatus([this.kind = NetworkKind.unknown]);

  final NetworkKind kind;

  @override
  Future<NetworkKind> current() async => kind;

  @override
  Stream<NetworkKind> get changes => const Stream<NetworkKind>.empty();
}
