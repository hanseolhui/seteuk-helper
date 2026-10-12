import SwiftUI

struct RecordView: View {
    @EnvironmentObject var store: Store
    @StateObject private var rec = Recorder()
    @State private var pending: (URL, TimeInterval, Date)?
    @State private var kind = "수업"
    @State private var memo = ""
    @State private var showSaved = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Text(timeString(rec.elapsed))
                    .font(.system(size: 64, weight: .light, design: .rounded)).monospacedDigit()
                    .foregroundStyle(rec.isRecording ? .primary : .secondary)
                LevelBar(level: rec.level, active: rec.isRecording && !rec.isPaused)
                    .frame(height: 10).padding(.horizontal, 48)
                Text(statusText).font(.subheadline).foregroundStyle(.secondary)
                Button(action: toggle) {
                    ZStack {
                        Circle().fill(rec.isRecording ? Color.red : Color.accentColor).frame(width: 120, height: 120)
                            .shadow(color: (rec.isRecording ? Color.red : Color.accentColor).opacity(0.35), radius: 16, y: 6)
                        Image(systemName: rec.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 44, weight: .semibold)).foregroundStyle(.white)
                    }
                }
                .accessibilityLabel(rec.isRecording ? "녹음 끝내기" : "녹음 시작")
                if rec.isRecording {
                    Button(rec.isPaused ? "이어서 녹음" : "일시정지") { rec.togglePause() }
                        .buttonStyle(.bordered)
                }
                Spacer()
                tip
            }
            .padding()
            .navigationTitle("쓰담")
            .alert("마이크 권한이 필요합니다", isPresented: $rec.permissionDenied) {
                Button("설정 열기") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                Button("닫기", role: .cancel) {}
            } message: { Text("설정 → 쓰담 → 마이크를 켜 주세요.") }
            .sheet(isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) { saveSheet }
            .overlay(alignment: .top) {
                if showSaved {
                    Label(syncHint, systemImage: "checkmark.circle.fill")
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.thinMaterial, in: Capsule()).padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
    }

    var statusText: String {
        if !rec.isRecording { return "버튼을 누르면 바로 녹음됩니다" }
        return rec.isPaused ? "일시정지됨" : "녹음 중 · 화면을 꺼도 계속 녹음됩니다"
    }

    var syncHint: String {
        if store.googlePaired || (store.useICloud && store.icloudAvailable) { return "저장 완료 · 컴퓨터로 자동 전송됩니다" }
        return "저장 완료 · '연결' 탭에서 컴퓨터와 연결하세요"
    }

    var tip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("이렇게 말하면 학생별로 자동 정리돼요", systemImage: "lightbulb").font(.footnote.weight(.semibold))
            Text("“3번 김민수, 토론에서 근거를 세 가지 들어 반론을 폈음. 7번 이서연, …”")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    var saveSheet: some View {
        NavigationStack {
            Form {
                Section("녹음 \(timeString(pending?.1 ?? 0))") {
                    Picker("유형", selection: $kind) { Text("수업").tag("수업"); Text("상담").tag("상담") }
                        .pickerStyle(.segmented)
                    TextField("메모 (선택) 예: 2-3 국어 토론", text: $memo)
                }
                Section {
                    Text("학급은 컴퓨터의 시간표나 녹음 내용으로 자동 지정됩니다. 메모에 '2-3'처럼 적어도 됩니다.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("녹음 저장").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("버리기", role: .destructive) {
                        if let p = pending { try? FileManager.default.removeItem(at: p.0) }
                        pending = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        if let p = pending { store.add(tempFile: p.0, duration: p.1, kind: kind, memo: memo, at: p.2) }
                        pending = nil; memo = ""
                        withAnimation { showSaved = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { withAnimation { showSaved = false } }
                    }.bold()
                }
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled()
    }

    func toggle() {
        if rec.isRecording {
            if let r = rec.stop() {
                if r.1 < 1 { try? FileManager.default.removeItem(at: r.0) } else { pending = r }
            }
        } else {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            Task { await rec.start() }
        }
    }
}

struct LevelBar: View {
    var level: Float
    var active: Bool
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                Capsule().fill(active ? Color.accentColor : Color.clear)
                    .frame(width: g.size.width * CGFloat(active ? level : 0))
                    .animation(.linear(duration: 0.1), value: level)
            }
        }
    }
}

func timeString(_ t: TimeInterval) -> String {
    let s = Int(t)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
}
