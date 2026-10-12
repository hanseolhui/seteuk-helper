import SwiftUI

// 녹음(또는 메모) 하나를 학생별로 나눈 결과를 보고 바로잡는 화면 조각들.
// 조각마다 "누구 이야기인지" 칩이 붙고, 눌러서 다른 학생으로 옮기거나, 위 조각과 합치거나, 지울 수 있다.

private let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)

/// 학생 이름 칩 (반 색 + 이름, 동명이인이면 반도 함께)
struct StudentChip: View {
    @EnvironmentObject var data: DataStore
    var student: SStudent?
    var unsure = false

    var body: some View {
        let c = student.flatMap { data.classOf($0) }
        let color = unsure ? Theme.butter : kindColor(c?.kind)
        HStack(spacing: 6) {
            Text(student.map { String($0.displayName.suffix(2)) } ?? "?")
                .font(Theme.font(11, .heavy)).foregroundStyle(.white)
                .frame(width: 24, height: 24).background(color, in: Circle())
            Text(student?.displayName ?? "누구일까요?").font(Theme.font(14, .bold)).foregroundStyle(Theme.ink)
            if let s = student, unsure || !data.sameName(s).isEmpty, let c {
                Text(c.title).font(Theme.font(11, .semibold)).foregroundStyle(Theme.soft)
            }
            Image(systemName: unsure ? "questionmark.circle.fill" : "chevron.down")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(unsure ? Theme.butter : Theme.soft)
        }
        .padding(.leading, 4).padding(.trailing, 10).padding(.vertical, 4)
        .background(color.opacity(0.14), in: Capsule())
    }
}

/// 녹음 하나 → 학생별 조각
struct RecordingSplitSection: View {
    @EnvironmentObject var data: DataStore
    @EnvironmentObject var store: Store
    var entry: Entry
    @State private var picking: Picking?
    @State private var confirmResplit = false

    enum Picking: Identifiable {
        case move(SNote), leftover
        var id: String { if case .move(let n) = self { return n.uid }; return "leftover" }
    }

    var current: Entry { store.items.first(where: { $0.id == entry.id }) ?? entry }
    var sourceText: String { current.isAudio ? current.transcript : current.text }

