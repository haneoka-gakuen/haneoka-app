import AVFoundation
import ImageIO
import MediaPlayer
import UIKit

enum PlaybackMode: String, Codable {
  case sequential
  case repeatAll = "repeat-all"
  case repeatOne = "repeat-one"
  case shuffle
}

struct PlaybackTrack: Codable {
  let queueId: String
  let id: String
  let title: String
  let artist: String
  let url: String
  let source: URL
  let songKey: String?
  let titleLanguage: String?
  let cover: String
  let artwork: URL?
  let detailPath: String?
}

struct PlaybackArgs: Decodable {
  enum Action: String, Decodable {
    case state, configure, play, pause, toggle, seek, next, previous, mode, volume, clear
  }
  let action: Action
  let queueRevision: String?
  let queue: [PlaybackTrack]?
  let index: Int?
  let position: Double?
  let playing: Bool?
  let mode: PlaybackMode?
  let volume: Float?
}

struct PlaybackState: Encodable {
  let queue: [PlaybackTrack]?
  let queueRevision: String
  let index: Int
  let position: Double
  let duration: Double
  let playing: Bool
  let mode: PlaybackMode
  let volume: Float
}

final class Playback {
  static let shared = Playback()

  private let player = AVPlayer()
  private let audioSession = AVAudioSession.sharedInstance()
  private let commands = MPRemoteCommandCenter.shared()
  private var queue: [PlaybackTrack] = []
  private var revision = "empty"
  private var index = -1
  private var mode = PlaybackMode.repeatAll
  private var wantsPlayback = false
  private var resumeAfterInterruption = false
  private var audioSessionActive = false
  private var remoteTargets: [(MPRemoteCommand, Any)] = []
  private var pendingPosition: Double?
  private var seekGeneration = 0
  private var itemStatus: NSKeyValueObservation?
  private var timeControl: NSKeyValueObservation?
  private let artworkCache = NSCache<NSURL, UIImage>()
  private var artworkURL: URL?
  private var artworkTask: URLSessionDataTask?

  private var track: PlaybackTrack? { queue.indices.contains(index) ? queue[index] : nil }
  private var position: Double { pendingPosition ?? seconds(player.currentTime()) }
  private var duration: Double { player.currentItem.map { seconds($0.duration) } ?? 0 }

