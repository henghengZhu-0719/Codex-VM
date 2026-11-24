import Foundation
import Security

struct BrowserVaultEntry: Identifiable, Codable, Equatable {
    var id: String
    var domain: String
    var username: String
    var password: String
    var note: String
    var updatedAt: TimeInterval

    init(id: String = UUID().uuidString, domain: String, username: String, password: String, note: String = "", updatedAt: TimeInterval = Date().timeIntervalSince1970) {
        self.id = id
        self.domain = Self.normalizeDomain(domain)
        self.username = username
        self.password = password
        self.note = note
        self.updatedAt = updatedAt
    }

    static func normalizeDomain(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty { return "" }
        if let url = URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)"),
           let host = url.host, !host.isEmpty {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return trimmed
    }

    func matches(urlString: String) -> Bool {
        let host = Self.normalizeDomain(urlString)
        guard !host.isEmpty, !domain.isEmpty else { return false }
        return host == domain || host.hasSuffix("." + domain) || domain.hasSuffix("." + host)
    }
}

/// Host-side encrypted password vault backed by macOS Keychain (`Security.framework`).
/// Credentials stay in the user's macOS Keychain and are never persisted inside the Linux VM.
final class BrowserVaultStore: ObservableObject {
    static let shared = BrowserVaultStore()

    @Published private(set) var entries: [BrowserVaultEntry] = []
    @Published var lastError: String = ""

    private let service = "org.agentvm.desktop.browser-vault"
    private let account = "vault-entries-v1"

    private init() {
        load()
    }

    func load() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            if let decoded = try? JSONDecoder().decode([BrowserVaultEntry].self, from: data) {
                entries = decoded.sorted { $0.updatedAt > $1.updatedAt }
                lastError = ""
                return
            }
        } else if status != errSecItemNotFound {
            lastError = "读取 Keychain 失败 (OSStatus \(status))"
        }
        entries = []
    }

    @discardableResult
    func upsert(id: String? = nil, domain: String, username: String, password: String, note: String = "") -> Bool {
        let normDomain = BrowserVaultEntry.normalizeDomain(domain)
        guard !normDomain.isEmpty, !username.isEmpty, !password.isEmpty else {
            lastError = "请填写站点域名、用户名和密码。"
            return false
        }
        var next = entries
        if let id, let idx = next.firstIndex(where: { $0.id == id }) {
            next[idx] = BrowserVaultEntry(id: id, domain: normDomain, username: username, password: password, note: note)
        } else if let idx = next.firstIndex(where: { $0.domain == normDomain && $0.username == username }) {
            next[idx] = BrowserVaultEntry(id: next[idx].id, domain: normDomain, username: username, password: password, note: note)
        } else {
            next.insert(BrowserVaultEntry(domain: normDomain, username: username, password: password, note: note), at: 0)
        }
        return save(next)
    }

    @discardableResult
    func delete(id: String) -> Bool {
        let next = entries.filter { $0.id != id }
        return save(next)
    }

    func sortedEntries(forURL urlString: String) -> [BrowserVaultEntry] {
        entries.sorted { a, b in
            let am = a.matches(urlString: urlString)
            let bm = b.matches(urlString: urlString)
            if am != bm { return am }
            return a.updatedAt > b.updatedAt
        }
    }

    private func save(_ next: [BrowserVaultEntry]) -> Bool {
        guard let data = try? JSONEncoder().encode(next) else {
            lastError = "序列化密码库失败。"
            return false
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        let finalStatus: OSStatus
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            finalStatus = SecItemAdd(addQuery as CFDictionary, nil)
        } else {
            finalStatus = updateStatus
        }
        if finalStatus == errSecSuccess {
            entries = next.sorted { $0.updatedAt > $1.updatedAt }
            lastError = ""
            return true
        }
        lastError = "写入 Keychain 失败 (OSStatus \(finalStatus))"
        return false
    }
}
