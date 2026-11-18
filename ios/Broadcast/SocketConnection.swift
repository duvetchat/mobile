import Foundation

/// The extension's end of flutter_webrtc's Unix socket (its
/// FlutterSocketConnection listens; this connects). Its streams run on a thread
/// of their own; [perform], [write] and the callbacks are on that thread.
final class SocketConnection: NSObject, StreamDelegate {
  /// The app closed its end, or the socket failed.
  var onClose: (() -> Void)?
  /// The socket can take more bytes.
  var onSpace: (() -> Void)?

  private let socketHandle: Int32
  private var address = sockaddr_un()
  private var input: InputStream?
  private var output: OutputStream?
  private var runLoop: CFRunLoop?
  private var closed = false

  init?(path: String) {
    socketHandle = socket(AF_UNIX, SOCK_STREAM, 0)
    guard socketHandle >= 0 else { return nil }
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < capacity else {
      Darwin.close(socketHandle)
      return nil
    }
    withUnsafeMutablePointer(to: &address.sun_path) {
      $0.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strncpy($0, path, capacity - 1) }
    }
    super.init()
  }

  /// Connects; false when nothing listens.
  func open() -> Bool {
    var address = self.address
    let status = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(socketHandle, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard status == 0 else {
      Darwin.close(socketHandle)
      return false
    }
    var read: Unmanaged<CFReadStream>?
    var write: Unmanaged<CFWriteStream>?
    CFStreamCreatePairWithSocket(kCFAllocatorDefault, socketHandle, &read, &write)
    guard let input = read?.takeRetainedValue() as InputStream?,
      let output = write?.takeRetainedValue() as OutputStream?
    else {
      Darwin.close(socketHandle)
      return false
    }
    input.setProperty(kCFBooleanTrue, forKey: Stream.PropertyKey(kCFStreamPropertyShouldCloseNativeSocket as String))
    output.setProperty(kCFBooleanTrue, forKey: Stream.PropertyKey(kCFStreamPropertyShouldCloseNativeSocket as String))
    self.input = input
    self.output = output

    let ready = DispatchSemaphore(value: 0)
    let thread = Thread { [weak self] in
      guard let self else { return }
      self.runLoop = CFRunLoopGetCurrent()
      for stream in [input, output] as [Stream] {
        stream.delegate = self
        stream.schedule(in: .current, forMode: .default)
        stream.open()
      }
      ready.signal()
      while !self.closed, RunLoop.current.run(mode: .default, before: .distantFuture) {}
    }
    thread.name = "chat.duvet.broadcast.socket"
    thread.qualityOfService = .userInitiated
    thread.start()
    ready.wait()
    return true
  }

  /// Runs [block] on the socket's thread.
  func perform(_ block: @escaping () -> Void) {
    guard let runLoop else { return }
    CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
    CFRunLoopWakeUp(runLoop)
  }

  /// Writes what the socket takes now; how much, or -1 on an error.
  func write(_ bytes: UnsafePointer<UInt8>, count: Int) -> Int {
    guard let output, output.hasSpaceAvailable else { return 0 }
    return output.write(bytes, maxLength: count)
  }

  func close() {
    perform { [weak self] in self?.shut(notify: false) }
  }

  private func shut(notify: Bool) {
    guard !closed else { return }
    closed = true
    for stream in [input, output].compactMap({ $0 as Stream? }) {
      stream.delegate = nil
      stream.remove(from: .current, forMode: .default)
      stream.close()
    }
    input = nil
    output = nil
    if let runLoop { CFRunLoopStop(runLoop) }
    if notify { onClose?() }
  }

  func stream(_ stream: Stream, handle event: Stream.Event) {
    switch event {
    case .hasSpaceAvailable:
      onSpace?()
    case .hasBytesAvailable:
      // The app sends nothing; read to see its end.
      var byte: UInt8 = 0
      if (stream as? InputStream)?.read(&byte, maxLength: 1) == 0 { shut(notify: true) }
    case .endEncountered, .errorOccurred:
      shut(notify: true)
    default:
      break
    }
  }
}
