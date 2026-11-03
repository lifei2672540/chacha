import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
  @EnvironmentObject var player: AudioPlayerModel
  @State private var showPicker = false

  var body: some View {
    NavigationStack {
      List {
        ForEach(player.playlist) { track in
          Button {
            if let idx = player.playlist.firstIndex(of: track) { player.play(at: idx) }
          } label: {
            HStack {
              Image(systemName: track.isDemo ? "sparkles" : "music.note")
                .foregroundColor(track.isDemo ? .pink : .cyan)
              VStack(alignment: .leading, spacing: 2) {
                Text(track.title).lineLimit(1)
                Text(track.artist).font(.caption).foregroundColor(.secondary)
              }
              Spacer()
              if player.currentTrack?.id == track.id {
                Image(systemName: "waveform").foregroundColor(.cyan)
              }
              Text(fmt(track.duration)).font(.system(.caption, design: .monospaced)).foregroundColor(.secondary)
            }
          }
          .listRowBackground(Color.white.opacity(0.04))
        }
        .onDelete { player.delete(at: $0) }
      }
      .listStyle(.plain)
      .navigationTitle("音乐库")
      .toolbar {
        Button { showPicker = true } label: {
          Image(systemName: "plus")
        }
      }
      .sheet(isPresented: $showPicker) {
        DocumentPicker { url in
          player.importFile(from: url)
          showPicker = false
        }
      }
      .overlay {
        if player.playlist.isEmpty {
          VStack(spacing: 8) {
            Image(systemName: "music.note").font(.largeTitle).foregroundColor(.secondary)
            Text("还没有音乐").font(.headline)
            Text("点右上角 + 从文件导入你的音乐").font(.subheadline).foregroundColor(.secondary)
          }
        }
      }
    }
  }

  private func fmt(_ t: Double) -> String {
    guard t.isFinite else { return "--:--" }
    return String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60)
  }
}

struct DocumentPicker: UIViewControllerRepresentable {
  var onPick: (URL) -> Void

  func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
    let vc = UIDocumentPickerViewController(forOpeningContentTypes: [.audio], asCopy: true)
    vc.delegate = context.coordinator
    vc.allowsMultipleSelection = false
    return vc
  }

  func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

  final class Coordinator: NSObject, UIDocumentPickerDelegate {
    var onPick: (URL) -> Void
    init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
      if let url = urls.first { onPick(url) }
    }
  }
}
