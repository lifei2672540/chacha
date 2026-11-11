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
                    .toolbar(.hidden, for: .tabBar)
                    .preferredColorScheme(.dark)
                    .tabItem { Label("首页", systemImage: "house") }
                    .tag(0)
                SearchView()
                    .toolbar(.hidden, for: .tabBar)
                    .preferredColorScheme(.dark)
                    .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                    .tag(1)
                SitesView()
                    .toolbar(.hidden, for: .tabBar)
                    .preferredColorScheme(.dark)
                    .tabItem { Label("采集站", systemImage: "antenna.radiowaves.left.and.right") }
                    .tag(2)
                EmbyView()
                    .toolbar(.hidden, for: .tabBar)
                    .preferredColorScheme(.dark)
                    .tabItem { Label("Emby", systemImage: "play.rectangle") }
                    .tag(3)
                SettingsView()
                    .toolbar(.hidden, for: .tabBar)
                    .preferredColorScheme(.light)
                    .tabItem { Label("设置", systemImage: "gear") }
                    .tag(4)
                HikerHomeView()
                    .toolbar(.hidden, for: .tabBar)
                    .preferredColorScheme(.dark)
                    .tabItem { Label("海阔", systemImage: "globe") }
                    .tag(5)
            }
            .environmentObject(store)
            .environmentObject(tabNav)
            // 系统底栏藏掉，改用悬浮玻璃底栏（蚂蚁 2.0.6 同款）；TabView 本身留着，
            // 各 tab 的导航状态照常保留，切 tab 不会丢正在看的详情页。
            // 注意：藏底栏与深浅色必须写在每个 tab 上 —— 写在 TabView 上不生效，
            // 1.3.0 就是这么漏的：底栏旧标签露在玻璃条下面，设置页的状态栏还是白字。
            // 玻璃底栏的留空也必须写在每个 tab 的 NavigationStack 上：写在 TabView
            // 上的 safeAreaInset 传不进各页的滚动视图，底部内容会被玻璃条盖住、
            // 滑到底一松手就弹回去（1.4.3 的教训，设置页表单也一样）。
            .overlay(alignment: .bottom) {
                GlassTabBar(selected: $tabNav.selected)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    // 玻璃条固定深色：不管切到哪个 tab（设置页是浅色），白字图标都看得见。
                    .preferredColorScheme(.dark)
            }
            // 视频 App 惯用深色 + 红色强调，不再是默认白底 demo 样
            .tint(.red)
        }
    }
}

/// 悬浮玻璃底栏：毛玻璃底 + 6 个入口，当前项红色高亮。
private struct GlassTabBar: View {
    @Binding var selected: Int
    private let items = [
        ("首页", "house"),
        ("搜索", "magnifyingglass"),
        ("采集站", "antenna.radiowaves.left.and.right"),
        ("Emby", "play.rectangle"),
        ("设置", "gear"),
        ("海阔", "globe"),
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
