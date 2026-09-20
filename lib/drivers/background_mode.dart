/// Keeping the app alive, and keeping work running, while always-listening
/// runs with the screen off.
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
///     after the app is swiped away. See `ListeningService.kt`. Queued
///     transcripts simply carry on running in that process.
///   * iOS: there is no foreground service and no way to invent one. What iOS
///     gives instead is two separate things, and this seam carries both.
///
///     The LINK is kept by the `bluetooth-central` background mode in
///     `Info.plist`: while the app is subscribed to the recorder's
///     characteristics, iOS wakes the process for each notification, with the
///     screen locked and the app off screen, and the note is written to disk
///     in that wake-up. Nothing has to be started for this and there is
///     nothing for the user to grant, so [start] and [stop] do not touch it.
///
///     CPU TIME for transcription is a separate favour, and iOS grants it only
///     through `BGProcessingTask` - see [scheduleWork]. The app asks; the
///     system picks its own moment, typically while the phone is idle and
///     charging; [listenForWork] is how that window reaches Dart.
///
///     [start] and [stop] on iOS carry only the ALERT. There is no persistent
///     notification to keep, and an iPhone in a pocket cannot be made to
///     vibrate by an app that is not on screen; a local notification is the
///     only way to tell the wearer their notes stopped saving.
library;

import '../model/background_task_plan.dart';

abstract class BackgroundMode {
  /// Starts the keep-alive, or updates its text when it is already running.
  ///
  /// [alert] is true only while something is wrong and the wearer should be
  /// told now - `NotSavingAlertPolicy` decides. Android shows [title] and
  /// [text] in its service notification either way. iOS posts a local
  /// notification when [alert] is true and withdraws it when it is false, and
  /// does nothing at all with an ordinary status line.
  ///
  /// FALSE MEANS THE KEEP-ALIVE IS NOT RUNNING, and the caller must ask again
  /// rather than remember this as done. Android refuses a foreground service
  /// of type `connectedDevice` when the Bluetooth permission has been revoked,
  /// and refuses a background start with no exemption. True where there is
  /// nothing to keep alive, which is iOS and every test without a platform.
  Future<bool> start({
    required String title,
    required String text,
    bool alert = false,
  });

  /// Stops the keep-alive and removes its notification.
  Future<void> stop();

  /// Whether the app may post its notification. Always true below Android 13.
  Future<bool> notificationsAllowed();

  /// Asks the OS for permission to post notifications.
  ///
  /// DOES NOT RETURN UNTIL THE USER HAS ANSWERED, so a caller with a second
  /// thing to ask for does not stack two system dialogs. Returns at once where
  /// there is nothing to ask - already granted, or an OS with no such
  /// permission. The answer is read back with [notificationsAllowed].
  Future<void> requestNotifications();

  /// Whether the OS will let this app work off screen.
  ///
  /// Android: the battery-optimisation exemption - without it Doze and vendor
  /// task killers are free to stop the keep-alive. iOS: Background App
  /// Refresh, which is what gates `BGProcessingTask`; with it off, a queued
  /// transcript waits for the app to be opened and nothing else changes.
  Future<bool> backgroundWorkAllowed();

  /// Asks for what [backgroundWorkAllowed] reports.
  ///
  /// Android shows the OS dialog that grants the exemption. iOS has no API to
  /// ask - Background App Refresh is the user's own switch - so it opens
  /// Settings at this app's page, where that switch is.
  Future<void> requestBackgroundWork();

  /// Whether this phone has a vendor "autostart" page worth pointing at.
  /// True on Xiaomi (MIUI / HyperOS), which kills background apps that lack it
  /// whatever the other settings say. False on iOS.
  Future<bool> hasAutostartSettings();

  /// Opens that page, or the app's own settings where there is none. False
  /// when nothing could be opened.
  Future<bool> openAutostartSettings();

  /// iOS only: asks the system for a block of background CPU time on the terms
  /// in [request]. A no-op on Android, where the foreground service already
  /// keeps the process running and there is nothing to ask for.
  ///
  /// The system decides whether and when to grant it. Nothing may depend on
  /// the window arriving - see [BackgroundTaskPlan].
  Future<void> scheduleWork(BackgroundTaskRequest request);

  /// Withdraws a pending [scheduleWork] request.
  Future<void> cancelWork();

  /// Keeps the CPU awake while a transcription runs off screen.
  ///
  /// ANDROID ONLY, and only for inference. An incoming audio notification
  /// wakes the CPU by itself, so writing a note needs nothing; minutes of
  /// speech inference are different - once the delivering wake lock goes, the
  /// CPU is free to suspend and a job on a worker thread is frozen between
  /// packets. iOS has no equivalent and needs none: the `BGProcessingTask`
  /// window IS the assertion, and it is the system's to give.
  Future<void> holdCpu();

  /// Lets the CPU sleep again. Safe to call when nothing is held.
  Future<void> releaseCpu();

  /// Registers what the platform may call back with. Called once, at startup;
  /// a platform with none of these to give never calls any of them.
  ///
  /// [onGranted] (iOS) runs the work when the system grants a
  /// `BGProcessingTask` window, and must complete when the queue drains or the
  /// policy pauses it - iOS is told the task finished when it returns.
  /// [onExpiring] (iOS) comes moments before that window ends, and must stop
  /// the running job quickly: iOS kills an app that overruns.
  /// [onKeepAliveStopped] (Android) says the foreground service is not running
  /// after all - refused at start, or killed - so the caller must stop
  /// believing it is up and ask again.
  void listen({
    required Future<void> Function() onGranted,
    required void Function() onExpiring,
    required void Function() onKeepAliveStopped,
  });
}
