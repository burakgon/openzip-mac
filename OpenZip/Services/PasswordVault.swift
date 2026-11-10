import Foundation
import Security

/// The passwords the user asked OpenZip to remember, kept in the login keychain.
///
/// They are tried, the newest first, on an archive that asks for a password, before the
/// user is asked; and one of them can be picked for a new archive. This is what WinRAR
/// calls organizing passwords, with the keychain as the place to keep them: locked with
/// the Mac, and to be looked at in Keychain Access.
enum PasswordVault {
    struct Entry: Identifiable, Hashable {
        /// What tells it from the others in the keychain.
        let id: String
        /// What it was remembered for: the name of an archive, or what the user called it.
        var label: String
        var saved: Date
    }

    /// Where they are in the keychain. The demo has a place of its own, so that trying
    /// this from a script leaves the user's passwords alone.
    private static let service = Demo.isEnabled ? "OpenZip Archive Passwords (Demo)" : "OpenZip Archive Passwords"
    private static let labelPrefix = "OpenZip: "
    /// More than this are not tried on an archive: every try starts the archive again.
    private static let mostTried = 24

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    }

    /// What is remembered, the newest first. The passwords themselves are not read for this.
    static func entries() -> [Entry] {
        var query = base
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        let entries = items.compactMap { item -> Entry? in
            guard let id = item[kSecAttrAccount as String] as? String else { return nil }
            var label = item[kSecAttrLabel as String] as? String ?? ""
            if label.hasPrefix(labelPrefix) { label.removeFirst(labelPrefix.count) }
            let saved = item[kSecAttrModificationDate as String] as? Date ?? item[kSecAttrCreationDate as String] as? Date ?? .distantPast
            return Entry(id: id, label: label.isEmpty ? "Password" : label, saved: saved)
        }
        return entries.sorted { $0.saved > $1.saved }
    }

    static func password(of entry: Entry) -> String? {
        var query = base
        query[kSecAttrAccount as String] = entry.id
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The passwords to try on an archive, the newest first and each once.
    static func passwords() -> [String] {
        var seen = Set<String>()
        return entries().prefix(mostTried).compactMap(password(of:)).filter { seen.insert($0).inserted }
    }

    /// Remembers a password. One that is remembered already is not remembered twice.
    @discardableResult
    static func save(_ password: String, label: String) -> Bool {
        guard !password.isEmpty else { return false }
        if entries().contains(where: { Self.password(of: $0) == password }) { return false }
        var item = base
        item[kSecAttrAccount as String] = UUID().uuidString
        item[kSecAttrLabel as String] = labelPrefix + label
        item[kSecAttrDescription as String] = "archive password"
        item[kSecValueData as String] = Data(password.utf8)
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func remove(_ entry: Entry) {
        var query = base
        query[kSecAttrAccount as String] = entry.id
        SecItemDelete(query as CFDictionary)
    }

    static func removeAll() {
        entries().forEach(remove)
    }

    /// The remembered passwords that are still to be tried on one archive.
    struct Attempts {
        private var remaining: [String]?

        /// The next one to try after one that failed, or nil when the user has to be
        /// asked. The keychain is only looked into once an archive wants a password.
        mutating func next(after failed: String?) -> String? {
            if remaining == nil { remaining = PasswordVault.passwords() }
            remaining?.removeAll { $0 == failed }
            guard remaining?.isEmpty == false else { return nil }
            return remaining?.removeFirst()
        }
    }
}
