import CoreImage
import ReplayKit

/// Sends the screen's frames as flutter_webrtc's FlutterSocketConnectionFrameReader
/// reads them: an HTTP message with Content-Length, Buffer-Width,
/// Buffer-Height and Buffer-Orientation headers and a JPEG body. One frame at a
/// time: frames that come while one is being sent are dropped.
final class SampleUploader {
  // The extension may use 50 MB; half the screen's size keeps a frame small.
  private static let scale: CGFloat = 0.5
  private static let context = CIContext(options: [.cacheIntermediates: false])

  private let connection: SocketConnection
  private let encoding = DispatchQueue(label: "chat.duvet.broadcast.encode", qos: .userInitiated)
  private let lock = NSLock()
  private var busy = false
  // On the socket's thread: the frame being written and how far.
  private var pending: Data?
  private var sent = 0

  init(connection: SocketConnection) {
    self.connection = connection
    connection.onSpace = { [weak self] in self?.flush() }
  }

  func send(_ sampleBuffer: CMSampleBuffer) {
    lock.lock()
    defer { lock.unlock() }
    guard !busy, let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    busy = true
    let orientation = Self.orientation(of: sampleBuffer)
    encoding.async { [weak self] in
      guard let self else { return }
      guard let frame = Self.frame(of: image, orientation: orientation) else {
        self.done()
        return
      }
      self.connection.perform {
        self.pending = frame
        self.sent = 0
        self.flush()
      }
    }
  }

  private func done() {
    lock.lock()
    busy = false
    lock.unlock()
  }

  // On the socket's thread.
  private func flush() {
    guard let data = pending else { return }
    let written = data.withUnsafeBytes { raw -> Int in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
      return connection.write(base + sent, count: data.count - sent)
    }
    if written < 0 {
      // The socket closes, and the connection says so.
      pending = nil
      done()
      return
    }
    sent += written
    if sent >= data.count {
      pending = nil
      done()
    }
  }

  private static func orientation(of sampleBuffer: CMSampleBuffer) -> CGImagePropertyOrientation {
    let value = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil)
    return (value as? NSNumber).flatMap { CGImagePropertyOrientation(rawValue: $0.uint32Value) } ?? .up
  }

  private static func frame(of buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> Data? {
    let image = CIImage(cvPixelBuffer: buffer).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let jpeg = context.jpegRepresentation(
        of: image, colorSpace: colorSpace,
        options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.8])
    else { return nil }
    let message = CFHTTPMessageCreateResponse(nil, 200, nil, kCFHTTPVersion1_1).takeRetainedValue()
    let headers = [
      "Content-Length": "\(jpeg.count)",
      "Buffer-Width": "\(Int(image.extent.width))",
      "Buffer-Height": "\(Int(image.extent.height))",
      "Buffer-Orientation": "\(orientation.rawValue)",
    ]
    for (name, value) in headers {
      CFHTTPMessageSetHeaderFieldValue(message, name as CFString, value as CFString)
    }
    CFHTTPMessageSetBody(message, jpeg as CFData)
    return CFHTTPMessageCopySerializedMessage(message)?.takeRetainedValue() as Data?
  }
}
