import Foundation

public struct NewProfile: Equatable, Sendable {
    public let alias: String
    public let properties: [SSHProperty]
}

public enum ProfileFactory {
    public static func make(baseProperties: [SSHProperty], baseAlias: String,
                            label: String, user: String, identityFile: String?,
                            existingAliases: Set<String>) -> NewProfile {
        // Copy everything except the identity-defining keys, then set ours.
        var props = baseProperties.filter {
            let k = $0.key.lowercased()
            return k != "user" && k != "identityfile"
        }
        props.set("User", user)
        props.set("IdentityFile", identityFile)

        let rawBase = sanitize(baseAlias)
        let safeBase = rawBase.isEmpty ? "host" : rawBase
        let stem = sanitize(label)
        var candidate = "\(safeBase)-\(stem)"
        if existingAliases.contains(candidate) {
            var n = 2
            while existingAliases.contains("\(safeBase)-\(stem)-\(n)") { n += 1 }
            candidate = "\(safeBase)-\(stem)-\(n)"
        }
        return NewProfile(alias: candidate, properties: props)
    }

    private static let allowedExtras: Set<Character> = [".", "_", "-"]

    private static func sanitize(_ label: String) -> String {
        let mapped = label.map { c -> Character in
            (c.isASCII && (c.isLetter || c.isNumber)) || allowedExtras.contains(c) ? c : "-"
        }
        var s = String(mapped)
        while s.contains("--") { s = s.replacingOccurrences(of: "--", with: "-") }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return s.isEmpty ? "profile" : s
    }
}
