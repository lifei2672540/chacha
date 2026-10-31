import SwiftUI

@main
struct GHT63App: App {
    @StateObject private var store = Store.shared

    var body: some Scene {
        WindowGroup {
            TabView {
                HomeView()
                    .tabItem { Label("首页", systemImage: "house") }
                SearchView()
                    .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                SitesView()
                    .tabItem { Label("采集站", systemImage: "antenna.radiowaves.left.and.right") }
                EmbyView()
                    .tabItem { Label("Emby", systemImage: "play.rectangle") }
                SettingsView()
                    .tabItem { Label("设置", systemImage: "gear") }
            }
            .environmentObject(store)
            // 视频 App 惯用深色 + 红色强调，不再是默认白底 demo 样
            .preferredColorScheme(.dark)
            .tint(.red)
        }
    }
}
