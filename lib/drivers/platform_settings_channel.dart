import 'package:flutter/services.dart';

import 'platform_settings.dart';

/// [PlatformSettings] over a [MethodChannel] handled in `MainActivity.kt` and
/// `AppDelegate.swift`.
///
/// WHY NO PACKAGE. The whole job is two intents on Android and one
/// `openSettingsURLString` on iOS - about thirty lines of platform code. The
/// obvious candidate, `app_settings`, has historically reached the iOS
/// Bluetooth page through the PRIVATE `App-Prefs:` URL scheme, which apps have
/// been rejected from the App Store for; this app ships an `.ipa` through CI,
/// so that is a real risk to take on for thirty lines. Writing the channel
/// here also keeps the rule that every third-party package is named in exactly
/// one file intact, with no new name to name.
///
/// The channel name is the app's bundle id plus the capability, so it cannot
/// collide with a plugin's.
class MethodChannelPlatformSettings implements PlatformSettings {
  const MethodChannelPlatformSettings();

  static const MethodChannel channel =
      MethodChannel('com.ganeshsharma.voicenotetaker_app/settings');

  @override
  Future<bool> openBluetoothSettings() => _invoke('openBluetoothSettings');

  @override
  Future<bool> openAppSettings() => _invoke('openAppSettings');

  /// A platform that cannot honour the request answers false rather than
  /// throwing into the view layer: the screen's job is then to say so, not to
  /// crash.
  Future<bool> _invoke(String method) async {
    try {
      return await channel.invokeMethod<bool>(method) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      // A platform with no handler registered - a desktop or web build of this
      // app - has no settings page to open.
      return false;
    }
  }
}
