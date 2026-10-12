import Foundation
import UIKit

enum SyncError: LocalizedError {
    case noICloud, server(String)
    var errorDescription: String? {
        switch self {
        case .noICloud: return "iCloud에 로그인되어 있지 않습니다."
        case .server(let m): return m
        }
    }
}

enum Sync {
    static let container = "iCloud.kr.sseudam.app"

    /// iCloud Drive의 '쓰담' 폴더(맥: ~/Library/Mobile Documents/iCloud~kr~sseudam~app/Documents)에 복사
    static func copyToICloud(_ file: URL) async throws {
        try await Task.detached(priority: .utility) {
            guard let root = FileManager.default.url(forUbiquityContainerIdentifier: container) else { throw SyncError.noICloud }
            let docs = root.appendingPathComponent("Documents", isDirectory: true)
            try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
            let dest = docs.appendingPathComponent(file.lastPathComponent)
            var coordError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(writingItemAt: dest, options: .forReplacing, error: &coordError) { url in
                do {
                    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                    try FileManager.default.copyItem(at: file, to: url)
                } catch { copyError = error }
            }
            if let e = coordError ?? copyError { throw e }
        }.value
    }

    /// 선생님 본인의 구글 Apps Script(쓰담이 만든 것)로 업로드 → 드라이브 '쓰담 녹음함'
    static func uploadToGoogle(file: URL, entry r: Entry, url: String, token: String) async throws {
        guard let endpoint = URL(string: url) else { throw SyncError.server("연결 주소가 올바르지 않습니다.") }
        let data = try Data(contentsOf: file)
        let device = await MainActor.run { UIDevice.current.model }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        let body: [String: Any] = [
            "action": "upload_recording", "token": token, "filename": file.lastPathComponent,
            "mime": r.isAudio ? "audio/mp4" : "text/plain",
            "data": data.base64EncodedString(), "recorded_at": f.string(from: r.createdAt), "kind": r.kind,
            "title": file.deletingPathExtension().lastPathComponent, "memo": r.memo, "device": device,
        ]
        try await post(endpoint, body)
    }

    static func ping(url: String, token: String) async throws {
        guard let endpoint = URL(string: url) else { throw SyncError.server("연결 주소가 올바르지 않습니다.") }
        try await post(endpoint, ["action": "ping_phone", "token": token])
    }

    @discardableResult
    static func post(_ endpoint: URL, _ body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: endpoint, timeoutInterval: 300)
        req.httpMethod = "POST"
        req.setValue("text/plain;charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)  // Apps Script의 302 → GET 리다이렉트를 따라감
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw SyncError.server("연결 실패 (\((resp as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SyncError.server("응답을 이해하지 못했습니다. 컴퓨터의 구글 연결 스크립트를 최신으로 다시 배포해 주세요.")
        }
        if obj["ok"] as? Bool != true { throw SyncError.server(obj["error"] as? String ?? "알 수 없는 오류") }
        return obj
    }

    /// sseudam://pair?u=...&t=...&n=...  (예전 seteuk:// 도 허용)
    static func parsePairing(_ text: String) -> (url: String, token: String, name: String)? {
        guard let comps = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["sseudam", "seteuk"].contains(comps.scheme ?? ""), comps.host == "pair" else { return nil }
        let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        guard let u = q["u"], let t = q["t"], u.hasPrefix("https://"), !t.isEmpty else { return nil }
        return (u, t, q["n"] ?? "")
    }
}

enum Keychain {
    // 키체인을 못 쓰는 환경(서명 없는 시뮬레이터 등)에서는 기기 안 설정에 보관 — 업로드 전용 열쇠라 위험이 낮음
    static func set(_ key: String, _ value: String) {
        delete(key)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                kSecValueData as String: Data(value.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        if SecItemAdd(q as CFDictionary, nil) != errSecSuccess {
            UserDefaults.standard.set(value, forKey: "kc." + key)
        }
    }
    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data {
            return String(data: d, encoding: .utf8)
        }
        return UserDefaults.standard.string(forKey: "kc." + key)
    }
    static func delete(_ key: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key] as CFDictionary)
        UserDefaults.standard.removeObject(forKey: "kc." + key)
    }
}