    /// 받아쓴 글 안의 순서대로
    var pieces: [SNote] {
        let t = sourceText
        return data.notes(forSource: current.fileName).sorted { a, b in
            func pos(_ n: SNote) -> Int {
                guard let c = n.content, let r = t.range(of: String(c.prefix(14))) else { return Int.max }
                return t.distance(from: t.startIndex, to: r.lowerBound)
            }
            return (pos(a), a.updated_at) < (pos(b), b.updated_at)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("학생별로 나눈 내용", systemImage: "person.2.fill").font(Theme.font(15, .semibold))
                Spacer()
                if data.hasRoster && !sourceText.isEmpty {
                    Button(pieces.isEmpty ? "나누기" : "다시 나누기") {
                        if pieces.isEmpty { resplit() } else { confirmResplit = true }
                    }.font(Theme.font(13, .semibold))
                }
            }
            if !data.hasRoster {
                Text("‘학생’ 탭에 명단을 넣으면 이름이 나온 곳마다 학생별로 나눠 담아요.")
                    .font(Theme.font(13)).foregroundStyle(Theme.soft)
            } else if pieces.isEmpty && current.splitLeftover.isEmpty {
                Text(sourceText.isEmpty ? "글자로 바뀌면 나눌 수 있어요." :
                        current.splitNames == nil ? "아직 나누지 않았어요. ‘나누기’를 누르면 이름이 나온 곳마다 학생별로 담아요."
                                                  : "명단에 있는 이름을 찾지 못했어요. 아래 칩을 눌러 학생을 골라 주세요.")
                    .font(Theme.font(13)).foregroundStyle(Theme.soft)
                if !sourceText.isEmpty { leftoverCard(sourceText, whole: true) }
            }
            if !current.splitLeftover.isEmpty { leftoverCard(current.splitLeftover, whole: false) }
            ForEach(Array(pieces.enumerated()), id: \.element.uid) { i, n in
                pieceCard(n, above: i > 0 ? pieces[i - 1] : nil)
                    .transition(.asymmetric(insertion: .scale(scale: 0.92).combined(with: .opacity),
                                            removal: .move(edge: .leading).combined(with: .opacity)))
            }
        }
        .animation(spring, value: pieces.map { $0.uid + ($0.student_uid ?? "") + ($0.content ?? "") })
        .animation(spring, value: current.splitLeftover)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .sheet(item: $picking) { p in
            switch p {
            case .move(let n):
                StudentPicker(title: "누구 이야기인가요?", suggested: data.candidates(n), current: n.student_uid) { s in
                    withAnimation(spring) { data.moveNote(n, to: s) }
                }
            case .leftover:
                StudentPicker(title: "누구 이야기인가요?", suggested: [], current: nil) { s in
                    withAnimation(spring) {
                        if current.splitLeftover.isEmpty {
                            data.addNote(s, content: sourceText, date: current.createdAt, kind: current.kind, source: current.fileName)
                        } else {
                            store.assignLeftover(current, to: s)
                        }
                    }
                }
            }
        }
        .alert("다시 나눌까요?", isPresented: $confirmResplit) {
            Button("다시 나누기", role: .destructive) { resplit() }
            Button("취소", role: .cancel) {}
        } message: { Text("지금 나눠 둔 조각을 지우고 명단으로 처음부터 다시 나눠요. 직접 고친 내용은 사라져요.") }
    }

    func resplit() {
        withAnimation(spring) { store.splitToStudents(current, text: sourceText, force: true) }
    }

    func pieceCard(_ n: SNote, above: SNote?) -> some View {
        let unsure = data.isUnsure(n)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { picking = .move(n) } label: {
                    StudentChip(student: data.student(n.student_uid), unsure: unsure)
                }
                .buttonStyle(Squishy())
                .id(n.student_uid)
                .transition(.scale.combined(with: .opacity))
                Spacer()
                Menu {
                    Button { picking = .move(n) } label: { Label("다른 학생으로 옮기기", systemImage: "arrow.right.arrow.left") }
                    if let a = above {
                        Button { withAnimation(spring) { data.mergeNotes(n, into: a) } } label: {
                            Label("위 조각과 합치기", systemImage: "arrow.up.and.down.text.horizontal")
                        }
                    }
                    Button(role: .destructive) { withAnimation(spring) { data.deleteNote(n) } } label: {
                        Label("이 조각 빼기", systemImage: "minus.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.soft)
                        .frame(width: 32, height: 28)
                }
            }
            Text(n.content ?? "").font(Theme.font(15)).fixedSize(horizontal: false, vertical: true)
            if unsure {
                HStack(spacing: 8) {
                    Text(data.isGuess(n) ? "✨ 기기 안 AI가 짐작했어요" : "이름이 같은 학생이 있어요")
                        .font(Theme.font(12, .semibold)).foregroundStyle(Theme.butter)
                    Spacer()
                    Button("맞아요") { withAnimation(spring) { data.confirmNote(n) } }
                        .font(Theme.font(12, .bold)).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Theme.mint.opacity(0.16), in: Capsule()).foregroundStyle(Theme.mint)
                    Button("다른 학생") { picking = .move(n) }
                        .font(Theme.font(12, .bold)).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Theme.butter.opacity(0.18), in: Capsule()).foregroundStyle(Theme.butter)
                }
                .buttonStyle(Squishy())
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(unsure ? Theme.butter.opacity(0.6) : .clear, lineWidth: 1.5))
    }

    func leftoverCard(_ text: String, whole: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { picking = .leftover } label: { StudentChip(student: nil, unsure: true) }.buttonStyle(Squishy())
                Spacer()
                if !whole {
                    Button { withAnimation(spring) { store.dropLeftover(current) } } label: {
                        Text("학생 얘기 아님").font(Theme.font(12, .bold)).padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.gray.opacity(0.14), in: Capsule()).foregroundStyle(Theme.soft)
                    }.buttonStyle(Squishy())
                }
            }
            Text(text).font(Theme.font(15)).foregroundStyle(Theme.soft).lineLimit(whole ? 6 : nil)
                .fixedSize(horizontal: false, vertical: true)
            Text("이름이 안 나온 부분이에요. 칩을 눌러 학생을 골라 주세요.").font(Theme.font(12)).foregroundStyle(Theme.soft)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.bg))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).foregroundStyle(Theme.soft.opacity(0.5)))
    }
}

