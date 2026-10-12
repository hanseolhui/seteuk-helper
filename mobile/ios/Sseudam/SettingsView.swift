import AVFoundation
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @State private var scanning = false
    @State private var manual = ""
    @State private var testResult = ""
    @State private var showManual = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: Binding(get: { store.useICloud }, set: { store.useICloud = $0; Task { await store.syncAll() } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("iCloud로 보내기")
                            Text(store.icloudAvailable ? "같은 Apple ID로 로그인한 맥의 쓰담이 자동으로 가져갑니다"
                                                       : "이 아이폰이 iCloud에 로그인되어 있지 않습니다")
                                .font(.caption).foregroundStyle(store.icloudAvailable ? Color.secondary : Color.red)
                        }
                    }
                } header: { Text("맥 (같은 Apple ID)") } footer: {
                    Text("맥의 iCloud Drive › '쓰담' 폴더로 저장됩니다. 설정할 것이 없습니다.")
                }

                Section {
                    if store.googlePaired {
                        LabeledContent("연결됨", value: store.teacherName.isEmpty ? "내 구글 드라이브" : "\(store.teacherName) 선생님")
                        Button("연결 확인") { Task { await test() } }
                        if !testResult.isEmpty { Text(testResult).font(.footnote).foregroundStyle(testResult.hasPrefix("✓") ? .green : .red) }
                        Button("연결 끊기", role: .destructive) { store.unpair() }
                    } else {
                        Button { scanning = true } label: { Label("컴퓨터 화면의 QR 찍기", systemImage: "qrcode.viewfinder") }
                        Button("연결 코드 붙여넣기") { showManual = true }
                    }
                } header: { Text("윈도우 PC · 다른 컴퓨터 (구글 드라이브)") } footer: {
                    Text("컴퓨터의 쓰담 → 설정 → '휴대폰 쓰담 앱 연결'에 나오는 QR을 찍으세요. 녹음은 선생님 본인의 구글 드라이브를 거쳐 컴퓨터로 갑니다. 이 앱은 녹음을 올리기만 할 수 있고, 학생 기록을 볼 수는 없습니다.")
                }

                Section {
                    Picker("휴대폰에 보관", selection: Binding(get: { store.deleteAfterDays }, set: { store.deleteAfterDays = $0 })) {
                        Text("계속 보관").tag(0)
                        Text("보낸 뒤 180일 후 지우기").tag(180)
                        Text("보낸 뒤 90일 후 지우기").tag(90)
                    }
                } header: { Text("녹음 보관") } footer: {
                    Text("기본은 계속 보관입니다. 컴퓨터의 쓰담과 구글 드라이브에도 원본이 학기말 이후까지 그대로 보관됩니다. 휴대폰 저장 공간이 부족할 때만 바꾸세요. (컴퓨터로 전송이 끝난 녹음만 지웁니다)")
                }

                Section("도움말") {
                    Label("받아쓰기와 학생별 정리는 컴퓨터의 쓰담이 합니다", systemImage: "desktopcomputer")
                    Link(destination: URL(string: "https://github.com/hanseolhui/sseudam")!) {
                        Label("컴퓨터용 쓰담 설치·사용법", systemImage: "questionmark.circle")
                    }
                    Link(destination: URL(string: "https://hanseolhui.github.io/sseudam/privacy.html")!) {
                        Label("개인정보 처리방침", systemImage: "hand.raised")
                    }
                }
                Section { Text("쓰담 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")").font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("연결")
            .sheet(isPresented: $scanning) {
                QRScanner { code in
                    scanning = false
                    handle(code)
                }.ignoresSafeArea()
            }
            .alert("연결 코드", isPresented: $showManual) {
                TextField("sseudam://pair?…", text: $manual)
                Button("연결") { handle(manual); manual = "" }
                Button("취소", role: .cancel) {}
            }
        }
    }

    func handle(_ code: String) {
        if let p = Sync.parsePairing(code) {
            store.pair(url: p.url, token: p.token, name: p.name)
            Task { await test() }
        } else {
            testResult = "쓰담 연결 QR이 아닙니다."
        }
    }

    func test() async {
        testResult = "확인 중…"
        do { try await Sync.ping(url: store.googleURL, token: store.googleToken); testResult = "✓ 연결되었습니다" }
        catch { testResult = error.localizedDescription }
    }
}

/// 카메라로 QR 읽기
struct QRScanner: UIViewControllerRepresentable {
    var onCode: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerVC { let v = ScannerVC(); v.onCode = onCode; return v }
    func updateUIViewController(_ vc: ScannerVC, context: Context) {}
}

final class ScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var done = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let dev = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: dev),
              session.canAddInput(input) else {
            let l = UILabel(); l.text = "카메라를 쓸 수 없습니다. '연결 코드 붙여넣기'를 이용하세요."
            l.textColor = .white; l.numberOfLines = 0; l.textAlignment = .center
            l.frame = view.bounds.insetBy(dx: 24, dy: 0); view.addSubview(l); return
        }
        session.addInput(input)
        let out = AVCaptureMetadataOutput()
        if session.canAddOutput(out) {
            session.addOutput(out)
            out.setMetadataObjectsDelegate(self, queue: .main)
            out.metadataObjectTypes = [.qr]
        }
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.frame = view.bounds; layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        let hint = UILabel(); hint.text = "컴퓨터 화면의 QR을 비춰 주세요"
        hint.textColor = .white; hint.textAlignment = .center; hint.font = .preferredFont(forTextStyle: .headline)
        hint.frame = CGRect(x: 0, y: view.bounds.height - 140, width: view.bounds.width, height: 40)
        view.addSubview(hint)
        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
    }

    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); session.stopRunning() }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objs: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !done, let s = (objs.first as? AVMetadataMachineReadableCodeObject)?.stringValue, (s.hasPrefix("sseudam://") || s.hasPrefix("seteuk://")) else { return }
        done = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onCode?(s)
    }
}
