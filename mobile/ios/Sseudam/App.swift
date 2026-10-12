import SwiftUI

@main
struct SseudamApp: App {
    @StateObject private var store = Store.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .onOpenURL { url in
                    if let p = Sync.parsePairing(url.absoluteString) { store.pair(url: p.url, token: p.token, name: p.name) }
                }
        }
        .onChange(of: phase) { p in
            if p == .active { Task { await store.syncAll() } }
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            RecordView().tabItem { Label("녹음", systemImage: "mic.fill") }
            ListView().tabItem { Label("녹음 목록", systemImage: "list.bullet") }
            SettingsView().tabItem { Label("연결", systemImage: "arrow.triangle.2.circlepath") }
        }
    }
}