/// 학생 고르기: 검색 + 반별 목록. 추천(동명이인 후보)이 있으면 맨 위에.
struct StudentPicker: View {
    @EnvironmentObject var data: DataStore
    @Environment(\.dismiss) private var dismiss
    var title: String
    var suggested: [SStudent]
    var current: String?
    var onPick: (SStudent) -> Void
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if !suggested.isEmpty && query.isEmpty {
                    Section("이 중 누구인가요?") {
                        ForEach(suggested) { s in row(s, showClass: true) }
                    }
                }
                ForEach(data.activeClasses) { c in
                    let list = data.students(in: c).filter { query.isEmpty || $0.displayName.contains(query) || ($0.aliases ?? "").contains(query) }
                    if !list.isEmpty {
                        Section(c.title) { ForEach(list) { s in row(s, showClass: false) } }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "이름 찾기")
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    func row(_ s: SStudent, showClass: Bool) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onPick(s); dismiss()
        } label: {
            HStack(spacing: 12) {
                Text(s.number.map(String.init) ?? "–").font(Theme.font(13, .bold)).foregroundStyle(Theme.soft).frame(width: 24)
                Text(s.displayName).font(Theme.font(16, .semibold)).foregroundStyle(Theme.ink)
                if showClass || !data.sameName(s).isEmpty, let c = data.classOf(s) {
                    Text(c.title).font(Theme.font(12)).foregroundStyle(Theme.soft)
                }
                Spacer()
                if s.uid == current { Image(systemName: "checkmark").foregroundStyle(Theme.blue) }
            }
        }
    }
}

/// 학생 이름·번호·별칭 고치기 + 다른 학생과 합치기
struct StudentEditSheet: View {
    @EnvironmentObject var data: DataStore
    @Environment(\.dismiss) private var dismiss
    var student: SStudent
    var onMerged: () -> Void = {}
    @State private var name = ""
    @State private var number = ""
    @State private var aliases = ""
    @State private var merging = false
    @State private var mergeTarget: SStudent?

    var body: some View {
        NavigationStack {
            Form {
                Section("이름") {
                    TextField("이름", text: $name)
                    TextField("번호", text: $number).keyboardType(.numberPad)
                }
                Section {
                    TextField("예) 민수, 김민쑤", text: $aliases)
                } header: { Text("다르게 불리는 이름") } footer: {
                    Text("별명이나 받아쓰기가 자주 잘못 적는 이름을 쉼표로 적어 두면, 그 말이 나와도 이 학생 기록으로 담아요.")
                }
                Section {
                    Button { merging = true } label: { Label("다른 학생과 합치기", systemImage: "person.2.badge.plus") }
                } footer: { Text("같은 학생이 두 번 들어갔을 때 써요. 이 학생의 기록이 고른 학생에게 옮겨 가고, 이 이름은 별칭으로 남아요.") }
            }
            .navigationTitle("학생 정보").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        data.updateStudent(student, name: name, number: Int(number), aliases: aliases)
                        dismiss()
                    }.disabled(name.trimmingCharacters(in: .whitespaces).count < 2)
                }
            }
            .onAppear { name = student.displayName; number = student.number.map(String.init) ?? ""; aliases = student.aliases ?? "" }
            .sheet(isPresented: $merging) {
                StudentPicker(title: "어느 학생과 합칠까요?", suggested: data.sameName(student), current: student.uid) { s in
                    if s.uid != student.uid { mergeTarget = s }
                }
            }
            .alert("\(student.displayName) → \(mergeTarget?.displayName ?? "")", isPresented: Binding(get: { mergeTarget != nil }, set: { if !$0 { mergeTarget = nil } })) {
                Button("합치기", role: .destructive) {
                    if let t = mergeTarget { data.mergeStudent(student, into: t) }
                    mergeTarget = nil; dismiss(); onMerged()
                }
                Button("취소", role: .cancel) { mergeTarget = nil }
            } message: { Text("기록을 모두 옮기고 ‘\(student.displayName)’ 항목은 없앨까요?") }
        }
    }
}
