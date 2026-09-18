import Foundation

extension Preferences {
    func engineJSON() -> String {
        let rules = customRules.map { ["id": $0.id, "pattern": $0.pattern, "score": $0.score] as [String: Any] }
        let config: [String: Any] = ["threshold": threshold, "known": known, "generic": generic,
            "personal": personal, "emails": emails, "phones": phones, "custom_rules": rules,
            "allowed_hashes": allowedHashes, "allowed_paths": allowedPaths, "disabled_rules": disabledRules]
        return String(data: try! JSONSerialization.data(withJSONObject: config), encoding: .utf8)!
    }
}
