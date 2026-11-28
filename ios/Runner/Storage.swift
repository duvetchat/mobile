import Flutter
import Foundation

/// The encryption database's folder out of the phone's backups (lib/e2e/core_gate.dart), on the chat.duvet/storage
/// channel: "exclude" takes a folder out of iCloud's and the computer's backups, and "excluded" says whether it is.
/// A folder's flag covers what it holds, and stays on it.
enum Storage {
  static func answer(on messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(name: "chat.duvet/storage", binaryMessenger: messenger).setMethodCallHandler { call, result in
      guard let path = call.arguments as? String else {
        return result(FlutterError(code: "storage", message: "\(call.method) takes a folder's path", details: nil))
      }
      var folder = URL(fileURLWithPath: path, isDirectory: true)
      do {
        switch call.method {
        case "exclude":
          var values = URLResourceValues()
          values.isExcludedFromBackup = true
          try folder.setResourceValues(values)
          result(nil)
        case "excluded":
          result(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        default:
          result(FlutterMethodNotImplemented)
        }
      } catch {
        result(FlutterError(code: "storage", message: error.localizedDescription, details: nil))
      }
    }
  }
}