  private init() {
    player.actionAtItemEnd = .none
    artworkCache.countLimit = 12
    timeControl = player.observe(\.timeControlStatus, options: .new) { [weak self] _, _ in
      DispatchQueue.main.async { self?.publish() }
    }
    let notifications = NotificationCenter.default
    notifications.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] event in
      guard let self = self, let item = event.object as? AVPlayerItem,
            item === self.player.currentItem, self.wantsPlayback else { return }
      self.advance(forward: true, automatic: true, playing: true)
    }
    notifications.addObserver(forName: AVAudioSession.interruptionNotification, object: audioSession, queue: .main) { [weak self] event in
      self?.interruption(event)
    }
    notifications.addObserver(forName: AVAudioSession.routeChangeNotification, object: audioSession, queue: .main) { [weak self] event in
      if event.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ==
          AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
        self?.pause()
      }
    }
  }

  func dispatch(_ args: PlaybackArgs) throws -> PlaybackState {
    switch args.action {
    case .state: break
    case .configure:
      guard let queue = args.queue, !queue.isEmpty else { throw PlaybackError.invalidQueue }
      try configure(queue, args: args)
    case .play: try play()
    case .pause: pause()
    case .toggle: if wantsPlayback { pause() } else { try play() }
    case .seek: if let position = args.position { seek(position) }
    case .next: advance(forward: true, playing: true)
    case .previous: advance(forward: false, playing: true)
    case .mode: if let mode = args.mode { self.mode = mode }
    case .volume: if let volume = args.volume { player.volume = min(max(volume, 0), 1) }
    case .clear: clear()
    }
    return PlaybackState(
      queue: args.queueRevision == revision ? nil : queue,
      queueRevision: revision, index: index, position: position, duration: duration,
      playing: wantsPlayback, mode: mode, volume: player.volume)
  }

  private func configure(_ tracks: [PlaybackTrack], args: PlaybackArgs) throws {
    let current = track
    let match = tracks.firstIndex { $0.queueId == current?.queueId && $0.source == current?.source }
    let target = min(max(args.index ?? match ?? index, 0), tracks.count - 1)
    let playing = args.playing ?? wantsPlayback
    if let mode = args.mode { self.mode = mode }
    if let volume = args.volume { player.volume = min(max(volume, 0), 1) }
    queue = tracks
    revision = UUID().uuidString
    index = target
    if match != target || player.currentItem?.status == .failed {
      prepare(position: args.position ?? 0)
    } else if let position = args.position {
      seek(position)
    }
    if !remoteTargets.isEmpty { commands.nextTrackCommand.isEnabled = queue.count > 1 }
    if playing { try play() } else { pause() }
  }

  private func prepare(position: Double) {
    guard let track = track else { return }
    let item = AVPlayerItem(url: track.source)
    pendingPosition = position > 0 ? position : nil
    player.replaceCurrentItem(with: item)
    itemStatus = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
      DispatchQueue.main.async {
        guard let self = self, item === self.player.currentItem else { return }
        if item.status == .readyToPlay, let position = self.pendingPosition {
          self.seek(position)
        } else if item.status == .failed {
          self.pendingPosition = nil
          self.pause()
        }
        self.publish()
      }
    }
    publish()
  }

  private func play() throws {
    guard track != nil else { return }
    if player.currentItem?.status == .failed { prepare(position: position) }
    if !audioSessionActive {
      try audioSession.setCategory(.playback, mode: .default)
      try audioSession.setActive(true)
      audioSessionActive = true
    }
    if remoteTargets.isEmpty { attachRemoteCommands() }
    commands.nextTrackCommand.isEnabled = queue.count > 1
    wantsPlayback = true
    if pendingPosition == nil { player.play() }
    publish()
  }

  private func resume() {
    do { try play() } catch { pause() }
  }

  private func pause() {
    resumeAfterInterruption = false
    wantsPlayback = false
    player.pause()
    publish()
  }

  private func seek(_ seconds: Double) {
    guard let item = player.currentItem else { return }
    let target = min(max(seconds, 0), duration > 0 ? duration : Double.greatestFiniteMagnitude)
    pendingPosition = target
    guard item.status == .readyToPlay else { return }
    seekGeneration += 1
    let generation = seekGeneration
    player.seek(to: CMTime(seconds: target, preferredTimescale: 1_000),
                toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak item] _ in
      DispatchQueue.main.async {
        guard let self = self, item === self.player.currentItem,
              self.seekGeneration == generation else { return }
        self.pendingPosition = nil
        if self.wantsPlayback { self.player.play() }
        self.publish()
      }
    }
    publish()
  }

  private func advance(forward: Bool, automatic: Bool = false, playing: Bool) {
    guard !queue.isEmpty else { return }
    let repeatsTrack = mode == .repeatOne || (queue.count == 1 && mode != .sequential)
    if (automatic && repeatsTrack) || (!forward && position > 3) {
      seek(0)
      if playing { resume() }
      return
    }
    if automatic && mode == .sequential && index == queue.count - 1 {
      pause()
      seek(0)
      return
    }
    if forward && mode == .shuffle && queue.count > 1 {
      let choice = Int.random(in: 0..<(queue.count - 1))
      index = choice < index ? choice : choice + 1
    } else {
      index = (index + (forward ? 1 : -1) + queue.count) % queue.count
    }
    prepare(position: 0)
    if playing { resume() } else { pause() }
  }

  private func clear() {
    pause()
    queue = []
    revision = UUID().uuidString
    index = -1
    pendingPosition = nil
    itemStatus = nil
    player.replaceCurrentItem(with: nil)
    if audioSessionActive {
      try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
      audioSessionActive = false
    }
    loadArtwork(nil)
    if !remoteTargets.isEmpty {
      remoteTargets.forEach { $0.0.removeTarget($0.1) }
      remoteTargets = []
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
  }

  private func interruption(_ notification: Notification) {
    guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
    if type == .began {
      let wasPlaying = wantsPlayback
      pause()
      resumeAfterInterruption = wasPlaying
      audioSessionActive = false
    } else {
      let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
      if resumeAfterInterruption && AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
        resume()
      }
      resumeAfterInterruption = false
    }
  }

  private func register(_ command: MPRemoteCommand, run: @escaping (Playback, MPRemoteCommandEvent) -> Void) {
    command.isEnabled = true
    let target = command.addTarget { [weak self] event in
      guard let self = self else { return .commandFailed }
      DispatchQueue.main.async {
        if self.track != nil { run(self, event) }
      }
      return .success
    }
    remoteTargets.append((command, target))
  }

  private func attachRemoteCommands() {
    register(commands.playCommand) { player, _ in player.resume() }
    register(commands.pauseCommand) { player, _ in player.pause() }
    register(commands.togglePlayPauseCommand) { player, _ in
      if player.wantsPlayback { player.pause() } else { player.resume() }
    }
    register(commands.nextTrackCommand) { player, _ in
      player.advance(forward: true, playing: player.wantsPlayback)
    }
    register(commands.previousTrackCommand) { player, _ in
      player.advance(forward: false, playing: player.wantsPlayback)
    }
    register(commands.changePlaybackPositionCommand) { player, event in
      if let event = event as? MPChangePlaybackPositionCommandEvent { player.seek(event.positionTime) }
    }
  }

  private func publish() {
    guard !remoteTargets.isEmpty, let track = track else { return }
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: track.title,
      MPMediaItemPropertyArtist: track.artist,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
      MPNowPlayingInfoPropertyPlaybackRate: player.timeControlStatus == .playing ? player.rate : 0,
    ]
    if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
    if let url = track.artwork, let image = artworkCache.object(forKey: url as NSURL) {
      info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    loadArtwork(track.artwork)
  }

  private func loadArtwork(_ url: URL?) {
    guard url != artworkURL else { return }
    artworkTask?.cancel()
    artworkTask = nil
    artworkURL = url
    guard let url = url, artworkCache.object(forKey: url as NSURL) == nil else { return }
    artworkTask = URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
      guard let data = data, data.count <= 8 * 1_024 * 1_024,
            let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceCreateThumbnailWithTransform: true,
              kCGImageSourceThumbnailMaxPixelSize: 512,
            ] as CFDictionary) else { return }
      DispatchQueue.main.async {
        guard let self = self, self.artworkURL == url else { return }
        self.artworkCache.setObject(UIImage(cgImage: image), forKey: url as NSURL)
        self.publish()
      }
    }
    artworkTask?.resume()
  }

  private func seconds(_ time: CMTime) -> Double {
    time.seconds.isFinite ? max(0, time.seconds) : 0
  }

  private enum PlaybackError: Error { case invalidQueue }
}
