import PhotosUI
import SwiftUI
import Vision
import VisionKit

/// 말하기 어려울 때 두 번 톡으로 남기는 빠른 기록
enum QuickTags {
    static let all: [(emoji: String, text: String)] = [
        ("👍", "발표를 자신 있게 함"), ("🤝", "친구를 도와 함께 해결함"), ("❓", "좋은 질문을 함"),
        ("🌱", "지난번보다 한 뼘 성장함"), ("📚", "과제를 성실히 해 옴"), ("💡", "창의적인 아이디어를 냄"),
    ]
}

struct QuickTagRow: View {
    @EnvironmentObject var data: DataStore
    var student: SStudent
    @State private var popped: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(QuickTags.all, id: \.text) { t in
                    Button {
                        data.addNote(student, content: t.text)
                        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { popped = t.text }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { withAnimation { if popped == t.text { popped = nil } } }
                    } label: {
                        HStack(spacing: 4) {
                            Text(t.emoji)
                            Text(popped == t.text ? "담았어요!" : t.text).font(Theme.font(13, .semibold))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background((popped == t.text ? Theme.mint : Theme.lavender).opacity(0.14), in: Capsule())
                        .foregroundStyle(popped == t.text ? Theme.mint : Theme.ink)
                        .scaleEffect(popped == t.text ? 1.08 : 1)
                    }
                    .buttonStyle(Squishy())
                    .accessibilityLabel("\(t.text) 빠른 기록")
                }
            }
        }
    }
}

/// 반 안에서 학생별 기록 수 막대 (누가 적은지 한눈에)
struct CountBar: View {
    var count: Int
    var maxCount: Int
    var color: Color
    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.12))
                    Capsule().fill(count == 0 ? Theme.butter.opacity(0.5) : color)
                        .frame(width: count == 0 ? 6 : max(6, g.size.width * CGFloat(count) / CGFloat(max(1, maxCount))))
                }
            }
            .frame(width: 70, height: 8)
            Text(count == 0 ? "🌱" : "\(count)").font(Theme.font(12, .bold)).foregroundStyle(count == 0 ? Theme.butter : color)
                .frame(minWidth: 18, alignment: .trailing)
        }
        .animation(.spring(response: 0.5), value: count)
        .accessibilityLabel("기록 \(count)개")
    }
}

// MARK: - 사진 속 글자 읽기 (기기 안 Vision, 오프라인)

enum PhotoText {
    static func read(_ image: UIImage) async -> String {
        guard let cg = image.cgImage else { return "" }
        return await withCheckedContinuation { c in
            let req = VNRecognizeTextRequest { r, _ in
                let lines = (r.results as? [VNRecognizedTextObservation])?.compactMap { $0.topCandidates(1).first?.string } ?? []
                c.resume(returning: lines.joined(separator: "\n"))
            }
            req.recognitionLevel = .accurate
            req.recognitionLanguages = ["ko-KR", "en-US"]
            req.usesLanguageCorrection = true
            DispatchQueue.global(qos: .userInitiated).async {
                do { try VNImageRequestHandler(cgImage: cg, orientation: .up).perform([req]) } catch { c.resume(returning: "") }
            }
        }
    }
}

/// 문서 스캐너 (학생 활동지·손글씨를 찍으면 글자로)
struct DocScanner: UIViewControllerRepresentable {
    var onImages: ([UIImage]) -> Void
    func makeCoordinator() -> Coord { Coord(onImages) }
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let v = VNDocumentCameraViewController(); v.delegate = context.coordinator; return v
    }
    func updateUIViewController(_ vc: VNDocumentCameraViewController, context: Context) {}
    final class Coord: NSObject, VNDocumentCameraViewControllerDelegate {
        let done: ([UIImage]) -> Void
        init(_ d: @escaping ([UIImage]) -> Void) { done = d }
        func documentCameraViewController(_ c: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            done((0..<scan.pageCount).map { scan.imageOfPage(at: $0) }); c.dismiss(animated: true)
        }
        func documentCameraViewControllerDidCancel(_ c: VNDocumentCameraViewController) { done([]); c.dismiss(animated: true) }
        func documentCameraViewController(_ c: VNDocumentCameraViewController, didFailWithError error: Error) { done([]); c.dismiss(animated: true) }
    }
}

