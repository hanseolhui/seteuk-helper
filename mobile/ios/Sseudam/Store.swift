import Foundation
import UIKit

enum SyncState: String, Codable { case off, pending, done, failed }

struct Recording: Codable, Identifiable, Equatable {
    var id = UUID()
    var fileName: String
    var createdAt: Date
    var duration: Double
    var kind: String          // 수업 | 상담
    var memo: String
    var icloud: SyncState = .off
    var google: SyncState = .off
    var lastError: String = ""
}

/// 녹음 목록과 동기화(iCloud · 구글 드라이브)를 관리한다.
@MainActor
final class Store: ObservableObject {
    static let shared = Store()
    @Published var items: [Recording] = []
    @Published var icloudAvailable = false
    @Published var syncing = false

    let defaults = UserDefaults.standard
    var useICloud: Bool {
        get { defaults.object(forKey: "useICloud") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "useICloud"); objectWillChange.send() }
    }
    var googleURL: String { defaults.string(forKey: "googleURL") ?? "" }
    var googleToken: String { Keychain.get("googleToken") ?? "" }
    var teacherName: String { defaults.string(forKey: "teacherName") ?? "" }
    /// 컴퓨터로 보낸 녹음을 휴대폰에서 지울 시점(일). 0 = 지우지 않음(기본 — 학기말까지 보관)
    var deleteAfterDays: Int {
        get { defaults.integer(forKey: "deleteAfterDays") }
        set { defaults.set(newValue, forKey: "deleteAfterDays"); objectWillChange.send() }
    }
    var googlePaired: Bool { !googleURL.isEmpty && !googleToken.isEmpty }

    static let folder: URL = {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Recordings")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private var indexURL: URL { Store.folder.appendingPathComponent("index.json") }

    init() {
        load()
        icloudAvailable = FileManager.default.ubiquityIdentityToken != nil
    }

    func url(_ r: Recording) -> URL { Store.folder.appendingPathComponent(r.fileName) }

    func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([Recording].self, from: data) else { return }
        items = list.filter { FileManager.default.fileExists(atPath: url($0).path) }
    }

    func save() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: indexURL, options: .atomic) }
    }

    func add(tempFile: URL, duration: Double, kind: String, memo: String, at date: Date) {
        let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR"); f.dateFormat = "yyyyMMdd HHmm"
        var name = "쓰담 " + f.string(from: date)
        if kind == "상담" { name += " 상담" }
        let cleanMemo = memo.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n")).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        if !cleanMemo.isEmpty { name += " " + String(cleanMemo.prefix(30)) }
        var fileName = name + ".m4a"
        var i = 2
        while FileManager.default.fileExists(atPath: Store.folder.appendingPathComponent(fileName).path) {
            fileName = "\(name) (\(i)).m4a"; i += 1
        }
        try? FileManager.default.moveItem(at: tempFile, to: Store.folder.appendingPathComponent(fileName))
        var r = Recording(fileName: fileName, createdAt: date, duration: duration, kind: kind, memo: memo)
        r.icloud = useICloud && icloudAvailable ? .pending : .off
        r.google = googlePaired ? .pending : .off
        items.insert(r, at: 0)
        save()
        Task { await syncAll() }
    }

    func delete(_ r: Recording) {
        try? FileManager.default.removeItem(at: url(r))
        items.removeAll { $0.id == r.id }
        save()
    }

    func update(_ r: Recording) {
        if let i = items.firstIndex(where: { $0.id == r.id }) { items[i] = r; save() }
    }

    /// 대기·실패한 녹음을 모두 보낸다. 앱이 켜질 때·화면으로 돌아올 때·녹음 저장 후 호출.
    func syncAll() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        icloudAvailable = FileManager.default.ubiquityIdentityToken != nil
        for r in items {
            var cur = r
            if useICloud && icloudAvailable && (cur.icloud == .pending || cur.icloud == .failed || cur.icloud == .off) {
                do { try await Sync.copyToICloud(url(cur)); cur.icloud = .done }
                catch { cur.icloud = .failed; cur.lastError = "iCloud: \(error.localizedDescription)" }
                update(cur)
            }
            if googlePaired && (cur.google == .pending || cur.google == .failed || cur.google == .off) {
                let bg = UIApplication.shared.beginBackgroundTask(withName: "upload")
                do {
                    try await Sync.uploadToGoogle(file: url(cur), recording: cur, url: googleURL, token: googleToken)
                    cur.google = .done; cur.lastError = ""
                } catch {
                    cur.google = .failed; cur.lastError = "구글: \(error.localizedDescription)"
                }
                UIApplication.shared.endBackgroundTask(bg)
                update(cur)
            }
        }
        cleanupOld()
    }

    /// 선생님이 고른 경우에만, 컴퓨터로 전송이 끝난 녹음을 휴대폰에서 지운다. 기본은 지우지 않음.
    func cleanupOld() {
        guard deleteAfterDays > 0 else { return }
        let limit = Date().addingTimeInterval(-Double(deleteAfterDays) * 24 * 3600)
        let old = items.filter { $0.createdAt < limit && $0.icloud != .pending && $0.icloud != .failed
            && $0.google != .pending && $0.google != .failed && ($0.icloud == .done || $0.google == .done) }
        old.forEach(delete)
    }

    func pair(url: String, token: String, name: String) {
        defaults.set(url, forKey: "googleURL")
        defaults.set(name, forKey: "teacherName")
        Keychain.set("googleToken", token)
        for i in items.indices where items[i].google == .off { items[i].google = .pending }
        save()
        objectWillChange.send()
        Task { await syncAll() }
    }

    func unpair() {
        defaults.removeObject(forKey: "googleURL")
        Keychain.delete("googleToken")
        for i in items.indices where items[i].google != .done { items[i].google = .off }
        save()
        objectWillChange.send()
    }
}
