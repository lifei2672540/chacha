import SwiftUI

@main
struct ChachaMusicApp: App {
  @StateObject private var player = AudioPlayerModel()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(player)
        .preferredColorScheme(.dark)
    }
  }
}

struct ContentView: View {
  var body: some View {
    TabView {
      PlayerView()
        .tabItem { Label("播放", systemImage: "play.circle.fill") }
      LibraryView()
        .tabItem { Label("音乐库", systemImage: "music.note.list") }
    }
    .tint(.cyan)
  }
}