/// 사진으로 담기 버튼 묶음: 스캔 또는 앨범 → 글자 읽기 → 결과를 넘겨줌 (선생님이 고쳐서 담기)
struct PhotoCaptureButtons: View {
    var onText: (String) -> Void
    @State private var scanning = false
    @State private var pick: PhotosPickerItem?
    @State private var reading = false

    var body: some View {
        HStack(spacing: 8) {
            if VNDocumentCameraViewController.isSupported {
                Button { scanning = true } label: { chip("doc.viewfinder", "활동지 찍기") }
            }
            PhotosPicker(selection: $pick, matching: .images) { chip("photo", "사진에서") }
            if reading { ProgressView().controlSize(.small) }
        }
        .buttonStyle(Squishy())
        .fullScreenCover(isPresented: $scanning) {
            DocScanner { imgs in Task { await handle(imgs) } }.ignoresSafeArea()
        }
        .onChange(of: pick) { item in
            guard let item else { return }
            Task {
                if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d) { await handle([img]) }
                pick = nil
            }
        }
    }

    func handle(_ imgs: [UIImage]) async {
        guard !imgs.isEmpty else { return }
        reading = true
        var parts: [String] = []
        for i in imgs { parts.append(await PhotoText.read(i)) }
        reading = false
        let t = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        onText(t.isEmpty ? "" : t)
    }

    func chip(_ icon: String, _ t: String) -> some View {
        Label(t, systemImage: icon).font(Theme.font(13, .semibold))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Theme.blue.opacity(0.1), in: Capsule()).foregroundStyle(Theme.blue)
    }
}

// MARK: - 학생 한 장 PDF

@MainActor
enum StudentPDF {
    static func make(student: SStudent, cls: SClass?, notes: [SNote], drafts: [SDraft]) -> URL? {
        let view = VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(student.displayName).font(.system(size: 26, weight: .bold, design: .rounded))
                    Text([cls?.title, student.number.map { "\($0)번" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("쓰담").font(.system(size: 14, weight: .heavy, design: .rounded)).foregroundStyle(Theme.blue)
            }
            Divider()
            if !drafts.isEmpty {
                Text("초안").font(.system(size: 15, weight: .bold))
                ForEach(drafts) { d in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(Areas.name(d.area)) · \(neisBytes(d.content ?? ""))바이트").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(d.content ?? "").font(.system(size: 12))
                    }
                }
                Divider()
            }
            Text("관찰 기록 \(notes.count)개").font(.system(size: 15, weight: .bold))
            ForEach(notes.reversed()) { n in
                HStack(alignment: .top, spacing: 10) {
                    Text(n.date ?? "").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
                    Text(n.content ?? "").font(.system(size: 12))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(36)
        .frame(width: 595, alignment: .topLeading)
        .background(Color.white)
        .environment(\.colorScheme, .light)

        let r = ImageRenderer(content: view)
        r.proposedSize = .init(width: 595, height: nil)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("쓰담_\(student.displayName)_\(f.string(from: Date())).pdf")
        var ok = false
        r.render { size, draw in
            let pageH: CGFloat = 842
            var box = CGRect(x: 0, y: 0, width: 595, height: pageH)
            guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            var y: CGFloat = 0
            repeat {   // 길면 A4 여러 장으로
                ctx.beginPDFPage(nil)
                ctx.translateBy(x: 0, y: pageH - size.height + y)
                draw(ctx)
                ctx.endPDFPage()
                y += pageH
            } while y < size.height
            ctx.closePDF()
            ok = true
        }
        return ok ? url : nil
    }
}
