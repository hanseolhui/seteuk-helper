import SwiftUI

// ChatGPT·Gemini(선생님 구독) 로 반 전체 초안을 한 번에 — 요청문 복사 → 답 붙여넣기 → 학생별 초안 저장.
// 이름은 '학생1, 학생2…' 로 가려서 보내고, 돌아온 답에서 다시 학생을 찾는다. 서버 비용 없음.

/// 초안 검사: NEIS 바이트, 기재 금지어, 문장 끝(~함·~임)
enum DraftCheck {
    static let forbidden = [
        "토익", "TOEIC", "토플", "TOEFL", "텝스", "TEPS", "HSK", "JLPT", "DELF", "IELTS",
        "교외", "외부 대회", "올림피아드", "경시대회", "공모전", "수상", "입상", "금상", "은상", "동상", "대상을",
        "논문", "학회", "특허", "출판", "저서", "발명", "해외", "어학연수", "유학",
        "부모", "아버지", "어머니", "아빠", "엄마", "가정형편", "직업이", "학원", "과외", "인강",
    ]

    struct Issue: Hashable { var text: String; var serious: Bool }

    static func issues(_ text: String, limit: Int) -> [Issue] {
        var out: [Issue] = []
        let b = neisBytes(text)
        if b > limit { out.append(Issue(text: "\(b - limit)바이트 넘쳐요 (\(b)/\(limit))", serious: true)) }
        let low = text.lowercased()
        let found = forbidden.filter { low.contains($0.lowercased()) }
        if !found.isEmpty { out.append(Issue(text: "기재 금지어: " + found.prefix(4).joined(separator: ", "), serious: true)) }
        let endings = text.components(separatedBy: CharacterSet(charactersIn: ".!?\n")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let plain = endings.filter { $0.hasSuffix("다") || $0.hasSuffix("요") }
        if !plain.isEmpty { out.append(Issue(text: "‘~함·~임’으로 끝나지 않은 문장 \(plain.count)개", serious: false)) }
        return out
    }
}

/// 반 전체 요청문 만들기 / 답 읽기
enum ClassPrompt {
    struct Item { var label: String; var student: SStudent; var notes: [SNote] }

    @MainActor
    static func items(_ cls: SClass, data: DataStore) -> [Item] {
        data.students(in: cls).filter { !data.notes(of: $0).isEmpty }.enumerated().map { i, s in
            Item(label: "학생\(i + 1)", student: s, notes: data.notes(of: s).reversed())
        }
    }

    /// 기록 안의 이름을 모두 '학생N' 으로 가림 (다른 학생 이름도)
    static func mask(_ text: String, items: [Item]) -> String {
        var t = text
        for it in items.sorted(by: { $0.student.displayName.count > $1.student.displayName.count }) {
            let n = it.student.displayName
            t = t.replacingOccurrences(of: n, with: it.label)
            if n.count >= 3 { t = t.replacingOccurrences(of: String(n.dropFirst()), with: it.label) }
        }
        return t
    }

    static func build(items: [Item], area: String) -> String {
        let limit = Areas.limit(area)
        let body = items.map { it in
            "[\(it.label)]\n" + it.notes.map { "- \($0.date ?? "") \(mask($0.content ?? "", items: items))" }.joined(separator: "\n")
        }.joined(separator: "\n\n")
        return """
        너는 학교 선생님의 학교생활기록부 작성을 돕는 보조자야. 아래 학생마다 '관찰 기록'에 있는 사실만 근거로 \(Areas.name(area)) 초안을 써 줘.

        [규칙]
        - 학생마다 따로, 반드시 이 형식으로만 답해:
          [학생1]
          (초안 한 문단)

          [학생2]
          (초안 한 문단)
        - 학생 이름은 쓰지 말고, 기록에 없는 활동·성과·수상은 절대 지어내지 마.
        - 문장 끝은 '~함', '~임' 같은 명사형으로.
        - 학생마다 NEIS 기준 \(limit)바이트(한글 1자 3바이트) 이내.
        - 사교육·부모 직업·교외 수상·어학 시험 같은 기재 금지 내용은 넣지 마.
        - 기록이 적은 학생은 짧게 써도 돼. 억지로 늘리지 마.

        [관찰 기록]
        \(body)
        """
    }

