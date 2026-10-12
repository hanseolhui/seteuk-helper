import AVFoundation
import Foundation

/// AAC(m4a) 모노 16kHz 32kbps — 1시간 약 14MB. 화면이 꺼져도 계속 녹음(백그라운드 오디오).
@MainActor
final class Recorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var elapsed: TimeInterval = 0
    @Published var level: Float = 0           // 0...1
    @Published var permissionDenied = false
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private(set) var startedAt = Date()
    private var tempURL: URL?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)),
                                               name: AVAudioSession.interruptionNotification, object: nil)
    }

    func start() async {
        let granted = await withCheckedContinuation { c in
            AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) }
        }
        guard granted else { permissionDenied = true; return }
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth])
            try s.setActive(true)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32000, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            r.delegate = self
            guard r.record() else { return }
            recorder = r; tempURL = url; startedAt = Date()
            isRecording = true; isPaused = false; elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch {
            print("녹음 시작 실패", error)
        }
    }

    private func tick() {
        guard let r = recorder else { return }
        elapsed = r.currentTime
        r.updateMeters()
        let db = r.averagePower(forChannel: 0)       // -160...0
        level = max(0, min(1, (db + 50) / 50))
    }

    func togglePause() {
        guard let r = recorder else { return }
        if isPaused { r.record(); isPaused = false } else { r.pause(); isPaused = true; level = 0 }
    }

    /// 녹음 끝 → (임시 파일, 길이, 시작 시각)
    func stop() -> (URL, TimeInterval, Date)? {
        guard let r = recorder, let url = tempURL else { return nil }
        let d = r.currentTime
        r.stop()
        timer?.invalidate(); timer = nil
        recorder = nil; isRecording = false; isPaused = false; level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return (url, d, startedAt)
    }

    func discard() {
        if let (url, _, _) = stop() { try? FileManager.default.removeItem(at: url) }
    }

    @objc nonisolated private func interrupted(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        Task { @MainActor in
            // 전화가 오면 일시정지 → 끝나면 사용자가 다시 누르도록
            if type == .began, self.isRecording, !self.isPaused { self.recorder?.pause(); self.isPaused = true }
        }
    }
}
