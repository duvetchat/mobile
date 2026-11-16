import ReplayKit

/// The broadcast upload extension that shares the whole screen in a call
/// (#264). iOS runs it from the broadcast picker the app opens; it sends each
/// frame over a socket in the app group to flutter_webrtc's
/// FlutterSocketConnectionFrameReader, which feeds the call's screen track.
///
/// It tells the app when it starts and stops, and stops when the app stops
/// sharing: the app closes the socket, or says so.
final class SampleHandler: RPBroadcastSampleHandler {
  private var connection: SocketConnection?
  private var uploader: SampleUploader?

  // iOS shows these under "Screen Broadcast Stopped".
  private static let stoppedMessage = "You stopped sharing your screen in Duvet."
  private static let notSharingMessage = "Share your screen from a call in Duvet."

  override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
    // Nothing listens when it's started from Control Center, with no call asking.
    guard let path = BroadcastShared.socketPath, let connection = SocketConnection(path: path), connection.open()
    else {
      finish(Self.notSharingMessage)
      return
    }
    connection.onClose = { [weak self] in self?.finish(Self.stoppedMessage) }
    self.connection = connection
    uploader = SampleUploader(connection: connection)
    BroadcastShared.observe(.stop) { [weak self] in self?.finish(Self.stoppedMessage) }
    BroadcastShared.post(.started)
  }

  override func broadcastFinished() {
    close()
  }

  override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
    guard sampleBufferType == .video else { return }
    uploader?.send(sampleBuffer)
  }

  private func finish(_ message: String) {
    close()
    finishBroadcastWithError(
      NSError(domain: "chat.duvet.broadcast", code: 0, userInfo: [NSLocalizedDescriptionKey: message]))
  }

  // Once, however it stops: the app hears it, and nothing more is sent.
  private func close() {
    guard let connection else { return }
    self.connection = nil
    uploader = nil
    BroadcastShared.unobserveAll()
    connection.close()
    BroadcastShared.post(.stopped)
  }
}
