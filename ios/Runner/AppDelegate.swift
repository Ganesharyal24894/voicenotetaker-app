import BackgroundTasks
import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// The channel behind `MethodChannelPlatformSettings`. Held so it outlives
  /// `didInitializeImplicitFlutterEngine`.
  private var settingsChannel: FlutterMethodChannel?

  /// The channel behind `MethodChannelDiskSpace`. Held for the same reason.
  private var storageChannel: FlutterMethodChannel?

  /// The channel behind `MethodChannelBackgroundMode`. Held for the same
  /// reason, and because a `BGProcessingTask` that fires needs it: the task
  /// handler below calls INTO Dart on it.
  private var backgroundChannel: FlutterMethodChannel?

  private static let settingsChannelName =
    "com.ganeshsharma.voicenotetaker_app/settings"

  private static let storageChannelName =
    "com.ganeshsharma.voicenotetaker_app/storage"

  private static let backgroundChannelName =
    "com.ganeshsharma.voicenotetaker_app/background"

  /// Must match `BackgroundTaskPlan.transcribeTaskId` in Dart and the
  /// `BGTaskSchedulerPermittedIdentifiers` array in `Info.plist`. iOS raises
  /// if it is registered without being permitted there.
  private static let transcribeTaskId =
    "com.ganeshsharma.voicenotetaker_app.transcribe"

  /// The one local notification this app posts: "Notes not saving".
  private static let alertNotificationId =
    "com.ganeshsharma.voicenotetaker_app.notSaving"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // BEFORE `super`, AND BEFORE LAUNCH ENDS. Apple: "Register all of the
    // tasks before the end of the app launch sequence." A registration that
    // happens later is refused, and the window this app asks for would never
    // be delivered.
    _ = BGTaskScheduler.shared.register(
      forTaskWithIdentifier: AppDelegate.transcribeTaskId,
      using: nil  // nil means the main queue, which is where Flutter channels live.
    ) { [weak self] task in
      guard let self, let processing = task as? BGProcessingTask else {
        task.setTaskCompleted(success: false)
        return
      }
      self.runTranscribeWindow(processing)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // ---------------------------------------------------------------------------
  // THE BACKGROUND WINDOW
  //
  // iOS grants minutes of CPU through `BGProcessingTask`, and only while the
  // phone is idle; it ends the task the moment the user picks the phone up.
  // Dart is handed the window and answers when the queue has drained or the
  // policy has paused it - see `AppController._runBackgroundWindow`.
  //
  // THE ONE RULE HERE IS THAT `setTaskCompleted` IS ALWAYS CALLED, exactly
  // once. An app that overruns its window is killed by the system, and this
  // one is the user's voice recorder.
  // ---------------------------------------------------------------------------

  private func runTranscribeWindow(_ task: BGProcessingTask) {
    guard let channel = backgroundChannel else {
      // Launched into the background with no Flutter engine yet - there is
      // nothing that can do the work. Hand the window straight back rather
      // than hold it for nothing.
      task.setTaskCompleted(success: false)
      return
    }

    var finished = false
    let finish: (Bool) -> Void = { success in
      if finished { return }
      finished = true
      task.setTaskCompleted(success: success)
    }

    task.expirationHandler = {
      DispatchQueue.main.async {
        channel.invokeMethod("workExpiring", arguments: nil)
        // Dart stops at its next check, which is between jobs. If it has not
        // answered by then, end the task here: being late is fatal, and a
        // half-finished transcript is simply queued again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { finish(false) }
      }
    }

    channel.invokeMethod("runWork", arguments: nil) { _ in
      finish(true)
    }
  }

  // ---------------------------------------------------------------------------
  // WHAT THE BACKGROUND CHANNEL ANSWERS ON AN IPHONE
  //
  // Nothing here keeps the app alive - the `bluetooth-central` background mode
  // in Info.plist does that on its own, for Bluetooth events only, and there
  // is nothing to start and nothing for the user to grant. What is here is the
  // two things iOS does ask for: permission to tell the wearer their notes
  // stopped saving, and a request for CPU time to finish transcripts.
  // ---------------------------------------------------------------------------

  private func handleBackgroundCall(
    _ call: FlutterMethodCall, _ result: @escaping FlutterResult
  ) {
    let arguments = call.arguments as? [String: Any]
    switch call.method {
    case "start":
      // iOS has no persistent "listening" notification and wants none: the
      // ordinary status line is not news. Only an alert is posted.
      if arguments?["alert"] as? Bool == true {
        postAlert(
          title: arguments?["title"] as? String ?? "Notes not saving",
          body: arguments?["text"] as? String ?? "")
      } else {
        withdrawAlert()
      }
      // Nothing here can be refused, so the keep-alive is never "not running".
      result(true)

    case "stop":
      withdrawAlert()
      result(nil)

    case "notificationsAllowed":
      UNUserNotificationCenter.current().getNotificationSettings { settings in
        let allowed =
          settings.authorizationStatus == .authorized
          || settings.authorizationStatus == .provisional
          || settings.authorizationStatus == .ephemeral
        DispatchQueue.main.async { result(allowed) }
      }

    case "requestNotifications":
      // ANSWERS ONLY WHEN THE USER HAS ANSWERED. The Dart side raises a second
      // ask straight after this one, and two system prompts at once is one the
      // user never sees.
      //
      // AND A SECOND ASK IS NOT A PROMPT. iOS shows the notification prompt
      // once per install; after that `requestAuthorization` returns "no"
      // without showing anything. A button that looks like it asks and does
      // nothing is worse than one that takes you where the switch is, so a
      // previous "don't allow" opens Settings instead.
      UNUserNotificationCenter.current().getNotificationSettings { settings in
        DispatchQueue.main.async {
          guard settings.authorizationStatus != .denied else {
            self.openAppSettings { _ in result(nil) }
            return
          }
          UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in
              DispatchQueue.main.async { result(nil) }
            }
        }
      }

    case "backgroundWorkAllowed":
      // Background App Refresh. Apple: a scheduler submission fails with
      // `BGTaskScheduler.Error.Code.unavailable` when "a person disabled
      // background refresh in settings", so this is what gates the window.
      // `restricted` is a managed device and cannot be changed by the user;
      // Apple says not to nag about it, so it counts as allowed and the ask
      // below is never raised.
      let status = UIApplication.shared.backgroundRefreshStatus
      result(status == .available || status == .restricted)

    case "requestBackgroundWork":
      // There is no API to ask. Background App Refresh is the user's own
      // switch, and this app's Settings page is where it is.
      openAppSettings { _ in result(nil) }

    case "hasAutostartSettings":
      // A vendor Android idea. iPhones have no such page.
      result(false)

    case "openAutostartSettings":
      openAppSettings { opened in result(opened) }

    case "scheduleWork":
      scheduleTranscribeWindow(arguments, result)

    case "cancelWork":
      BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: AppDelegate.transcribeTaskId)
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func scheduleTranscribeWindow(
    _ arguments: [String: Any]?, _ result: @escaping FlutterResult
  ) {
    let request = BGProcessingTaskRequest(identifier: AppDelegate.transcribeTaskId)
    request.requiresExternalPower = arguments?["externalPower"] as? Bool ?? true
    request.requiresNetworkConnectivity = arguments?["network"] as? Bool ?? false
    let after = arguments?["afterSeconds"] as? Int ?? 900
    // A floor, never a promise: iOS runs the task when the phone is idle, or
    // not at all. Dart is written so that it never matters which.
    request.earliestBeginDate = Date(timeIntervalSinceNow: TimeInterval(after))
    do {
      // Submitting replaces an unexecuted request with the same identifier, so
      // this is safe to call every time the app leaves the screen.
      try BGTaskScheduler.shared.submit(request)
      result(nil)
    } catch {
      // `unavailable` when Background App Refresh is off, and always on the
      // Simulator. The Dart side treats a refusal as "no window this time";
      // the queue still runs when the app is opened.
      result(
        FlutterError(
          code: "scheduleFailed", message: "\(error)", details: nil))
    }
  }

  // ---------------------------------------------------------------------------
  // THE ALERT
  //
  // An app that is not on screen cannot make an iPhone vibrate - there is no
  // API for it. A local notification is the only way to tell the wearer that
  // their recorder dropped and notes are being lost, and Apple names exactly
  // this case: "a background app could ask the system to display an alert when
  // your app finishes a particular task".
  //
  // One notification, one identifier, replaced in place - never a pile of them
  // for a link that flaps. `NotSavingAlertPolicy` in Dart decides when.
  // ---------------------------------------------------------------------------

  private func postAlert(title: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    let request = UNNotificationRequest(
      identifier: AppDelegate.alertNotificationId,
      content: content,
      // No trigger: Apple delivers it right away.
      trigger: nil)
    UNUserNotificationCenter.current().add(request) { _ in }
  }

  private func withdrawAlert() {
    let centre = UNUserNotificationCenter.current()
    centre.removePendingNotificationRequests(
      withIdentifiers: [AppDelegate.alertNotificationId])
    centre.removeDeliveredNotifications(
      withIdentifiers: [AppDelegate.alertNotificationId])
  }

  /// Opens this app's page in Settings, where its permission switches live.
  private func openAppSettings(_ done: @escaping (Bool) -> Void) {
    guard let url = URL(string: UIApplication.openSettingsURLString) else {
      done(false)
      return
    }
    UIApplication.shared.open(url, options: [:]) { opened in done(opened) }
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    guard
      let registrar = engineBridge.pluginRegistry.registrar(
        forPlugin: "VoiceNotetakerPlatformSettings")
    else { return }

    let channel = FlutterMethodChannel(
      name: AppDelegate.settingsChannelName,
      binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      switch call.method {
      // BOTH cases open THIS APP's Settings page, and that is not an
      // oversight. `UIApplication.openSettingsURLString` is the only public
      // deep link into Settings iOS offers; the Bluetooth page is reachable
      // only through the private `App-Prefs:root=Bluetooth` scheme, which apps
      // have been rejected for. The app's own page carries its Bluetooth
      // permission switch and is one tap from the top of Settings, where the
      // radio toggle lives - see `PlatformSettings` in the Dart layer, which
      // documents the same limit.
      case "openBluetoothSettings", "openAppSettings":
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
          result(false)
          return
        }
        UIApplication.shared.open(url, options: [:]) { opened in
          result(opened)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    settingsChannel = channel

    // Free space, which Dart has no API for. A model download asks before it
    // starts, so an iPhone with no room says so in a sentence instead of
    // filling up and failing 197 MB later.
    let storage = FlutterMethodChannel(
      name: AppDelegate.storageChannelName,
      binaryMessenger: registrar.messenger())
    storage.setMethodCallHandler { call, result in
      switch call.method {
      case "freeBytes":
        let arguments = call.arguments as? [String: Any]
        let path =
          (arguments?["path"] as? String)
          ?? NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)
            .first ?? NSHomeDirectory()
        do {
          let attributes = try FileManager.default.attributesOfFileSystem(forPath: path)
          // `systemFreeSize` is an NSNumber of bytes. Flutter carries it to
          // Dart as an int, which is what `freeBytesFor` returns.
          result((attributes[.systemFreeSize] as? NSNumber)?.int64Value)
        } catch {
          // A path iOS will not report on is "nothing known about the disk",
          // not an error worth failing a download over.
          result(nil)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    storageChannel = storage

    // Keeping work going off screen: the alert, the two permissions and the
    // `BGProcessingTask` window. See `handleBackgroundCall`.
    let background = FlutterMethodChannel(
      name: AppDelegate.backgroundChannelName,
      binaryMessenger: registrar.messenger())
    background.setMethodCallHandler { [weak self] call, result in
      // A Flutter result MUST be answered, once. An unanswered call leaves
      // Dart waiting forever - and one of these is `runWork`, which iOS is
      // timing.
      guard let self else {
        result(nil)
        return
      }
      self.handleBackgroundCall(call, result)
    }
    backgroundChannel = background
  }
}
