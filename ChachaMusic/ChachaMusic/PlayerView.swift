import SwiftUI

struct PlayerView: View {
  @EnvironmentObject var player: AudioPlayerModel

  var body: some View {
    ZStack {
      SciFiView(level: player.level)
        .ignoresSafeArea()
      VStack(spacing: 18) {
        VStack(spacing: 6) {
          Text("茶茶听音乐")
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .tracking(6)
            .foregroundColor(.cyan)
            .shadow(color: .cyan.opacity(0.8), radius: 8)
          Text("SCI-FI MUSIC CONSOLE")
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(.white.opacity(0.5))
            .tracking(3)
        }
        .padding(.top, 8)
        Spacer()
        VStack(spacing: 10) {
          Text(player.currentTrack?.title ?? "还没有音乐")
            .font(.system(size: 26, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .shadow(color: .cyan.opacity(0.6), radius: 12)
            .lineLimit(1)
          Text(player.currentTrack?.artist ?? "点下方音乐库导入你的音乐")
            .font(.system(size: 14))
            .foregroundColor(.white.opacity(0.7))
          VStack(spacing: 4) {
            Slider(value: Binding(
              get: { player.currentTime },
              set: { player.seek(to: $0) }
            ), in: 0...(player.duration > 0 ? player.duration : 1))
            .tint(.cyan)
            HStack {
              Text(fmt(player.currentTime))
              Spacer()
              Text(fmt(player.duration))
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.white.opacity(0.6))
          }
          HStack(spacing: 36) {
            Button { player.prev() } label: {
              Image(systemName: "backward.fill").font(.system(size: 26))
            }
            Button { player.togglePlay() } label: {
              Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 30))
                .frame(width: 76, height: 76)
                .background(Circle().fill(Color.cyan.opacity(0.25)))
                .overlay(Circle().stroke(Color.cyan, lineWidth: 2))
                .shadow(color: .cyan.opacity(0.9), radius: 18)
            }
            Button { player.next() } label: {
              Image(systemName: "forward.fill").font(.system(size: 26))
            }
          }
          .foregroundColor(.white)
          HStack(spacing: 10) {
            Image(systemName: "speaker.fill").font(.system(size: 12))
            Slider(value: Binding(
              get: { Double(player.volume) },
              set: { player.setVolume(Float($0)) }
            ), in: 0...1)
            .tint(.magenta)
            Image(systemName: "speaker.wave.3.fill").font(.system(size: 12))
          }
          .foregroundColor(.white.opacity(0.7))
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
      }
    }
  }

  private func fmt(_ t: Double) -> String {
    guard t.isFinite else { return "00:00" }
    return String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60)
  }
}
