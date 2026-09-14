import 'package:flutter/services.dart';

import 'background_mode.dart';

/// [BackgroundMode] over a [MethodChannel] handled by `EngineHolder.kt` on
/// Android.
///
/// WHY NO PACKAGE. `flutter_foreground_task` is the maintained candidate, and
/// it runs its work in a SECOND isolate started by the service. This app's BLE
/// link, frame decoding and open note all live in the main isolate, behind
/// `AppController`; moving them would split the controller in two and put a
/// message channel through the middle of the audio path. What is actually
/// needed is smaller: a foreground service that holds a notification, plus a
/// Flutter engine that outlives the activity. That is two small Kotlin files,
/// and it keeps the rule that every third-party package is named in
/// one file.
///
/// There is no iOS handler, on purpose - see [BackgroundMode]. A missing
/// handler answers as "ready", never as a failure.
class MethodChannelBackgroundMode implements BackgroundMode {
  const MethodChannelBackgroundMode();

  static const MethodChannel channel =
      MethodChannel('com.ganeshsharma.voicenotetaker_app/background');

  @override
  Future<void> start({required String title, required String text}) =>
      _call<void>('start', <String, String>{'title': title, 'text': text});

  @override
  Future<void> stop() => _call<void>('stop');

  @override
  Future<bool> notificationsAllowed() async =>
      await _call<bool>('notificationsAllowed') ?? true;

  @override
  Future<void> requestNotifications() => _call<void>('requestNotifications');

  @override
  Future<bool> ignoringBatteryOptimizations() async =>
      await _call<bool>('ignoringBatteryOptimizations') ?? true;

  @override
  Future<void> requestIgnoreBatteryOptimizations() =>
      _call<void>('requestIgnoreBatteryOptimizations');

  @override
  Future<bool> hasAutostartSettings() async =>
      await _call<bool>('hasAutostartSettings') ?? false;

  @override
  Future<bool> openAutostartSettings() async =>
      await _call<bool>('openAutostartSettings') ?? false;

  /// Null when the platform has no handler or refused; callers pick the
  /// honest default for each question.
  Future<T?> _call<T>(String method, [Object? arguments]) async {
    try {
      return await channel.invokeMethod<T>(method, arguments);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
