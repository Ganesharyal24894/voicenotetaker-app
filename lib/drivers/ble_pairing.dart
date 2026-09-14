import '../model/pairing_outcome.dart';

/// Pairing (bonding) with the recorder, without naming any BLE package.
///
/// A seam of its own rather than more of `BleTransport`, so the transport's
/// many fakes stay as they are and an app built without it connects exactly
/// as it did before pairing existed. `UniversalBleTransport` implements both.
///
/// WHAT EACH PLATFORM CAN DO:
///
///   * Android bonds explicitly ([systemBonds] true): [isBonded] reads the OS
///     bond state, [bond] calls `createBond` and waits for `BOND_BONDED`, and
///     [bondedRecorderIds] lists the bonded recorders by IDENTITY address -
///     the address to reconnect through, since the recorder advertises a
///     rotating private one.
///   * iOS has no bonding API ([systemBonds] false): [isBonded] answers null,
///     [bond] does nothing, and pairing happens when [secure] reads an
///     encrypted characteristic - the system shows its own alert.
abstract class BlePairing {
  /// Whether the platform bonds explicitly and reports bond state.
  bool get systemBonds;

  /// The OS bond state of [deviceId]; null where the platform cannot say.
  Future<bool?> isBonded(String deviceId);

  /// Bonds with the connected [deviceId]. Completes once bonded; throws when
  /// the bond fails or is refused. A no-op without [systemBonds].
  Future<void> bond(String deviceId, {required Duration timeout});

  /// Reads `fe02`, which needs an encrypted link: on iOS this is what starts
  /// pairing. Throws when the read fails.
  Future<void> secure(String deviceId, {required Duration timeout});

  /// Identity addresses of bonded recorders (Android); empty elsewhere or when
  /// the OS will not say.
  Future<List<String>> bondedRecorderIds();

  /// Sorts [error] - anything a connect, bond or read threw - using what the
  /// platform said and the reason the last disconnect of [deviceId] gave.
  BleFailureKind describe(Object error, {required String deviceId});
}
