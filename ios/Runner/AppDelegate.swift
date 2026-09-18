import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// The channel behind `MethodChannelPlatformSettings`. Held so it outlives
  /// `didInitializeImplicitFlutterEngine`.
  private var settingsChannel: FlutterMethodChannel?

  /// The channel behind `MethodChannelDiskSpace`. Held for the same reason.
  private var storageChannel: FlutterMethodChannel?

  private static let settingsChannelName =
    "com.ganeshsharma.voicenotetaker_app/settings"

  private static let storageChannelName =
    "com.ganeshsharma.voicenotetaker_app/storage"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
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
  }
}
