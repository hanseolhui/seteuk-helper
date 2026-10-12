import AVFoundation
import Foundation
import WatchConnectivity

/// 애플워치에서 녹음한 파일을 받아 기록함에 저장한다.
/// 활성화: 앱 시작 시 `WatchBridge.shared.activate()` 한 번.
final class WatchBridge: NSObject, WCSessionDelegate {
    static let shared = WatchBridge()

    private override init() { super.init() }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.delegate == nil || session.delegate === self else { return }
        session.delegate = self
        if session.activationState != .activated { session.activate() }
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}

    /// 다른 워치로 바꾼 경우 새 워치와 다시 연결
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    /// 받은 파일은 이 콜백이 끝나면 지워지므로, 여기서 바로(동기) 복사해 둔다.
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString).m4a")
        do {
            try fm.copyItem(at: file.fileURL, to: tmp)
        } catch {
            return
        }

        let meta = file.metadata ?? [:]
        let recordedAt = (meta["recordedAt"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970
        var duration = (meta["duration"] as? NSNumber)?.doubleValue ?? 0
        if duration <= 0, let player = try? AVAudioPlayer(contentsOf: tmp) {
            duration = player.duration
        }
        let date = Date(timeIntervalSince1970: recordedAt)
        let seconds = duration

        Task { @MainActor in
            Store.shared.addAudio(tempFile: tmp, duration: seconds, at: date)
        }
    }
}
