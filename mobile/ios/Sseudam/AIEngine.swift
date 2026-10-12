import Foundation

// AI 기능을 어디서 돌릴지 고르는 자리. (요금제 결정: 2026-10-12)
//  - 기기 안 AI (무료): 애플 Foundation Models. 학생별 나누기 보정. 서버 비용 0.
//  - 내 API 키 (BYOK): 선생님 본인 Gemini/OpenAI 키. 학생 요약·초안. ── 구조만, 아직 꺼져 있음
//  - 쓰담 플러스 (구독): 쓰담 서버. 서버 받아쓰기·요약·초안·암호화 동기화. ── 구조만, 아직 꺼져 있음
// 화면은 AIRouter 만 부르고, 어느 엔진이 처리할지는 여기서 정한다.
// 이름은 엔진에 넘기기 전에 'OO' 등으로 가리는 것이 원칙(기기 안 AI는 밖으로 나가지 않으므로 예외).

enum AITask { case assignSentences, summarizeStudent, draft }

enum AIEngineKind: String, Codable { case local, ownKey, plus }

enum AIError: LocalizedError {
    case notAvailable(String)
    var errorDescription: String? { if case .notAvailable(let m) = self { return m }; return nil }
}

protocol AIEngine {
    var kind: AIEngineKind { get }
    var isAvailable: Bool { get }
    func supports(_ task: AITask) -> Bool
    /// 문장마다 학생 번호(1부터) 또는 0
    func assign(sentences: [String], names: [String], known: [Int: Int]) async throws -> [Int]
    /// 학생 한 명의 기록 요약 (기록은 이름을 가린 상태로 받음)
    func summarize(notes: [String], area: String) async throws -> String
    /// 생기부 초안 (NEIS 바이트 제한 안에서)
    func draft(notes: [String], area: String, byteLimit: Int) async throws -> String
}

/// 기기 안 AI — 무료, 오프라인
struct LocalEngine: AIEngine {
    let kind = AIEngineKind.local
    var isAvailable: Bool { LocalAI.isReady }
    func supports(_ task: AITask) -> Bool { task == .assignSentences }
    func assign(sentences: [String], names: [String], known: [Int: Int]) async throws -> [Int] {
        guard let r = await LocalAI.owners(sentences: sentences, names: names, known: known) else {
            throw AIError.notAvailable(LocalAI.stateText)
        }
        return r
    }
    func summarize(notes: [String], area: String) async throws -> String { throw AIError.notAvailable("기기 안 AI 요약은 아직 없어요") }
    func draft(notes: [String], area: String, byteLimit: Int) async throws -> String { throw AIError.notAvailable("초안은 내 API 키나 쓰담 플러스에서") }
}

/// 내 API 키 — 구조만 (요금 1회 결제 예정, 아직 켜지 않음)
struct OwnKeyEngine: AIEngine {
    let kind = AIEngineKind.ownKey
    static let enabled = false            // 출시 결정 전까지 꺼 둠
    var provider: String { UserDefaults.standard.string(forKey: "ownKeyProvider") ?? "gemini" }
    var hasKey: Bool { !(Keychain.get("ownAIKey") ?? "").isEmpty }
    var isAvailable: Bool { OwnKeyEngine.enabled && hasKey }
    func supports(_ task: AITask) -> Bool { task != .assignSentences }
    func assign(sentences: [String], names: [String], known: [Int: Int]) async throws -> [Int] { throw AIError.notAvailable("준비 중") }
    // TODO(BYOK): Gemini generateContent / OpenAI responses 호출. 무료 등급 키는 입력이 학습에 쓰일 수 있다는 경고를 띄울 것.
    func summarize(notes: [String], area: String) async throws -> String { throw AIError.notAvailable("준비 중") }
    func draft(notes: [String], area: String, byteLimit: Int) async throws -> String { throw AIError.notAvailable("준비 중") }
}

/// 쓰담 플러스 — 구조만 (서버·결제·법률 검토 뒤)
struct PlusEngine: AIEngine {
    let kind = AIEngineKind.plus
    static let enabled = false
    var isAvailable: Bool { PlusEngine.enabled && UserDefaults.standard.bool(forKey: "plusActive") }
    func supports(_ task: AITask) -> Bool { true }
    // TODO(플러스): 서버 API (사용자별·하루 상한, 이름 가명 처리, 결과 미보관) — 수익모델_시뮬레이션.md 의 상한 참고
    func assign(sentences: [String], names: [String], known: [Int: Int]) async throws -> [Int] { throw AIError.notAvailable("준비 중") }
    func summarize(notes: [String], area: String) async throws -> String { throw AIError.notAvailable("준비 중") }
    func draft(notes: [String], area: String, byteLimit: Int) async throws -> String { throw AIError.notAvailable("준비 중") }
}

/// 일마다 쓸 엔진 고르기: 플러스 → 내 키 → 기기 안 AI 순. 없으면 nil (그 기능은 숨김)
enum AIRouter {
    static let engines: [AIEngine] = [PlusEngine(), OwnKeyEngine(), LocalEngine()]
    static func engine(for task: AITask) -> AIEngine? {
        engines.first { $0.isAvailable && $0.supports(task) }
    }
    static func available(_ task: AITask) -> Bool { engine(for: task) != nil }
}
