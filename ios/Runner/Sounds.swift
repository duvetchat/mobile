import AVFoundation
import Flutter

/// The app's sounds on iOS (#228), on the chat.duvet/sounds channel: "play" a
/// sound's asset at a gain, once or looped, "stop" it, and "done" goes back to
/// Dart when one ends by itself.
///
/// AVAudioPlayer plays in the app's one audio session, which a call
/// (flutter_webrtc), a voice note (just_audio), a video and the recorder set
/// up for themselves and leave as it was once they're done. So:
///
/// - While Dart says one of them is on ("busy"), a sound plays in the session
///   as it is and changes nothing: it's heard in the call, over the call's
///   route. Their categories aren't muted by the ring/silent switch, so
///   neither is the sound then.
/// - Otherwise it borrows the session as ambient, the one category that mixes
///   with other apps' audio and that the ring/silent switch mutes, and puts
///   back what was there once the last sound ends, so a voice note or a video
///   later plays as it did before.
/// - A sound the user asked to hear ("aloud", a preview in the settings)
///   borrows it as playback mixing with others instead, which the switch
///   doesn't mute.
final class Sounds: NSObject, AVAudioPlayerDelegate {
  private let channel: FlutterMethodChannel

  /// A player per asset, kept: the next play of it starts at once.
  private var players: [String: AVAudioPlayer] = [:]

  /// The play each player is on, as Dart numbers them.
  private var plays: [ObjectIdentifier: Int] = [:]

  /// What the session was before a sound borrowed it.
  private var lent: (category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions)?

  /// What a sound made the session, until it's given back: by it the session is known to still be ours.
  private var held: (category: AVAudioSession.Category, options: AVAudioSession.CategoryOptions)?

  private var sounding: Bool { players.values.contains(where: \.isPlaying) }

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "chat.duvet/sounds", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "play":
        do {
          try self.play(args)
          result(nil)
        } catch {
          result(FlutterError(code: "sounds", message: error.localizedDescription, details: nil))
        }
      case "stop":
        if let asset = args["asset"] as? String, let player = self.players[asset] { self.end(player) }
        self.giveBack()
        result(nil)
      case "dispose":
        self.players.values.forEach(self.end)
        self.players.removeAll()
        self.giveBack()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    NotificationCenter.default.addObserver(
      self, selector: #selector(interrupted), name: AVAudioSession.interruptionNotification, object: nil)
  }

  private func play(_ args: [String: Any]) throws {
    guard let asset = args["asset"] as? String, let id = args["id"] as? Int else {
      throw NSError(domain: "chat.duvet.sounds", code: 1, userInfo: [NSLocalizedDescriptionKey: "play needs an asset and an id"])
    }
    let player = try players[asset] ?? load(asset)
    players[asset] = player
    // Its last play, if it's still going, gives way without a "done": Dart ended it.
    end(player)
    player.currentTime = 0
    player.volume = Float((args["gain"] as? Double) ?? 1)
    // AVAudioPlayer loops on the file's own frame count (the .m4a carries its priming and remainder), with no gap.
    player.numberOfLoops = args["loop"] as? Bool == true ? -1 : 0
    if args["busy"] as? Bool != true { try borrow(aloud: args["aloud"] as? Bool == true) }
    guard player.play() else {
      giveBack()
      throw NSError(domain: "chat.duvet.sounds", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(asset) didn't start"])
    }
    plays[ObjectIdentifier(player)] = id
  }

  private func load(_ asset: String) throws -> AVAudioPlayer {
    let key = FlutterDartProject.lookupKey(forAsset: asset)
    guard let path = Bundle.main.path(forResource: key, ofType: nil) else {
      throw NSError(domain: "chat.duvet.sounds", code: 3, userInfo: [NSLocalizedDescriptionKey: "\(asset) isn't in the bundle"])
    }
    let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
    player.delegate = self
    player.prepareToPlay()
    return player
  }

  private func end(_ player: AVAudioPlayer) {
    player.stop()
    plays[ObjectIdentifier(player)] = nil
  }

  /// Makes the session ambient for a sound outside a call, or playback mixing
  /// with others for one played aloud. Failing that the sound doesn't play: in
  /// another category it would stop other apps' audio, and sound with the
  /// switch on silent.
  private func borrow(aloud: Bool) throws {
    let session = AVAudioSession.sharedInstance()
    let was = (category: session.category, mode: session.mode, options: session.categoryOptions)
    let want: (category: AVAudioSession.Category, options: AVAudioSession.CategoryOptions) =
      aloud ? (.playback, [.mixWithOthers]) : (.ambient, [])
    if let held, held.category == was.category, held.options == was.options {
      // Ours already. A sound still playing keeps it as it borrowed it: a
      // mention during a preview doesn't mute the preview, and a preview
      // during the ring doesn't make the ring sound on silent.
      if sounding || held.category == want.category { return }
      try session.setCategory(want.category, mode: .default, options: want.options)
    } else {
      // Someone else's, and as a sound needs it already.
      if was.category == want.category, was.options.contains(want.options) { return }
      try session.setCategory(want.category, mode: .default, options: want.options)
      // Solo ambient is where every app starts, nobody's choice: ambient takes its place.
      lent = was.category != .soloAmbient ? was : aloud ? (.ambient, .default, []) : nil
    }
    held = want
  }

  /// Puts the session back as it was, once no sound plays.
  private func giveBack() {
    guard let held, !sounding else { return }
    let session = AVAudioSession.sharedInstance()
    // Nothing to put back, or someone took the session since (a call answered, a recording): it's theirs now.
    guard let was = lent, session.category == held.category, session.categoryOptions == held.options else {
      lent = nil
      self.held = nil
      return
    }
    // The session is active since the sound, and an active one taking a
    // category that doesn't mix stops other apps' audio there and then. So
    // while another app plays, the session is let go first. That fails while
    // something of the app's own still runs in it (a voice note or a video
    // begun during the sound), which it stops; then the session stays as
    // borrowed until the next sound ends.
    let mixes = was.category == .ambient || was.options.contains(.mixWithOthers)
    if !mixes, session.isOtherAudioPlaying {
      do { try session.setActive(false) } catch { return }
    }
    lent = nil
    self.held = nil
    try? session.setCategory(was.category, mode: was.mode, options: was.options)
  }

  private func finished(_ player: AVAudioPlayer) {
    if let id = plays.removeValue(forKey: ObjectIdentifier(player)) {
      channel.invokeMethod("done", arguments: id)
    }
    giveBack()
  }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    finished(player)
  }

  func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
    finished(player)
  }

  /// A phone call or an alarm took the audio: what played is over, not paused.
  @objc private func interrupted(_ notification: Notification) {
    guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      AVAudioSession.InterruptionType(rawValue: raw) == .began
    else { return }
    for player in players.values where plays[ObjectIdentifier(player)] != nil {
      player.stop()
      finished(player)
    }
  }
}
