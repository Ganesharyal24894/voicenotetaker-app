import '../../model/firmware_update.dart';
import '../../model/firmware_update_state.dart';
import '../format.dart';

/// Every word the recorder-update screens say, from the approved canvas
/// (`canvas-update/project/*.dc.html`, 2026-10-18). Strings the canvas does
/// not draw - a phone that is not next to the recorder, each way a run can
/// stop - are written in the same voice: plain, short, never blaming.
abstract final class UpdateCopy {
  // Today.
  static const String todayTitle = 'A recorder update is ready';
  static String todayMeta(FirmwareVersion version) =>
      'Version $version. Takes about 5 minutes on the charger.';

  // Recorder settings.
  static const String section = 'Recorder';
  static const String softwareTitle = 'Software';
  static const String checking = 'Checking…';
  static const String versionUnknown = 'Connect your recorder to see its version';
  static const String versionUnreadable = "Couldn't read your recorder's version";
  static String upToDate(FirmwareVersion installed) =>
      'Version $installed, up to date';
  static String updateReady(FirmwareVersion installed, FirmwareVersion next) =>
      'Version $installed. Update to $next ready';
  static String updating(FirmwareVersion next) => 'Updating to $next';
  static const String didNotFinishShort = "The last update didn't finish";

  // Ready and blocked.
  static const String title = 'Recorder update';
  static String published(FirmwareRelease release) {
    final at = release.publishedAt;
    return at == null
        ? 'Version ${release.version}'
        : 'Version ${release.version}, published ${Fmt.dayMonth(at.toLocal())}';
  }

  static const String whatsNew = "What's new";
  static const String beforeYouStart = 'Before you start';
  static const String onCharger = 'Recorder is on its charger';
  static const String putOnCharger = 'Put the recorder on its charger';
  static const String putOnChargerWhy = "So it can't run out of power halfway";
  static const String phoneNearby = 'Phone is next to it';
  static const String bringPhone = 'Bring your phone next to the recorder';
  static const String bringPhoneWhy = 'It needs to be connected to update';
  static const String takesAbout =
      "Takes about 5 minutes. The recorder doesn't save notes while it "
      'updates, and the app needs to stay open.';
  static const String cableOnly =
      "Your recorder's version couldn't be read, so it can't be updated from "
      'the phone.';
  static const String updateNow = 'Update now';
  static const String notNow = 'Not now';

  // Updating.
  static const String updatingTitle = 'Updating your recorder';
  static String versionLine(FirmwareVersion version) => 'Version $version';
  static const String preparing = 'Preparing';
  static const String sending = 'Sending';
  static const String whatsHappening = "What's happening";
  static const String stepUpdateMode = 'Recorder switched to update mode';
  static const String stepSending = 'Sending the new software';
  static const String stepRestart = 'Recorder restarts and reconnects';
  static const String keepOpen =
      'Keep the app open and the recorder on its charger. Its light stays off '
      'until the restart.';

  /// "About 3 minutes left", rounded up so it never promises too little.
  static String timeLeft(Duration left) {
    if (left < const Duration(minutes: 1)) return 'Less than a minute left';
    final minutes = (left.inSeconds / 60).ceil();
    return minutes == 1 ? 'About 1 minute left' : 'About $minutes minutes left';
  }

  // Done.
  static const String doneTitle = 'Your recorder is up to date';
  static String doneBody(FirmwareVersion version) =>
      'Version $version is running and notes are saving again.';
  static const String done = 'Done';
  static String nothingToDoBody(FirmwareVersion? version) => version == null
      ? 'There is no update for your recorder right now.'
      : 'Version $version is running.';

  // Failed.
  static const String failedTitle = "The update didn't finish";
  static const String tryAgain = 'Try again';
  static const String later = 'Later';
  static const String close = 'Close';
  static const String waitingTitle = 'Your recorder is waiting in update mode';
  static const String waitingBody =
      "It isn't saving notes right now. Keep it on the charger with the phone "
      'next to it and try again. The update starts over from the beginning.';
  static const String unchangedTitle = "Your recorder wasn't changed";
  static const String unchangedBody =
      "It's still running its current software and saving notes.";
  static const String notBackTitle = "Your recorder hasn't reconnected";
  static const String notBackBody =
      'The new software was sent. Give it a minute on the charger; it '
      'reconnects on its own when it has restarted.';
  static const String keepsFailing = 'If it keeps failing';
  // What the bootloader actually does while it waits for the phone: no
  // drive, no USB, only Bluetooth. The cable path only opens after the
  // recorder restarts, which on a sealed unit means a flat battery. So the
  // honest advice is to retry from here first.
  static const String usbFallback =
      'The recorder keeps waiting for this phone, so Try again is the way '
      'back. If it never finishes, it will restart once its battery runs '
      'down; plugged into a computer with a USB-C cable it then shows up as '
      'a drive named XIAO-SENSE, and the firmware can be copied onto it. '
      'Your notes are on this phone and nothing is lost.';

  /// The line under "The update didn't finish": what went wrong, in plain
  /// words. [droppedAt] is the last percent seen while sending, if any.
  static String failedReason(UpdateFailure reason, {int? droppedAt}) =>
      switch (reason) {
        UpdateFailure.transferFailed => droppedAt == null
            ? 'The connection dropped'
            : 'The connection dropped at $droppedAt%',
        UpdateFailure.bootloaderNotFound =>
          "The phone couldn't find your recorder",
        UpdateFailure.checksumMismatch =>
          "The download didn't arrive intact, so nothing was sent",
        UpdateFailure.triggerRefused =>
          'Put the recorder on its charger and try again',
        UpdateFailure.download =>
          "The update couldn't be downloaded. Check your internet connection",
        UpdateFailure.storage => "There wasn't room on this phone for the update",
        UpdateFailure.notConnected =>
          'Your recorder disconnected. Bring your phone next to it and try again',
        UpdateFailure.recorderDidNotRestart =>
          "Your recorder didn't switch to update mode",
        UpdateFailure.recorderDidNotReturn =>
          "Your recorder didn't reconnect after the update",
        UpdateFailure.versionMismatch =>
          "Your recorder restarted, but it isn't running the new version",
      };
}
