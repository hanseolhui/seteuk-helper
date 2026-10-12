import AVFoundation
import Foundation
import Speech

/// 아이폰 안에서 녹음을 글자로 바꾼다 (기기 안 받아쓰기만 사용 — 학생 목소리가 밖으로 나가지 않음).
/// 받아쓴 글은 m4a의 가사(©lyr) 메타데이터로 넣어 보내므로, 컴퓨터의 쓰담이 다시 받아쓸 필요가 없다.
enum Transcriber {
    /// 낱말마다 (녹음 시작부터 초, 글 안 위치(UTF-16)) — 녹음 중 누른 이름표를 글 위치로 바꿀 때 씀
    struct Seg { var t: Double; var offset: Int }
    enum Outcome { case text(String, [Seg]), unavailable(String), failed(String) }

    static var recognizer: SFSpeechRecognizer? { SFSpeechRecognizer(locale: Locale(identifier: "ko-KR")) }

    /// 이 아이폰이 한국어 기기 안 받아쓰기를 지원하는지
    static var supported: Bool { recognizer?.supportsOnDeviceRecognition == true }

    static func authorize() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { c in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }

    static func transcribe(_ file: URL, hints: [String] = []) async -> Outcome {
        guard await authorize() else { return .unavailable("받아쓰기 권한이 꺼져 있어요 (설정 → 쓰담)") }
        guard let r = recognizer, r.supportsOnDeviceRecognition else {
            return .unavailable("이 아이폰은 기기 안 받아쓰기를 지원하지 않아요 · 컴퓨터에서 글자로 바꿔요")
        }
        let req = SFSpeechURLRecognitionRequest(url: file)
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = false
        req.addsPunctuation = true
        req.taskHint = .dictation
        if !hints.isEmpty { req.contextualStrings = Array(hints.prefix(100)) }
        return await withCheckedContinuation { c in
            var done = false
            var task: SFSpeechRecognitionTask?
            task = r.recognitionTask(with: req) { result, error in
                if done { return }
                if let result, result.isFinal {
                    done = true
                    let tr = result.bestTranscription
                    c.resume(returning: .text(tr.formattedString, tr.segments.map { Seg(t: $0.timestamp, offset: $0.substringRange.location) }))
                } else if let error {
                    done = true
                    let ns = error as NSError
                    // 말소리가 없으면 'No speech detected' 오류가 난다 → 빈 글로 처리
                    if ns.domain == "kAFAssistantErrorDomain" && [1110, 1101].contains(ns.code) {
                        c.resume(returning: .text("", []))
                    } else {
                        c.resume(returning: .failed(error.localizedDescription))
                    }
                }
            }
            _ = task
        }
    }

    /// 받아쓴 글을 m4a 안에 넣는다 (소리는 그대로 복사). 실패하면 원본을 그대로 둔다.
    static func embed(_ text: String, into file: URL) async -> Bool {
        let asset = AVURLAsset(url: file)
        guard let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return false }
        let tmp = file.deletingLastPathComponent().appendingPathComponent(".tag-\(UUID().uuidString).m4a")
        let item = AVMutableMetadataItem()
        item.identifier = .iTunesMetadataLyrics
        item.value = text as NSString
        item.extendedLanguageTag = "ko"
        ex.metadata = [item]
        ex.outputURL = tmp
        ex.outputFileType = .m4a
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            ex.exportAsynchronously { c.resume() }
        }
        guard ex.status == .completed else { try? FileManager.default.removeItem(at: tmp); return false }
        do {
            _ = try FileManager.default.replaceItemAt(file, withItemAt: tmp)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }
}
