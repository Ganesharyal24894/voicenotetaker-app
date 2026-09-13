/// Opening the OS settings pages the edge-state screens point at.
///
/// This is a driver, not a service: it is a platform capability with no domain
/// logic, and it is the only reason `view/` ever needs the OS. Views reach it
/// through [AppController], never directly.
///
/// WHAT EACH PLATFORM CAN ACTUALLY DO - this interface is deliberately honest
/// about it, because the alternative is a button that lies:
///
///   * Android: both destinations are public. `ACTION_BLUETOOTH_SETTINGS`
///     opens the Bluetooth page, `ACTION_APPLICATION_DETAILS_SETTINGS` opens
///     this app's permissions page.
///   * iOS: `UIApplication.openSettingsURLString` opens THIS APP's Settings
///     page, which is exactly right for [openAppSettings]. There is NO public
///     way to open the Bluetooth page - `App-Prefs:root=Bluetooth` is a
///     private URL scheme apps have been rejected for - so
///     [openBluetoothSettings] lands the user on the app's own Settings page
///     instead, one tap from the top of Settings where Bluetooth lives.
///
/// Both methods report whether Settings was actually opened, so a caller is
/// never left claiming something happened that did not.
abstract class PlatformSettings {
  /// Opens the system Bluetooth settings, or the closest the platform allows.
  ///
  /// Returns false when the platform refused or has no such destination.
  Future<bool> openBluetoothSettings();

  /// Opens this app's own settings page, where its permissions live.
  Future<bool> openAppSettings();
}
