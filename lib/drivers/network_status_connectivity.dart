import 'package:connectivity_plus/connectivity_plus.dart';

import 'network_status.dart';

/// [NetworkStatus] over `connectivity_plus`.
///
/// The ONLY file that names the package, like every other driver here.
///
/// WHAT IT CAN AND CANNOT SAY. It reports the transport - Wi-Fi, mobile,
/// ethernet, none - not whether there is really internet behind it. That is
/// exactly what the Wi-Fi-only rule needs: the question is "is this going to
/// come out of the user's data allowance", not "is the internet up". A phone
/// on Wi-Fi with no route out fails later as an ordinary network error, with
/// its own friendly message and a Retry.
///
/// A phone can report several transports at once (Wi-Fi and mobile both up).
/// Wi-Fi wins: Android routes over it, and it is the answer that lets the
/// download start.
class ConnectivityPlusNetworkStatus implements NetworkStatus {
  ConnectivityPlusNetworkStatus([Connectivity? connectivity])
      : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  @override
  Future<NetworkKind> current() async {
    try {
      return _kindOf(await _connectivity.checkConnectivity());
    } on Object {
      // A platform with no implementation must not make the feature
      // unreachable: see [NetworkKind.unknown].
      return NetworkKind.unknown;
    }
  }

  @override
  Stream<NetworkKind> get changes => _connectivity.onConnectivityChanged
      .map(_kindOf)
      .handleError((Object _) {});

  static NetworkKind _kindOf(List<ConnectivityResult> results) {
    if (results.isEmpty) return NetworkKind.unknown;
    if (results.every((r) => r == ConnectivityResult.none)) {
      return NetworkKind.none;
    }
    for (final result in results) {
      switch (result) {
        case ConnectivityResult.wifi:
        case ConnectivityResult.ethernet:
        case ConnectivityResult.vpn:
          // A VPN hides the transport underneath it. Calling it unmetered is
          // the lesser evil: the alternative blocks the download on every
          // phone with a VPN profile, on Wi-Fi or not.
          return NetworkKind.unmetered;
        case ConnectivityResult.mobile:
        case ConnectivityResult.satellite:
        case ConnectivityResult.bluetooth:
        case ConnectivityResult.other:
        case ConnectivityResult.none:
          continue;
      }
    }
    // Mobile and satellite both come out of an allowance.
    return results.contains(ConnectivityResult.mobile) ||
            results.contains(ConnectivityResult.satellite)
        ? NetworkKind.metered
        : NetworkKind.unknown;
  }
}
