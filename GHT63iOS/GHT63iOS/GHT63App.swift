import SwiftUI

/// 底部导航的状态（首页顶栏的搜索按钮、玻璃底栏共用）：切哪个 tab 就改它。
final class TabNav: ObservableObject {
    @Published var selected = 0
}

@main
struct GHT63App: App {
    @StateObject private var store = Store.shared
    @StateObject private var tabNav = TabNav()

    init() {
        // 内嵌 Python 解释器（阶段 1：只验证能跑，版本号见设置页）
        PyRuntime.start()
        // 报错日志：未捕获异常 + 每次启动都记一笔（崩溃后重启能对上）
        ErrorLog.installExceptionHandler()
        ErrorLog.append("App 启动")
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tabNav.selected) {
                HomeView()
                    .tabItem { Label("首页", systemImage: "house") }
                    .tag(0)
                SearchView()
                    .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                    .tag(1)
                SitesView()
                    .tabItem { Label("采集站", systemImage: "antenna.radiowaves.left.and.right") }
                    .tag(2)
                EmbyView()
                    .tabItem { Label("Emby", systemImage: "play.rectangle") }
                    .tag(3)
                SettingsView()
                    .tabItem { Label("设置", systemImage: "gear") }
                    .tag(4)
            }
            .environmentObject(store)
            .environmentObject(tabNav)
            // 系统底栏藏掉，改用悬浮玻璃底栏（蚂蚁 2.0.6 同款）；TabView 本身留着，
            // 各 tab 的导航状态照常保留，切 tab 不会丢正在看的详情页。
            .toolbar(.hidden, for: .tabBar)
            // 给玻璃底栏留空，别盖住内容。
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 76) }
            .overlay(alignment: .bottom) {
                GlassTabBar(selected: $tabNav.selected)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
            // 视频 App 惯用深色 + 红色强调，不再是默认白底 demo 样
            .preferredColorScheme(.dark)
            .tint(.red)
        }
    }
}

/// 悬浮玻璃底栏：毛玻璃底 + 5 个入口，当前项红色高亮。
private struct GlassTabBar: View {
    @Binding var selected: Int
    private let items = [
        ("首页", "house"),
        ("搜索", "magnifyingglass"),
        ("采集站", "antenna.radiowaves.left.and.right"),
        ("Emby", "play.rectangle"),
        ("设置", "gear"),
    ]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                Button {
                    selected = i
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: items[i].1)
                            .font(.system(size: 20))
                        Text(items[i].0)
                            .font(.caption2)
                    }
                    .foregroundColor(selected == i ? .red : .white.opacity(0.85))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(selected == i ? Color.red.opacity(0.18) : Color.clear)
                    .cornerRadius(16)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .cornerRadius(28)
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(Color.white.opacity(0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }
}
