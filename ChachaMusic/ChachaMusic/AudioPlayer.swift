import Foundation
import AVFoundation
import MediaPlayer
import Combine

final class AudioPlayerModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
  @Published var playlist: [Track] = []
  @Published var currentIndex: Int = 0
  @Published var isPlaying: Bool = false
  @Published var currentTime: Double = 0
  @Published var duration: Double = 0
  @Published var level: Double = 0
  @Published var volume: Float = 0.8

  private var player: AVAudioPlayer?
  private var timer: Timer?

  private var docsDir: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
  }
  private var playlistURL: URL { docsDir.appendingPathComponent("playlist.json") }

  var currentTrack: Track? {
    guard playlist.indices.contains(currentIndex) else { return nil }
    return playlist[currentIndex]
  }

  override init() {
    super.init()
    loadPlaylist()
    if playlist.isEmpty { installDemo() }
    setupSession()
    setupRemoteCommands()
    timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      self?.tick()
    }
  }

  private func tick() {
    guard let p = player else { return }
    currentTime = p.currentTime
    if p.isPlaying {
      p.updateMeters()
      let avg = p.averagePower(forChannel: 0)
      level = min(1.0, max(0.0, (avg + 60.0) / 60.0))
      updateNowPlaying()
    } else {
      level *= 0.9
    }
  }

  // MARK: - playlist persistence

  private func loadPlaylist() {
    guard let data = try? Data(contentsOf: playlistURL),
          let list = try? JSONDecoder().decode([Track].self, from: data) else { return }
    playlist = list
    if currentIndex >= playlist.count { currentIndex = 0 }
  }

  private func savePlaylist() {
    if let data = try? JSONEncoder().encode(playlist) {
      try? data.write(to: playlistURL, options: .atomic)
    }
  }

  private func installDemo() {
    guard let url = Bundle.main.url(forResource: "StarVoyage", withExtension: "wav") else { return }
    var dur = 34.0
    if let p = try? AVAudioPlayer(contentsOf: url) { dur = p.duration }
    playlist = [Track(id: UUID().uuidString, title: "星际漫游", artist: "茶茶 Demo", fileName: "StarVoyage.wav", isDemo: true, duration: dur)]
    savePlaylist()
  }

  private func trackURL(for track: Track) -> URL? {
    if track.isDemo {
      let base = (track.fileName as NSString).deletingPathExtension
      let ext = (track.fileName as NSString).pathExtension
      return Bundle.main.url(forResource: base, withExtension: ext)
    }
    return docsDir.appendingPathComponent(track.fileName)
  }

  // MARK: - playback

  func play(at index: Int) {
    guard playlist.indices.contains(index) else { return }
    let track = playlist[index]
    guard let url = trackURL(for: track) else { return }
    do {
      let p = try AVAudioPlayer(contentsOf: url)
      p.delegate = self
      p.isMeteringEnabled = true
      p.volume = volume
      p.prepareToPlay()
      p.play()
      player = p
      currentIndex = index
      duration = p.duration
      currentTime = 0
      isPlaying = true
      updateNowPlaying()
    } catch {
      print("play failed: \(error)")
      isPlaying = false
    }
  }

  func togglePlay() {
    if player == nil {
      if !playlist.isEmpty { play(at: currentIndex) }
      return
    }
    if isPlaying { pause() } else { resume() }
  }

  func resume() {
    player?.play()
    isPlaying = true
    updateNowPlaying()
  }

  func pause() {
    player?.pause()
    isPlaying = false
    updateNowPlaying()
  }

  func next() {
    guard !playlist.isEmpty else { return }
    play(at: (currentIndex + 1) % playlist.count)
  }

  func prev() {
    guard !playlist.isEmpty else { return }
    if currentTime > 3 {
      seek(to: 0)
      resume()
    } else {
      play(at: (currentIndex - 1 + playlist.count) % playlist.count)
    }
  }

  func seek(to seconds: Double) {
    guard let p = player else { return }
    p.currentTime = max(0, min(seconds, p.duration))
    currentTime = p.currentTime
    updateNowPlaying()
  }

  func setVolume(_ v: Float) {
    volume = v
    player?.volume = v
  }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    if flag { next() }
  }

  // MARK: - import / delete

  func importFile(from url: URL) {
    var dest = docsDir.appendingPathComponent(url.lastPathComponent)
    var n = 1
    while FileManager.default.fileExists(atPath: dest.path) {
      let base = url.deletingPathExtension().lastPathComponent
      dest = docsDir.appendingPathComponent("\(base) \(n).\(url.pathExtension)")
      n += 1
    }
    do {
      try FileManager.default.copyItem(at: url, to: dest)
      var dur = 0.0
      if let p = try? AVAudioPlayer(contentsOf: dest) { dur = p.duration }
      let t = Track(id: UUID().uuidString,
                    title: url.deletingPathExtension().lastPathComponent,
                    artist: "本地音乐",
                    fileName: dest.lastPathComponent,
                    isDemo: false,
                    duration: dur)
      playlist.append(t)
      savePlaylist()
    } catch {
      print("import failed: \(error)")
    }
  }

  func delete(at offsets: IndexSet) {
    let currentWasDeleted = offsets.contains(currentIndex)
    let beforeCount = offsets.filter { $0 < currentIndex }.count
    for idx in offsets.sorted(by: >) {
      playlist.remove(at: idx)
    }
    if playlist.isEmpty {
      player?.stop()
      player = nil
      isPlaying = false
      currentTime = 0
      duration = 0
      level = 0
    } else if currentWasDeleted {
      player?.stop()
      player = nil
      play(at: min(currentIndex, playlist.count - 1))
    } else {
      currentIndex = max(0, currentIndex - beforeCount)
      if currentIndex >= playlist.count { currentIndex = playlist.count - 1 }
    }
    savePlaylist()
  }

  // MARK: - session / remote / now playing

  private func setupSession() {
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      print("audio session failed: \(error)")
    }
  }

  private func setupRemoteCommands() {
    let center = MPRemoteCommandCenter.shared()
    center.playCommand.addTarget { [weak self] _ in
      self?.resume()
      return .success
    }
    center.pauseCommand.addTarget { [weak self] _ in
      self?.pause()
      return .success
    }
    center.nextTrackCommand.addTarget { [weak self] _ in
      self?.next()
      return .success
    }
    center.previousTrackCommand.addTarget { [weak self] _ in
      self?.prev()
      return .success
    }
  }

  private func updateNowPlaying() {
    guard let track = currentTrack else {
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
      return
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = [
      MPMediaItemPropertyTitle: track.title,
      MPMediaItemPropertyArtist: track.artist,
      MPMediaItemPropertyPlaybackDuration: duration,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
      MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
    ]
  }
}