    /// 답에서 '[학생N]' 또는 '학생N:' 머리말을 찾아 학생별로 나눔
    static func parse(_ answer: String, items: [Item]) -> [(Item, String)] {
        let rx = try! NSRegularExpression(pattern: #"(?m)^\s*[\[\(【]?\s*\**\s*학생\s*(\d{1,3})\s*\**\s*[\]\)】]?\s*[:：.\-]?\s*"#)
        let ns = answer as NSString
        let ms = rx.matches(in: answer, range: NSRange(location: 0, length: ns.length))
        var out: [(Item, String)] = []
        for (i, m) in ms.enumerated() {
            guard let n = Int(ns.substring(with: m.range(at: 1))), n >= 1, n <= items.count else { continue }
            let start = m.range.location + m.range.length
            let end = i + 1 < ms.count ? ms[i + 1].range.location : ns.length
            var text = ns.substring(with: NSRange(location: start, length: max(0, end - start)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // 혹시 남은 '학생N' 표기는 지움 (생기부에는 이름을 쓰지 않음)
            text = text.replacingOccurrences(of: #"학생\s*\d{1,3}(은|는|이|가)?\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "**", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { out.append((items[n - 1], text)) }
        }
        return out
    }
}

extension DataStore {
    @discardableResult
    func addDraft(_ s: SStudent, area: String, content: String) -> SDraft {
        let d = SDraft(uid: "d-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased(),
                       updated_at: Date().timeIntervalSince1970, student_uid: s.uid, area: area, content: content, status: "초안")
        insertDraft(d)
        return d
    }
}

/// 반 전체 초안 시트
struct ClassDraftSheet: View {
    @EnvironmentObject var data: DataStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    var cls: SClass
    @State private var area = "subject"
    @State private var copied = false
    @State private var answer = ""
    @State private var parsed: [(ClassPrompt.Item, String)] = []
    @State private var saved = false

    var items: [ClassPrompt.Item] { ClassPrompt.items(cls, data: data) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    step1
                    step2
                    if !parsed.isEmpty { preview }
                }
                .padding(18).frame(maxWidth: 640).frame(maxWidth: .infinity)
            }
            .softBackground()
            .navigationTitle("반 전체 초안").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
            .onAppear { area = Areas.forKind(cls.kind).first ?? "subject" }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: parsed.count)
        }
    }

    var step1: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("① 요청문 복사", systemImage: "doc.on.doc.fill").font(Theme.font(17, .bold))
            if Areas.forKind(cls.kind).count > 1 {
                Picker("영역", selection: $area) {
                    ForEach(Areas.forKind(cls.kind), id: \.self) { Text(Areas.name($0)).tag($0) }
                }.pickerStyle(.segmented)
            }
            Text("기록이 있는 학생 \(items.count)명의 기록을 한 번에 담아요. 이름은 ‘학생1, 학생2…’로 가려서 복사돼요.")
                .font(Theme.font(13)).foregroundStyle(Theme.soft).fixedSize(horizontal: false, vertical: true)
            Button {
                UIPasteboard.general.string = ClassPrompt.build(items: items, area: area)
                withAnimation(.spring(response: 0.3)) { copied = true }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } label: {
                Label(copied ? "복사됐어요!" : "요청문 복사하기", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(Theme.font(16, .bold)).frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(Theme.brand, in: Capsule()).foregroundStyle(.white)
            }.buttonStyle(Squishy()).disabled(items.isEmpty)
            HStack(spacing: 10) {
                Button { openURL(URL(string: "https://chatgpt.com/")!) } label: { appChip("ChatGPT 열기") }
                Button { openURL(URL(string: "https://gemini.google.com/app")!) } label: { appChip("Gemini 열기") }
            }.buttonStyle(Squishy())
            Text("새 대화에 붙여넣고 보내세요. 학생이 많으면 ‘계속’이라고 하면 이어서 써 줘요.")
                .font(Theme.font(12)).foregroundStyle(Theme.soft)
        }
        .frame(maxWidth: .infinity, alignment: .leading).card()
    }

