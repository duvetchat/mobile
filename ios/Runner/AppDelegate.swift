import Flutter
import UIKit
import flutter_secure_storage_darwin
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var screenShare: ScreenShare?
  private var sounds: Sounds?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // The session's renewal while the app sits closed (lib/push/renewal.dart): BGTaskScheduler takes a task's launch
    // handler only before the app's launch ends, so it's registered here, under the identifier Info.plist permits and
    // Dart schedules (renewalTask). Each run asks for the next one renewalEvery's 4 hours later at the soonest, and iOS
    // runs it when it chooses. The task's engine reads and writes the session, and gets the Keychain's plugin alone:
    // none of the app's audio, calls or notifications start there.
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      if let registrar = registry.registrar(forPlugin: "FlutterSecureStorageDarwinPlugin") {
        FlutterSecureStorageDarwinPlugin.register(with: registrar)
      }
    }
    WorkmanagerPlugin.registerPeriodicTask(
      withIdentifier: "renew-session", earliestBeginInSeconds: NSNumber(value: 14400))
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ScreenShare") {
      screenShare = ScreenShare(messenger: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "Sounds") {
      sounds = Sounds(messenger: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "Storage") {
      Storage.answer(on: registrar.messenger())
    }
    // The phone's model, «iPhone» or «iPad», which names this installation's device among the user's
    // (lib/e2e/bootstrap.dart), as MainActivity.kt answers Android's.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "Device") {
      FlutterMethodChannel(name: "chat.duvet/device", binaryMessenger: registrar.messenger()).setMethodCallHandler {
        call, result in
        if call.method == "model" {
          result(UIDevice.current.model)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }
}
