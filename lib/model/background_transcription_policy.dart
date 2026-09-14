import 'phone_power.dart';

/// Whether transcription may run right now, and why.
enum TranscriptionPermit {
  /// The app is on screen. Always allowed: the user is there and can see it.
  foreground,

  /// In the background, on a charger and not hot.
  charging,

  /// In the background, on battery with enough charge, no saver, not hot.
  batteryOk,

  /// In the background with nothing keeping the process alive - iOS, or
  /// Android with always-listening off. Paused until the app is opened.
  noKeepAlive,

  /// The phone did not report enough to decide. Paused.
  powerUnknown,

  /// Below [BackgroundTranscriptionPolicy.minBatteryPercent] and not charging.
  batteryLow,

  /// Battery saver is on and not charging.
  batterySaver,

  /// The phone reports [BackgroundTranscriptionPolicy.maxThermal] or hotter.
  tooHot;

  bool get allowed =>
      this == foreground || this == charging || this == batteryOk;
}

/// When transcription may run without the app on screen.
///
/// PURE: no clock, no I/O, no platform. The controller reads the phone and
/// asks; every rule below is a unit test.
///
/// THE RULES
///
///   * On screen: always.
///   * Off screen, only where something keeps the process alive - the Android
///     foreground service that always-listening runs. iOS gives no such
///     guarantee, so there it waits for the app to be opened, as before.
///   * Never when the phone is [maxThermal] or hotter, charger or not: a
///     charging phone is already warm, and two cores of inference on top is
///     how a phone throttles or cuts out.
///   * On a charger: yes.
///   * On battery: only at [minBatteryPercent] or more, with battery saver off.
///     A user who turned the saver on asked for exactly this kind of work to
///     wait.
///   * Anything the phone did not report counts against running.
///
/// It is asked before each job and again every [recheckInterval] while one
/// runs in the background, so a job pauses when the phone unplugs, drops
/// below the threshold or heats up.
abstract final class BackgroundTranscriptionPolicy {
  /// A 1-hour note is about 9 minutes of two cores on the owner's phone
  /// (RTF 0.15). 30% leaves a day's ordinary use a margin after that.
  static const int minBatteryPercent = 30;

  /// Android's `THERMAL_STATUS_MODERATE`: the platform's own "start shedding
  /// load" point. `light` is still allowed.
  static const ThermalState maxThermal = ThermalState.moderate;

  /// How often a running background job re-reads the phone.
  static const Duration recheckInterval = Duration(seconds: 60);

  static TranscriptionPermit decide({
    required bool foreground,
    required bool keepAlive,
    PhonePowerState? power,
  }) {
    if (foreground) return TranscriptionPermit.foreground;
    if (!keepAlive) return TranscriptionPermit.noKeepAlive;
    if (power == null) return TranscriptionPermit.powerUnknown;
    final thermal = power.thermal;
    if (thermal != null && thermal.index >= maxThermal.index) {
      return TranscriptionPermit.tooHot;
    }
    if (power.onExternalPower == true) return TranscriptionPermit.charging;
    final percent = power.batteryPercent;
    if (percent == null || power.batterySaver == null) {
      return TranscriptionPermit.powerUnknown;
    }
    if (power.batterySaver!) return TranscriptionPermit.batterySaver;
    if (percent < minBatteryPercent) return TranscriptionPermit.batteryLow;
    return TranscriptionPermit.batteryOk;
  }
}
