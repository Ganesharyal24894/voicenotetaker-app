/// The phone's own power and heat, as far as the platform reports them.
///
/// Pure data. Read by `drivers/phone_power.dart`; judged by
/// `model/background_transcription_policy.dart`.
library;

/// Android's thermal status (`PowerManager.THERMAL_STATUS_*`), in order of
/// severity.
enum ThermalState { none, light, moderate, severe, critical, emergency, shutdown }

/// One reading of the phone's battery, charger, saver and temperature.
///
/// Every field that a platform may not report is nullable, and null means
/// UNKNOWN - never "fine". The policy treats unknown as the cautious answer.
class PhonePowerState {
  const PhonePowerState({
    this.batteryPercent,
    this.onExternalPower,
    this.batterySaver,
    this.thermal,
  });

  /// 0-100, or null when the platform did not say.
  final int? batteryPercent;

  /// Plugged in: charging, full, or connected but not charging (a charge
  /// limit). Null when unknown.
  final bool? onExternalPower;

  /// The OS battery saver / low-power mode. Null when unknown.
  final bool? batterySaver;

  /// Null where the platform has no thermal API (iOS here, Android < 10).
  final ThermalState? thermal;

  @override
  bool operator ==(Object other) =>
      other is PhonePowerState &&
      other.batteryPercent == batteryPercent &&
      other.onExternalPower == onExternalPower &&
      other.batterySaver == batterySaver &&
      other.thermal == thermal;

  @override
  int get hashCode =>
      Object.hash(batteryPercent, onExternalPower, batterySaver, thermal);

  @override
  String toString() => 'PhonePowerState($batteryPercent%, '
      'power $onExternalPower, saver $batterySaver, thermal ${thermal?.name})';
}
