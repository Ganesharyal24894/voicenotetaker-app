import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/background_transcription_policy.dart';
import 'package:voicenotetaker_app/model/phone_power.dart';

/// When transcription may run with the app off screen.
void main() {
  TranscriptionPermit decide({
    bool foreground = false,
    bool keepAlive = true,
    PhonePowerState? power,
  }) =>
      BackgroundTranscriptionPolicy.decide(
        foreground: foreground,
        keepAlive: keepAlive,
        power: power,
      );

  const healthy = PhonePowerState(
    batteryPercent: 80,
    onExternalPower: false,
    batterySaver: false,
    thermal: ThermalState.none,
  );

  test('on screen is always allowed, whatever the phone says', () {
    for (final power in <PhonePowerState?>[
      null,
      const PhonePowerState(
        batteryPercent: 5,
        onExternalPower: false,
        batterySaver: true,
        thermal: ThermalState.critical,
      ),
    ]) {
      final permit = decide(foreground: true, keepAlive: false, power: power);
      expect(permit, TranscriptionPermit.foreground);
      expect(permit.allowed, isTrue);
    }
  });

  test('off screen with nothing keeping the process alive: never (iOS, or '
      'always-listening off)', () {
    expect(decide(keepAlive: false, power: healthy),
        TranscriptionPermit.noKeepAlive);
    expect(TranscriptionPermit.noKeepAlive.allowed, isFalse);
  });

  test('on battery at 30% or more, saver off: allowed', () {
    expect(decide(power: healthy), TranscriptionPermit.batteryOk);
    const exactly = PhonePowerState(
        batteryPercent: 30, onExternalPower: false, batterySaver: false);
    expect(decide(power: exactly), TranscriptionPermit.batteryOk);
  });

  test('below 30% on battery: paused', () {
    const low = PhonePowerState(
        batteryPercent: 29, onExternalPower: false, batterySaver: false);
    expect(decide(power: low), TranscriptionPermit.batteryLow);
    expect(TranscriptionPermit.batteryLow.allowed, isFalse);
  });

  test('battery saver on, on battery: paused even when full', () {
    const saver = PhonePowerState(
        batteryPercent: 100, onExternalPower: false, batterySaver: true);
    expect(decide(power: saver), TranscriptionPermit.batterySaver);
  });

  test('charging: allowed at any level, saver or not', () {
    const charging = PhonePowerState(
        batteryPercent: 3, onExternalPower: true, batterySaver: true);
    expect(decide(power: charging), TranscriptionPermit.charging);
    // The level need not even be known.
    expect(decide(power: const PhonePowerState(onExternalPower: true)),
        TranscriptionPermit.charging);
  });

  test('moderate heat or worse pauses, charger or not; light does not', () {
    for (final thermal in ThermalState.values) {
      final hot = thermal.index >= ThermalState.moderate.index;
      final onCharger = PhonePowerState(onExternalPower: true, thermal: thermal);
      final onBattery = PhonePowerState(
        batteryPercent: 90,
        onExternalPower: false,
        batterySaver: false,
        thermal: thermal,
      );
      expect(decide(power: onCharger),
          hot ? TranscriptionPermit.tooHot : TranscriptionPermit.charging,
          reason: thermal.name);
      expect(decide(power: onBattery),
          hot ? TranscriptionPermit.tooHot : TranscriptionPermit.batteryOk,
          reason: thermal.name);
    }
  });

  test('no thermal API (null) does not block', () {
    const noThermal = PhonePowerState(
        batteryPercent: 50, onExternalPower: false, batterySaver: false);
    expect(decide(power: noThermal), TranscriptionPermit.batteryOk);
  });

  test('anything unknown on battery counts against running', () {
    expect(decide(power: null), TranscriptionPermit.powerUnknown);
    expect(decide(power: const PhonePowerState()),
        TranscriptionPermit.powerUnknown);
    expect(
        decide(
            power: const PhonePowerState(
                onExternalPower: false, batterySaver: false)),
        TranscriptionPermit.powerUnknown);
    expect(
        decide(
            power: const PhonePowerState(
                batteryPercent: 90, onExternalPower: false)),
        TranscriptionPermit.powerUnknown);
    // Unknown charger state with a good battery still needs the saver known.
    expect(
        decide(
            power: const PhonePowerState(
                batteryPercent: 90, batterySaver: false)),
        TranscriptionPermit.batteryOk);
  });

  test('the thresholds are the documented ones', () {
    expect(BackgroundTranscriptionPolicy.minBatteryPercent, 30);
    expect(BackgroundTranscriptionPolicy.maxThermal, ThermalState.moderate);
    expect(BackgroundTranscriptionPolicy.recheckInterval,
        const Duration(seconds: 60));
  });
}
