import Foundation
import UIKit

enum SyncState: String, Codable { case off, pending, done, failed }

/// 기록 한 건: 녹음(audio) 또는 한 줄 메모(text). 파일 이름에 날짜·유형·메모가 들어가
/// 컴퓨터의 쓰담이 시간표·학급을 알아서 판단한다. (예: "쓰담 20261012 1030 상담 2-3.m4a")
struct Entry: Codable, Identifiable, Equatable {
    var id = UUID()
    var type: String = "audio"          // audio | text
    var fileName: String
    var createdAt: Date
    var duration: Double = 0
    var kind: String = "수업"           // 수업 | 상담
    var memo: String = ""
    var text: String = ""
    var icloud: SyncState = .off
    var google: SyncState = .off
    var lastError: String = ""
    /// 저장한 시각 (녹음 시작 시각과 다름) — 보내기 전 고칠 시간 계산용
    var savedAt: Date? = nil

    var isAudio: Bool { type == "audio" }
    var editableUntil: Date { (savedAt ?? createdAt).addingTimeInterval(Store.grace) }
    var title: String { isAudio ? (memo.isEmpty ? "녹음 \(timeString(duration))" : memo) : text }

    init(type: String, fileName: String, createdAt: Date, duration: Double = 0, kind: String = "수업", memo: String = "", text: String = "") {
        self.type = type; self.fileName = fileName; self.createdAt = createdAt
        self.duration = duration; self.kind = kind; self.memo = memo; self.text = text
    }

    // 1.0 형식(Recording)도 읽기
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "audio"
        fileName = try c.decode(String.self, forKey: .fileName)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "수업"
        memo = try c.decodeIfPresent(String.self, forKey: .memo) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        icloud = try c.decodeIfPresent(SyncState.self, forKey: .icloud) ?? .off
        google = try c.decodeIfPresent(SyncState.self, forKey: .google) ?? .off
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError) ?? ""
        savedAt = try c.decodeIfPresent(Date.self, forKey: .savedAt)
    }
}

@MainActor
final class Store: ObservableObject {
    static let shared = Store()
    /// 저장 직후 이 시간 동안은 보내지 않고 기다린다 (수업/상담·메모를 고칠 수 있게)
    static let grace: TimeInterval = 20

    @Published var items: [Entry] = []
    @Published var icloudAvailable = false
    @Published var syncing = false
    @Published var justSaved: UUID?

