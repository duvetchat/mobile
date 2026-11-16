import Flutter

/// The app's side of sharing the screen on iOS (#264), on the chat.duvet/screen
/// channel that starts Android's screen capture service. "stop" tells the
/// broadcast extension (ios/Broadcast) to stop; its "started" and "stopped"
/// come back to Dart.
final class ScreenShare {
  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "chat.duvet/screen", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "stop":
        BroadcastShared.post(.stop)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    BroadcastShared.observe(.started) { [weak self] in self?.channel.invokeMethod("started", arguments: nil) }
    BroadcastShared.observe(.stopped) { [weak self] in self?.channel.invokeMethod("stopped", arguments: nil) }
  }
}
