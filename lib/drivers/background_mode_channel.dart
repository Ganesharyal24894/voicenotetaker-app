import 'dart:async';

import 'package:flutter/services.dart';

import '../model/background_task_plan.dart';
import 'background_mode.dart';

/// [BackgroundMode] over a [MethodChannel], answered by `EngineHolder.kt` on
/// Android and by `AppDelegate.swift` on iOS.
///
/// WHY NO PACKAGE. `flutter_foreground_task` is the maintained candidate, and
/// it runs its work in a SECOND isolate started by the service. This app's BLE
/// link, frame decoding and open note all live in the main isolate, behind
/// `AppController`; moving them would split the controller in two and put a
/// message channel through the middle of the audio path. What is actually
/// needed is smaller: a foreground service that holds a notification, plus a
/// Flutter engine that outlives the activity. That is two small Kotlin files,
/// and it keeps the rule that every third-party package is named in one file.
///
/// The same reasoning holds on iOS for `BGTaskScheduler`: the maintained
/// plugins (`workmanager`, `background_fetch`) all start a second isolate and
/// bring an Android half this app already has. What is needed there is one
/// registration, one handler and two method calls.
///
/// A MISSING HANDLER IS NEVER A FAILURE. Every call answers with the honest
/// default for its question, so a widget test with no platform behaves as a
/// phone that has nothing to grant.
class MethodChannelBackgroundMode implements BackgroundMode {
  MethodChannelBackgroundMode();

  static const MethodChannel channel =
      MethodChannel('com.ganeshsharma.voicenotetaker_app/background');

  /// Set by [listen]; called when iOS grants a `BGProcessingTask`
  /// window. Native waits on the future before telling iOS the task is done.
  Future<void> Function()? _onGranted;

  /// Called moments before the window ends.
  void Function()? _onExpiring;

  /// Called when Android's foreground service turns out not to be running.
  void Function()? _onKeepAliveStopped;

  @override
  Future<bool> start({
    required String title,
    required String text,
    bool alert = false,
  }) async {
    final arguments = <String, Object>{
      'title': title,
      'text': text,
      'alert': alert,
    };
    try {
      // Kotlin answers with whether the service is actually running; iOS with
      // true, having nothing that can be refused.
      return await channel.invokeMethod<bool>('start', arguments) ?? true;
    } on MissingPluginException {
      // No platform to keep anything alive - a test, or a desktop build.
      // There is nothing to retry, so this is not a failure.
      return true;
    } on PlatformException catch (error) {
      // The platform refused. Said so, so the caller asks again.
      return Future<bool>.error(error);
    }
  }

  @override
  Future<void> stop() => _call<void>('stop');

  @override
  Future<bool> notificationsAllowed() async =>
      await _call<bool>('notificationsAllowed') ?? true;

  @override
  Future<void> requestNotifications() => _call<void>('requestNotifications');

  @override
  Future<bool> backgroundWorkAllowed() async =>
      await _call<bool>('backgroundWorkAllowed') ?? true;

  @override
  Future<void> requestBackgroundWork() => _call<void>('requestBackgroundWork');

  @override
  Future<bool> hasAutostartSettings() async =>
      await _call<bool>('hasAutostartSettings') ?? false;

  @override
  Future<bool> openAutostartSettings() async =>
      await _call<bool>('openAutostartSettings') ?? false;

  @override
  Future<void> scheduleWork(BackgroundTaskRequest request) =>
      _call<void>('scheduleWork', <String, Object>{
        'externalPower': request.requiresExternalPower,
        'network': request.requiresNetworkConnectivity,
        'afterSeconds': request.earliestDelay.inSeconds,
      });

  @override
  Future<void> cancelWork() => _call<void>('cancelWork');

  @override
  Future<void> holdCpu() => _call<void>('holdCpu');

  @override
  Future<void> releaseCpu() => _call<void>('releaseCpu');

  @override
  void listen({
    required Future<void> Function() onGranted,
    required void Function() onExpiring,
    required void Function() onKeepAliveStopped,
  }) {
    _onGranted = onGranted;
    _onExpiring = onExpiring;
    _onKeepAliveStopped = onKeepAliveStopped;
    channel.setMethodCallHandler(_handle);
  }

  Future<Object?> _handle(MethodCall call) async {
    switch (call.method) {
      case 'runWork':
        // Native is awaiting this; it tells iOS the task finished when the
        // future completes. An error here must still complete, or the app is
        // killed for overrunning its window.
        try {
          await _onGranted?.call();
        } on Object {
          return false;
        }
        return true;
      case 'workExpiring':
        _onExpiring?.call();
        return null;
      case 'keepAliveStopped':
        _onKeepAliveStopped?.call();
        return null;
      default:
        return null;
    }
  }

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
