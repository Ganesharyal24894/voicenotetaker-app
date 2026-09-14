/// Keeping the app alive while always-listening runs with the screen off.
///
/// A driver, not a service: it is a platform capability with no domain logic.
/// The controller decides WHEN it runs and WHAT the notification says; this
/// only makes it so.
///
/// WHAT EACH PLATFORM DOES:
///
///   * Android: a foreground service of type `connectedDevice`, with a quiet,
///     persistent notification. It keeps the process - and the Dart isolate
///     holding the BLE link and the open note - alive with the screen off and
///     after the app is swiped away. See `ListeningService.kt`.
///   * iOS: nothing to start. The `bluetooth-central` background mode in
///     `Info.plist` is what keeps notifications arriving, and iOS has no
///     equivalent of the notification. Every method answers as though the
///     platform were ready, because there is nothing for the user to grant.
abstract class BackgroundMode {
  /// Starts the keep-alive, or updates its text when it is already running.
  Future<void> start({required String title, required String text});

  /// Stops the keep-alive and removes its notification.
  Future<void> stop();

  /// Whether the app may post its notification. Always true below Android 13.
  Future<bool> notificationsAllowed();

  /// Asks the OS for permission to post notifications. Returns once asked;
  /// the answer is read back with [notificationsAllowed] afterwards.
  Future<void> requestNotifications();

  /// Whether the OS exempts this app from battery optimisation - without it
  /// Doze and vendor task killers are free to stop the keep-alive.
  Future<bool> ignoringBatteryOptimizations();

  /// Shows the OS dialog that grants the exemption.
  Future<void> requestIgnoreBatteryOptimizations();

  /// Whether this phone has a vendor "autostart" page worth pointing at.
  /// True on Xiaomi (MIUI / HyperOS), which kills background apps that lack it
  /// whatever the other settings say.
  Future<bool> hasAutostartSettings();

  /// Opens that page, or the app's own settings where there is none. False
  /// when nothing could be opened.
  Future<bool> openAutostartSettings();
}
