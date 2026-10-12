import AVFoundation
import SwiftUI

struct ListView: View {
    @EnvironmentObject var store: Store
    @StateObject private var player = Player()

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    ContentUnavailableCompat(title: "아직 녹음이 없습니다", systemImage: "waveform",
                                             message: "녹음 탭에서 녹음하면 여기에 쌓이고, 컴퓨터로 자동 전송됩니다.")
                } else {
                    List {
                        ForEach(store.items) { r in row(r) }
                            .onDelete { idx in idx.map { store.items[$0] }.forEach(store.delete) }
                    }
                    .refreshable { await store.syncAll() }
                }
            }
            .navigationTitle("녹음 목록")
            .toolbar {
                if store.syncing { ProgressView() }
                else { Button { Task { await store.syncAll() } } label: { Image(systemName: "arrow.clockwise") } }
            }
        }
    }

    func row(_ r: Recording) -> some View {
        HStack(spacing: 12) {
            Button { player.toggle(store.url(r)) } label: {
                Image(systemName: player.playing == store.url(r) ? "stop.circle.fill" : "play.circle.fill").font(.title)
            }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(r.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.body.weight(.medium))
                HStack(spacing: 6) {
                    Text(r.kind).font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(r.kind == "상담" ? Color.purple.opacity(0.15) : Color.blue.opacity(0.15), in: Capsule())
                    Text(timeString(r.duration)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    if !r.memo.isEmpty { Text(r.memo).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                if !r.lastError.isEmpty && (r.icloud == .failed || r.google == .failed) {
                    Text(r.lastError).font(.caption2).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                badge("iCloud", r.icloud)
                badge("구글", r.google)
            }
        }
    }

    @ViewBuilder func badge(_ name: String, _ s: SyncState) -> some View {
        switch s {
        case .off: EmptyView()
        case .pending: Label(name, systemImage: "clock").font(.caption2).foregroundStyle(.secondary)
        case .done: Label(name, systemImage: "checkmark.icloud").font(.caption2).foregroundStyle(.green)
        case .failed: Label(name, systemImage: "exclamationmark.icloud").font(.caption2).foregroundStyle(.red)
        }
    }
}

@MainActor
final class Player: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playing: URL?
    private var p: AVAudioPlayer?
    func toggle(_ url: URL) {
        if playing == url { p?.stop(); playing = nil; return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        p = try? AVAudioPlayer(contentsOf: url)
        p?.delegate = self
        p?.play()
        playing = url
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playing = nil }
    }
}

/// iOS 16에서도 쓰는 빈 화면 안내
struct ContentUnavailableCompat: View {
    var title: String; var systemImage: String; var message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage).font(.system(size: 44)).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(32)
    }
}
