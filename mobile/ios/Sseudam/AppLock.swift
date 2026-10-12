import LocalAuthentication
import SwiftUI

/// 앱 잠금 (Face ID · Touch ID · 암호). 학생 이름과 기록이 있으니 원하면 켤 수 있게.
/// 켜 두면 앱을 나갔다가 1분 넘게 지나 돌아올 때, 그리고 앱 전환 화면에서 내용을 가린다.
@MainActor
final class AppLock: ObservableObject {
    static let shared = AppLock()
    @Published var locked = false
    @Published var covered = false
    private var leftAt: Date?

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "appLock") }
        set { UserDefaults.standard.set(newValue, forKey: "appLock"); objectWillChange.send() }
    }

    init() { locked = enabled }

    var biometryName: String {
        let c = LAContext()
        _ = c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch c.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "기기 암호"
        }
    }

    func phase(_ p: ScenePhase) {
        guard enabled else { covered = false; locked = false; return }
        switch p {
        case .background:
            leftAt = Date(); covered = true
        case .inactive:
            covered = true
        case .active:
            if let t = leftAt, Date().timeIntervalSince(t) > 60 { locked = true }
            leftAt = nil
            covered = false
            if locked { Task { await unlock() } }
        @unknown default: break
        }
    }

    func unlock() async {
        let c = LAContext()
        c.localizedFallbackTitle = "암호 입력"
        do {
            if try await c.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "쓰담의 학생 기록을 열어요") {
                withAnimation(.easeOut(duration: 0.25)) { locked = false }
            }
        } catch {}
    }

    /// 켤 때 한 번 확인 (본인만 켜고 끌 수 있게)
    func setEnabled(_ on: Bool) async {
        let c = LAContext()
        guard (try? await c.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: on ? "앱 잠금을 켜요" : "앱 잠금을 꺼요")) == true else { return }
        enabled = on
    }
}

struct LockScreen: View {
    @ObservedObject var lock = AppLock.shared
    var body: some View {
        VStack(spacing: 18) {
            Dami(size: 96, mood: .calm)
            Text("쓰담이 잠겨 있어요").font(Theme.font(22, .bold))
            Text("학생 기록을 지키고 있어요 🔒").font(Theme.font(15)).foregroundStyle(Theme.soft)
            if lock.locked {
                Button { Task { await lock.unlock() } } label: {
                    Label("\(lock.biometryName)로 열기", systemImage: "lock.open.fill").font(Theme.font(17, .bold))
                        .padding(.horizontal, 26).padding(.vertical, 13)
                        .background(Theme.brand, in: Capsule()).foregroundStyle(.white)
                }.buttonStyle(Squishy())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .softBackground()
    }
}
