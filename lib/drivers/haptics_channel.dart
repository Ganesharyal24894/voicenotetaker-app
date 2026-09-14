import 'package:flutter/services.dart';

import 'background_mode_channel.dart';
import 'haptics.dart';

/// [Haptics] over the background channel `EngineHolder.kt` already handles,
/// so the vibration works with the screen off and no activity on screen.
///
/// No iOS handler, on purpose - see [Haptics]. A missing handler is a quiet
/// no-op, never a failure.
class MethodChannelHaptics implements Haptics {
  const MethodChannelHaptics();

  @override
  Future<void> buzz(BuzzPattern pattern) async {
    try {
      await MethodChannelBackgroundMode.channel
          .invokeMethod<void>('vibrate', <String, String>{'pattern': pattern.name});
    } on PlatformException {
      // A phone that will not vibrate still shows the notification.
    } on MissingPluginException {
      // iOS, and tests.
    }
  }
}
