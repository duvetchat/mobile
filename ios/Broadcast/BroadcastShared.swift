import Foundation

/// What the broadcast extension and the app share, compiled into both: the app
/// group's socket flutter_webrtc listens on, and the Darwin notifications they
/// tell each other with.
enum BroadcastShared {
  static let appGroup = "group.chat.duvet"

  /// flutter_webrtc's kRTCScreensharingSocketFD in the group's container.
  static var socketPath: String? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
      .appendingPathComponent("rtc_SSFD").path
  }

  enum Note: String, CaseIterable {
    /// The extension started sending frames.
    case started = "chat.duvet.broadcast.started"
    /// The extension stopped: from the status bar, Control Center, or a stop.
    case stopped = "chat.duvet.broadcast.stopped"
    /// The app stopped sharing.
    case stop = "chat.duvet.broadcast.stop"
  }

  private static let center = CFNotificationCenterGetDarwinNotifyCenter()
  // Darwin notifications carry no object; this stands for the one observer.
  private static let token = NSObject()
  private static var observer: UnsafeRawPointer { UnsafeRawPointer(Unmanaged.passUnretained(token).toOpaque()) }
  private static var handlers: [Note: () -> Void] = [:]

  static func post(_ note: Note) {
    CFNotificationCenterPostNotification(center, CFNotificationName(note.rawValue as CFString), nil, nil, true)
  }

  /// Calls [handler] on the main queue on each [note], in place of the last one.
  static func observe(_ note: Note, _ handler: @escaping () -> Void) {
    DispatchQueue.main.async {
      if handlers.updateValue(handler, forKey: note) != nil { return }
      CFNotificationCenterAddObserver(
        center, observer,
        { _, _, name, _, _ in
          guard let raw = name?.rawValue as String?, let note = Note(rawValue: raw) else { return }
          DispatchQueue.main.async { BroadcastShared.handlers[note]?() }
        }, note.rawValue as CFString, nil, .deliverImmediately)
    }
  }

  static func unobserveAll() {
    DispatchQueue.main.async {
      handlers.removeAll()
      CFNotificationCenterRemoveEveryObserver(center, observer)
    }
  }
}
