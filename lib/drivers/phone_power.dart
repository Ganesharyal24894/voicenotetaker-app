import '../model/phone_power.dart';

/// The phone's battery, charger, battery saver and thermal state.
///
/// Interface only. The implementation (`phone_power_battery_plus.dart`) is
/// named in `main.dart` and nowhere else, so the controller and its tests
/// never see a plugin.
abstract class PhonePower {
  /// One reading. Never throws: what could not be read is null in the result.
  Future<PhonePowerState> read();

  /// Fires when the charger is plugged in or out (and on other battery state
  /// changes the platform reports). Listened to only while background work is
  /// waiting for power, so nothing is registered otherwise.
  Stream<void> get changes;
}
