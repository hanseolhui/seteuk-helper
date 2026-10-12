import AppIntents
import SwiftUI

@main
struct SseudamApp: App {
    @StateObject private var store = Store.shared
    @StateObject private var nav = Nav.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            Group {
                if store.onboarded { RootView() } else { OnboardingView() }
            }
            .environmentObject(store)
            .environmentObject(nav)
            .tint(Theme.blue)
            .onOpenURL { url in
                if let p = Sync.parsePairing(url.absoluteString) {
                    store.pair(url: p.url, token: p.token, name: p.name)
                    nav.tab = .connect
                }
            }
        }
        .onChange(of: phase) { p in
            if p == .active { Task { await store.syncAll() } }
        }
    }
}

/// 화면 이동 + Siri/동작 버튼에서 녹음 바로 시작
@MainActor
final class Nav: ObservableObject {
    static let shared = Nav()
    enum Tab: Hashable { case home, records, connect }
    @Published var tab: Tab = .home
    @Published var startRecordingRequest = 0
}

struct RootView: View {
    @EnvironmentObject var nav: Nav
    @Environment(\.horizontalSizeClass) private var size

    var body: some View {
        if size == .regular { iPadLayout } else { phoneLayout }
    }

    var phoneLayout: some View {
        TabView(selection: $nav.tab) {
            HomeView().tag(Nav.Tab.home)
                .tabItem { Label("담기", systemImage: "mic.fill") }
            RecordsView().tag(Nav.Tab.records)
                .tabItem { Label("기록함", systemImage: "tray.full.fill") }
            ConnectView().tag(Nav.Tab.connect)
                .tabItem { Label("연결", systemImage: "link") }
        }
    }

    /// 아이패드: 왼쪽 메뉴 + 오른쪽 화면
    var iPadLayout: some View {
        NavigationSplitView {
            List {
                sideItem("담기", "mic.fill", .home)
                sideItem("기록함", "tray.full.fill", .records)
                sideItem("연결", "link", .connect)
            }
            .navigationTitle("쓰담")
            .scrollContentBackground(.hidden)
            .softBackground()
        } detail: {
            switch nav.tab {
            case .home: HomeView()
            case .records: RecordsView()
            case .connect: ConnectView()
            }
        }
    }

    func sideItem(_ title: String, _ icon: String, _ tab: Nav.Tab) -> some View {
        Button { nav.tab = tab } label: {
            Label(title, systemImage: icon).font(Theme.font(17, nav.tab == tab ? .bold : .regular))
                .foregroundStyle(nav.tab == tab ? Theme.blue : Theme.ink)
        }
        .listRowBackground(nav.tab == tab ? Theme.blue.opacity(0.12) : Color.clear)
    }
}

// MARK: - Siri · 동작 버튼 · 단축어

struct StartRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "쓰담 녹음 시작"
    static var description = IntentDescription("쓰담을 열고 바로 녹음을 시작합니다.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        Nav.shared.tab = .home
        Nav.shared.startRecordingRequest += 1
        return .result()
    }
}

struct SseudamShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartRecordingIntent(),
                    phrases: ["\(.applicationName) 녹음 시작", "\(.applicationName)으로 녹음", "\(.applicationName) 녹음"],
                    shortTitle: "녹음 시작", systemImageName: "mic.fill")
    }
}
