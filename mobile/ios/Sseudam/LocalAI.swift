import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 기기 안 AI (애플 Foundation Models, iOS 26+ · 애플 인텔리전스 지원 기기).
/// 서버로 아무것도 보내지 않고, 이름이 안 나온 문장("그 친구는…")이 누구 이야기인지만 고른다.
/// 고를 수 있는 학생은 그 녹음에 이름이 나온 학생뿐이라, 없는 학생을 지어낼 수 없다.
enum LocalAI {
    enum State { case ready, notEligible, notEnabled, notReady, unsupportedOS }

    static var state: State {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .ready
            case .unavailable(.deviceNotEligible): return .notEligible
            case .unavailable(.appleIntelligenceNotEnabled): return .notEnabled
            case .unavailable(.modelNotReady): return .notReady
            case .unavailable: return .notEligible
            }
        }
        #endif
        return .unsupportedOS
    }

    static var isReady: Bool { state == .ready }

    static var stateText: String {
        switch state {
        case .ready: return "이 아이폰에서 바로 쓸 수 있어요."
        case .notEnabled: return "설정 → Apple Intelligence 및 Siri에서 Apple Intelligence를 켜면 쓸 수 있어요."
        case .notReady: return "기기 안 AI 모델을 내려받는 중이에요. 잠시 뒤 다시 확인해 주세요."
        case .notEligible: return "이 아이폰은 기기 안 AI를 지원하지 않아요 (아이폰 15 Pro 이후). 이름 기준으로 나눠요."
        case .unsupportedOS: return "iOS 26 이상에서 쓸 수 있어요. 지금은 이름 기준으로 나눠요."
        }
    }

    /// 문장마다 학생 번호(1부터) 또는 0(반 전체·모름)을 돌려준다. 실패하면 nil.
    /// - known: 이름이 나와 이미 정해진 문장 → 그 학생 번호 (AI에게 문맥 힌트로만 줌)
    static func owners(sentences: [String], names: [String], known: [Int: Int]) async -> [Int]? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), isReady {
            let roster = names.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            let lines = sentences.enumerated().map { i, s in
                if let k = known[i] { return "[\(i + 1)] (\(names[k - 1]) 언급) \(s)" }
                return "[\(i + 1)] \(s)"
            }.joined(separator: "\n")
            let session = LanguageModelSession(instructions: """
                너는 선생님이 수업 중 남긴 관찰 메모를 학생별로 나누는 도우미야.
                각 문장이 아래 학생 중 누구에 대한 내용인지 학생 번호로 답해.
                - "그 친구", "이 학생", "걔", "또한", "다만"처럼 이름 없이 이어지는 문장은 바로 앞 문장의 학생과 같은 학생이야.
                - "오늘 수업", "반 전체", "모두", "분위기"처럼 여러 학생이나 수업 이야기면 0.
                - 목록에 없는 학생은 절대 만들지 마.
                예시) 학생: 1. 김민수 2. 이서연
                [1] 오늘 실험을 했음. → 0
                [2] (김민수 언급) 김민수는 가설을 세웠음. → 1
                [3] 그 친구는 결과도 정리함. → 1
                [4] (이서연 언급) 이서연은 질문을 많이 함. → 2
                [5] 다만 기록이 부족했음. → 2
                [6] 모두 열심히 참여함. → 0
                """)
            do {
                let r = try await session.respond(to: "학생 목록:\n\(roster)\n\n문장:\n\(lines)", generating: SentenceOwners.self)
                var out = Array(repeating: 0, count: sentences.count)
                for a in r.content.items where (1...sentences.count).contains(a.sentence) && (0...names.count).contains(a.student) {
                    out[a.sentence - 1] = a.student
                }
                return out
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct SentenceOwners {
    @Guide(description: "문장마다 하나씩: 문장 번호와 그 문장의 학생 번호")
    var items: [SentenceOwner]
}

@available(iOS 26.0, *)
@Generable
struct SentenceOwner {
    @Guide(description: "문장 번호 (1부터)")
    var sentence: Int
    @Guide(description: "학생 번호 (1부터). 특정 학생이 아니거나 모르면 0")
    var student: Int
}
#endif
