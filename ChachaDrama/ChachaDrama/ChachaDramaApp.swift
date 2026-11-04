import SwiftUI

@main
struct ChachaDramaApp: App {
    @StateObject private var feedVM = FeedViewModel()
    @State private var tabSelection = 0

    init() {
        PyRuntime.start()
        ErrorLog.append("App 启动")
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tabSelection) {
                FeedView(vm: feedVM, tabSelection: $tabSelection)
                    .tabItem { Label("首页", systemImage: "house") }
                    .tag(0)
                TheaterView(vm: feedVM, tabSelection: $tabSelection)
                    .tabItem { Label("剧场", systemImage: "film") }
                    .tag(1)
                SettingsView()
                    .tabItem { Label("我的", systemImage: "person") }
                    .tag(2)
            }
            .tint(.orange)
            .preferredColorScheme(.dark)
        }
    }
}
