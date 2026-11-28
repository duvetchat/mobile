import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var screenShare: ScreenShare?
  private var sounds: Sounds?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
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
