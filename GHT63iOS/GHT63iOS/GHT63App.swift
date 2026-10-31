import SwiftUI

@main
struct GHT63App: App {
    @StateObject private var store = Store.shared

    init() {
        // 内嵌 Python 解释器（阶段 1：只验证能跑，版本号见设置页）
        PyRuntime.start()
        // 报错日志：未捕获异常 + 每次启动都记一笔（崩溃后重启能对上）
        ErrorLog.installExceptionHandler()
        ErrorLog.append("App 启动")
    }

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
