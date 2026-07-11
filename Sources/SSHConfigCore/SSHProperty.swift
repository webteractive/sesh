public struct SSHProperty: Codable, Equatable, Sendable {
    public var key: String
    public var values: [String]

    public init(key: String, values: [String]) {
        self.key = key
        self.values = values
    }
}

public extension [SSHProperty] {
    /// First value for a key, case-insensitive.
    func first(_ key: String) -> String? {
        first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.values.first
    }

    /// Replace all values for a key with a single value; nil/empty removes the key.
    mutating func set(_ key: String, _ value: String?) {
        if let value, !value.isEmpty {
            if let i = firstIndex(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) {
                self[i] = SSHProperty(key: self[i].key, values: [value])
            } else {
                append(SSHProperty(key: key, values: [value]))
            }
        } else {
            removeAll { $0.key.caseInsensitiveCompare(key) == .orderedSame }
        }
    }

    /// Lowercased-key map for order-insensitive comparison (conflict detection).
    var normalized: [String: [String]] {
        var out: [String: [String]] = [:]
        for p in self { out[p.key.lowercased(), default: []].append(contentsOf: p.values) }
        return out
    }
}
