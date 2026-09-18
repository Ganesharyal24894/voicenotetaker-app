import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/services.dart';

import '../model/phone_power.dart';
import 'background_mode_channel.dart';
import 'phone_power.dart';

/// [PhonePower] over `battery_plus` (fluttercommunity, BSD-3-Clause), plus
/// Android's thermal status over the app's own background channel.
///
/// WHY A PACKAGE HERE when the foreground service is hand-written: battery
/// level, charger state and battery saver are needed on BOTH platforms, and
/// `battery_plus` already answers all three on Android and iOS from the main
/// isolate with no service or second engine - the objection that ruled out
/// `flutter_foreground_task` does not apply. It is the Flutter Community's
/// maintained plugin, adds no permission, and is named in this file only.
///
/// Thermal status has no cross-platform plugin; `EngineHolder.kt` answers
/// `PowerManager.getCurrentThermalStatus()` (API 29+). Elsewhere it is null.
class BatteryPlusPhonePower implements PhonePower {
  BatteryPlusPhonePower({Battery? battery}) : _battery = battery ?? Battery();

  final Battery _battery;

  @override
  Future<PhonePowerState> read() async {
    return PhonePowerState(
      batteryPercent: await _try(() => _battery.batteryLevel),
      onExternalPower: await _try(() async {
        return switch (await _battery.batteryState) {
          BatteryState.charging ||
          BatteryState.full ||
          BatteryState.connectedNotCharging =>
            true,
          BatteryState.discharging => false,
          BatteryState.unknown => null,
        };
      }),
      batterySaver: await _try(() => _battery.isInBatterySaveMode),
      thermal: await _try(() async {
        // Named, not left to [_try]: this channel has no iOS handler, so a
        // MissingPluginException there is the ORDINARY case rather than a
        // failure, and a later narrowing of [_try] must not turn it into one.
        final int? status;
        try {
          status = await MethodChannelBackgroundMode.channel
              .invokeMethod<int>('thermalStatus');
        } on MissingPluginException {
          return null;
        }
        if (status == null ||
            status < 0 ||
            status >= ThermalState.values.length) {
          return null;
        }
        return ThermalState.values[status];
      }),
    );
  }

  @override
  Stream<void> get changes => _battery.onBatteryStateChanged
      .map((_) {})
      .handleError((Object _) {});

  static Future<T?> _try<T>(Future<T?> Function() read) async {
    try {
      return await read();
    } on Object {
      return null;
    }
  }
}