    func appChip(_ t: String) -> some View {
        Text(t).font(Theme.font(13, .bold)).padding(.horizontal, 14).padding(.vertical, 8)
            .background(Theme.blue.opacity(0.12), in: Capsule()).foregroundStyle(Theme.blue)
    }

    var step2: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("② 답 붙여넣기", systemImage: "arrow.down.doc.fill").font(Theme.font(17, .bold))
            Text("AI가 쓴 답을 통째로 복사해 와서 아래 버튼을 누르면, 학생마다 초안으로 나눠 담아요.")
                .font(Theme.font(13)).foregroundStyle(Theme.soft).fixedSize(horizontal: false, vertical: true)
            Button {
                answer = UIPasteboard.general.string ?? ""
                parsed = ClassPrompt.parse(answer, items: items)
                saved = false
            } label: {
                Label("복사한 답 붙여넣기", systemImage: "doc.on.clipboard").font(Theme.font(16, .bold))
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(Theme.mint, in: Capsule()).foregroundStyle(.white)
            }.buttonStyle(Squishy())
            if !answer.isEmpty && parsed.isEmpty {
                Text("‘[학생1]’ 같은 머리말을 찾지 못했어요. AI 답을 처음부터 끝까지 복사했는지 확인해 주세요.")
                    .font(Theme.font(12, .semibold)).foregroundStyle(Theme.coral)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).card()
    }

    var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(parsed.count)명 초안 확인").font(Theme.font(16, .bold))
                Spacer()
                Button {
                    for (it, t) in parsed { data.addDraft(it.student, area: area, content: t) }
                    withAnimation { saved = true }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } label: {
                    Label(saved ? "저장했어요" : "모두 저장", systemImage: saved ? "checkmark" : "tray.and.arrow.down.fill")
                        .font(Theme.font(14, .bold)).padding(.horizontal, 14).padding(.vertical, 8)
                        .background(saved ? Theme.mint : Theme.blue, in: Capsule()).foregroundStyle(.white)
                }.buttonStyle(Squishy()).disabled(saved)
            }
            ForEach(parsed.indices, id: \.self) { i in
                let (it, t) = parsed[i]
                VStack(alignment: .leading, spacing: 8) {
                    HStack { StudentChip(student: it.student); Spacer(); ByteBadge(text: t, limit: Areas.limit(area)) }
                    Text(t).font(Theme.font(14)).fixedSize(horizontal: false, vertical: true)
                    CheckList(text: t, limit: Areas.limit(area))
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
            Text("AI 초안은 다듬기 보조예요. 내용과 책임은 선생님께 있으니 꼭 읽고 고쳐 주세요.")
                .font(Theme.font(12)).foregroundStyle(Theme.soft)
        }
        .frame(maxWidth: .infinity, alignment: .leading).card()
    }
}

struct ByteBadge: View {
    var text: String
    var limit: Int
    var body: some View {
        let b = neisBytes(text)
        Text("\(b)/\(limit)").font(Theme.font(12, .bold)).monospacedDigit()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background((b > limit ? Theme.coral : Theme.mint).opacity(0.15), in: Capsule())
            .foregroundStyle(b > limit ? Theme.coral : Theme.mint)
    }
}

struct CheckList: View {
    var text: String
    var limit: Int
    var body: some View {
        let issues = DraftCheck.issues(text, limit: limit)
        if issues.isEmpty {
            Label("검사 통과", systemImage: "checkmark.seal.fill").font(Theme.font(12, .semibold)).foregroundStyle(Theme.mint)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(issues, id: \.self) { i in
                    Label(i.text, systemImage: i.serious ? "exclamationmark.triangle.fill" : "info.circle")
                        .font(Theme.font(12, .semibold)).foregroundStyle(i.serious ? Theme.coral : Theme.butter)
                }
            }
        }
    }
}
