import AVFoundation
import Foundation
import WatchConnectivity

/// 워치 녹음기: 16kHz 모노 AAC(m4a)로 녹음하고, 끝나면 아이폰으로 보낸다.
/// 아이폰이 멀리 있어도 WCSession이 전송을 줄 세워 두었다가 연결되면 보낸다.
@MainActor
final class WatchRecorder: NSObject, ObservableObject {
    enum Phase: Equatable { case idle, recording, sent, denied, failed }

    static let shared = WatchRecorder()

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var pendingCount = 0

    private var recorder: AVAudioRecorder?
    private var startedAt = Date()
    private var timer: Timer?
    private var resetTask: Task<Void, Never>?

    /// 보낼 파일을 모아 두는 폴더 (전송이 끝나면 지운다)
    static let pendingFolder: URL = {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Pending", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private override init() { super.init() }

    // MARK: 녹음

    func toggle() {
        if phase == .recording { stop() } else { start() }
    }

    func start() {
        resetTask?.cancel()
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor in
                if granted { self.beginRecording() } else { self.phase = .denied }
            }
        }
    }

    private func beginRecording() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
        } catch {
            phase = .failed
            return
        }

        let now = Date()
        let url = Self.pendingFolder.appendingPathComponent("watch-\(Int(now.timeIntervalSince1970 * 1000)).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            guard r.record() else { phase = .failed; return }
            recorder = r
        } catch {
            phase = .failed
            return
        }

        startedAt = now
        elapsed = 0
        phase = .recording
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .recording else { return }
                self.elapsed = Date().timeIntervalSince(self.startedAt)
            }
        }
    }

    func stop() {
        guard let r = recorder else { return }
        let duration = r.currentTime > 0 ? r.currentTime : Date().timeIntervalSince(startedAt)
        r.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        Phone.shared.send(r.url, recordedAt: startedAt, duration: duration)
        refreshPending()
        phase = .sent

        resetTask?.cancel()
        resetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if self?.phase == .sent { self?.phase = .idle }
            }
        }
    }

    func refreshPending() {
        pendingCount = Phone.shared.pendingCount
    }
}

// MARK: - 아이폰으로 보내기

/// WCSession 래퍼. 아직 활성화 전이면 파일을 기억해 두었다가 활성화되면 보낸다.
final class Phone: NSObject, WCSessionDelegate {
    static let shared = Phone()

    private var waiting: [(URL, [String: Any])] = []

    private override init() { super.init() }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    var pendingCount: Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: WatchRecorder.pendingFolder,
                                                                  includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "m4a" }.count
    }

    func send(_ url: URL, recordedAt: Date, duration: TimeInterval) {
        let meta: [String: Any] = ["recordedAt": recordedAt.timeIntervalSince1970, "duration": duration]
        saveMeta(meta, for: url)
        transfer(url, meta)
    }

    private func transfer(_ url: URL, _ meta: [String: Any]) {
        let s = WCSession.default
        guard s.activationState == .activated else {
            waiting.append((url, meta))
            return
        }
        s.transferFile(url, metadata: meta)
    }

    private func metaURL(for url: URL) -> URL { url.appendingPathExtension("json") }

    private func saveMeta(_ meta: [String: Any], for url: URL) {
        if let data = try? JSONSerialization.data(withJSONObject: meta) {
            try? data.write(to: metaURL(for: url))
        }
    }

    private func loadMeta(for url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: metaURL(for: url)),
              let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let date = (attrs?[.creationDate] as? Date) ?? Date()
            return ["recordedAt": date.timeIntervalSince1970, "duration": 0]
        }
        return meta
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else { return }
        DispatchQueue.main.async {
            let queued = self.waiting
            self.waiting.removeAll()
            let queuedNames = Set(queued.map { $0.0.lastPathComponent })
            for (url, meta) in queued { session.transferFile(url, metadata: meta) }
            // 대기열에 막 넣은 것과 겹치지 않게, 나머지 남은 파일만 다시 보낸다
            let inFlight = Set(session.outstandingFileTransfers.map { $0.file.fileURL.lastPathComponent })
            let files = (try? FileManager.default.contentsOfDirectory(at: WatchRecorder.pendingFolder,
                                                                      includingPropertiesForKeys: nil)) ?? []
            for url in files where url.pathExtension == "m4a"
                && !inFlight.contains(url.lastPathComponent)
                && !queuedNames.contains(url.lastPathComponent) {
                session.transferFile(url, metadata: self.loadMeta(for: url))
            }
            Task { @MainActor in WatchRecorder.shared.refreshPending() }
        }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let url = fileTransfer.file.fileURL
        if error == nil {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: metaURL(for: url))
        }
        // 실패한 파일은 폴더에 남겨 두고 다음 실행 때 다시 보낸다
        Task { @MainActor in WatchRecorder.shared.refreshPending() }
    }
}