    let defaults = UserDefaults.standard
    var onboarded: Bool {
        get { defaults.bool(forKey: "onboarded") }
        set { defaults.set(newValue, forKey: "onboarded"); objectWillChange.send() }
    }
    /// 선생님 컴퓨터 종류 — 연결 화면에서 추천 방법을 고를 때 사용
    var computer: String {
        get { defaults.string(forKey: "computer") ?? "mac" }
        set { defaults.set(newValue, forKey: "computer"); objectWillChange.send() }
    }
    var useICloud: Bool {
        get { defaults.object(forKey: "useICloud") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "useICloud"); objectWillChange.send(); Task { await syncAll() } }
    }
    var lastKind: String {
        get { defaults.string(forKey: "lastKind") ?? "수업" }
        set { defaults.set(newValue, forKey: "lastKind") }
    }
    /// 컴퓨터로 보낸 기록을 휴대폰에서 지울 시점(일). 0 = 지우지 않음(기본 — 학기말까지 보관)
    var deleteAfterDays: Int {
        get { defaults.integer(forKey: "deleteAfterDays") }
        set { defaults.set(newValue, forKey: "deleteAfterDays"); objectWillChange.send() }
    }
    var googleURL: String { defaults.string(forKey: "googleURL") ?? "" }
    var googleToken: String { Keychain.get("googleToken") ?? "" }
    var teacherName: String { defaults.string(forKey: "teacherName") ?? "" }
    var googlePaired: Bool { !googleURL.isEmpty && !googleToken.isEmpty }
    var autoSend: Bool { googlePaired || (useICloud && icloudAvailable) }

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

    func url(_ e: Entry) -> URL { Store.folder.appendingPathComponent(e.fileName) }

    var pendingCount: Int { items.filter { $0.icloud == .pending || $0.google == .pending || $0.icloud == .failed || $0.google == .failed }.count }
    var todayCount: Int { items.filter { Calendar.current.isDateInToday($0.createdAt) }.count }

    // MARK: 저장
    func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        items = list.filter { FileManager.default.fileExists(atPath: url($0).path) }
    }

    func save() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: indexURL, options: .atomic) }
    }

    private func baseName(date: Date, kind: String, memo: String, suffix: String = "") -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR"); f.dateFormat = "yyyyMMdd HHmm"
        var name = "쓰담 " + f.string(from: date)
        if kind == "상담" { name += " 상담" }
        if !suffix.isEmpty { name += " " + suffix }
        let clean = memo.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        if !clean.isEmpty { name += " " + String(clean.prefix(30)) }
        return name
    }

    private func uniqueFile(_ name: String, _ ext: String, excluding: String? = nil) -> String {
        var fileName = "\(name).\(ext)"; var i = 2
        while fileName != excluding && FileManager.default.fileExists(atPath: Store.folder.appendingPathComponent(fileName).path) {
            fileName = "\(name) (\(i)).\(ext)"; i += 1
        }
        return fileName
    }

    private func newEntry(_ e: Entry) -> Entry {
        var e = e
        e.savedAt = Date()
        e.icloud = useICloud && icloudAvailable ? .pending : .off
        e.google = googlePaired ? .pending : .off
        items.insert(e, at: 0)
        save()
        justSaved = e.id
        scheduleSync()
        return e
    }

    /// 녹음을 바로 저장 (묻지 않음). 유형은 지난번과 같게 — 저장 후 카드에서 바꿀 수 있다.
    @discardableResult
    func addAudio(tempFile: URL, duration: Double, at date: Date) -> Entry {
        let kind = lastKind
        let fileName = uniqueFile(baseName(date: date, kind: kind, memo: ""), "m4a")
        try? FileManager.default.moveItem(at: tempFile, to: Store.folder.appendingPathComponent(fileName))
        return newEntry(Entry(type: "audio", fileName: fileName, createdAt: date, duration: duration, kind: kind))
    }

    /// 한 줄 메모 저장 → 텍스트 파일로 컴퓨터에 전달
    @discardableResult
    func addText(_ text: String, kind: String, at date: Date = Date()) -> Entry? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        lastKind = kind
        let fileName = uniqueFile(baseName(date: date, kind: kind, memo: "", suffix: "메모"), "txt")
        try? t.data(using: .utf8)?.write(to: Store.folder.appendingPathComponent(fileName))
        return newEntry(Entry(type: "text", fileName: fileName, createdAt: date, kind: kind, text: t))
    }

    /// 유형·메모 바꾸기. 아직 보내기 전이면 파일 이름도 바꿔 컴퓨터가 올바로 알아듣게 한다.
    func edit(_ e: Entry, kind: String? = nil, memo: String? = nil, text: String? = nil) {
        guard var cur = items.first(where: { $0.id == e.id }) else { return }
        if let k = kind { cur.kind = k; lastKind = k }
        if let m = memo { cur.memo = m }
        if let t = text, !cur.isAudio { cur.text = t; try? t.data(using: .utf8)?.write(to: url(cur)) }
        let notSent = cur.icloud != .done && cur.google != .done
        if notSent {
            let ext = cur.isAudio ? "m4a" : "txt"
            let name = baseName(date: cur.createdAt, kind: cur.kind, memo: cur.memo, suffix: cur.isAudio ? "" : "메모")
            let newName = uniqueFile(name, ext, excluding: cur.fileName)
            if newName != cur.fileName {
                try? FileManager.default.moveItem(at: url(cur), to: Store.folder.appendingPathComponent(newName))
                cur.fileName = newName
            }
        }
        update(cur)
    }

    func delete(_ e: Entry) {
        try? FileManager.default.removeItem(at: url(e))
        items.removeAll { $0.id == e.id }
        save()
    }

    func update(_ e: Entry) {
        if let i = items.firstIndex(where: { $0.id == e.id }) { items[i] = e; save() }
    }

    // MARK: 보내기
    private var syncTask: Task<Void, Never>?

    func scheduleSync() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((Store.grace + 1) * 1_000_000_000))
            await self?.syncAll()
        }
    }

    /// 대기·실패한 기록을 모두 보낸다. 앱이 켜질 때·돌아올 때·저장 후 잠시 뒤 호출.
    func syncAll(force: Bool = false) async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        icloudAvailable = FileManager.default.ubiquityIdentityToken != nil
        let now = Date()
        for e in items {
            if !force && now < e.editableUntil { continue }  // 고칠 시간
            var cur = e
            if useICloud && icloudAvailable && [.pending, .failed, .off].contains(cur.icloud) {
                do { try await Sync.copyToICloud(url(cur)); cur.icloud = .done }
                catch { cur.icloud = .failed; cur.lastError = "iCloud: \(error.localizedDescription)" }
                update(cur)
            }
            if googlePaired && [.pending, .failed, .off].contains(cur.google) {
                let bg = UIApplication.shared.beginBackgroundTask(withName: "upload")
                do {
                    try await Sync.uploadToGoogle(file: url(cur), entry: cur, url: googleURL, token: googleToken)
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

    /// 선생님이 고른 경우에만, 컴퓨터로 전송이 끝난 기록을 휴대폰에서 지운다. 기본은 지우지 않음.
    func cleanupOld() {
        guard deleteAfterDays > 0 else { return }
        let limit = Date().addingTimeInterval(-Double(deleteAfterDays) * 24 * 3600)
        let old = items.filter { $0.createdAt < limit && ![.pending, .failed].contains($0.icloud)
            && ![.pending, .failed].contains($0.google) && ($0.icloud == .done || $0.google == .done) }
        old.forEach(delete)
    }

    func pair(url: String, token: String, name: String) {
        defaults.set(url, forKey: "googleURL")
        defaults.set(name, forKey: "teacherName")
        Keychain.set("googleToken", token)
        for i in items.indices where items[i].google == .off { items[i].google = .pending }
        save()
        objectWillChange.send()
        Task { await syncAll(force: true) }
    }

    func unpair() {
        defaults.removeObject(forKey: "googleURL")
        Keychain.delete("googleToken")
        for i in items.indices where items[i].google != .done { items[i].google = .off }
        save()
        objectWillChange.send()
    }
}

func timeString(_ t: TimeInterval) -> String {
    let s = Int(t)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}
