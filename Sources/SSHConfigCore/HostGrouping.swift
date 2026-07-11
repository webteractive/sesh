import Foundation

public struct HostRow: Sendable, Equatable {
    public let alias: String
    public let groupName: String?
    public let user: String?
    public let identityFile: String?
    public let isDefault: Bool
    public let isConnectable: Bool

    public init(alias: String, groupName: String?, user: String?,
                identityFile: String?, isDefault: Bool, isConnectable: Bool) {
        self.alias = alias
        self.groupName = groupName
        self.user = user
        self.identityFile = identityFile
        self.isDefault = isDefault
        self.isConnectable = isConnectable
    }
}

public struct ProfileRef: Identifiable, Sendable, Equatable {
    public let id: String        // == alias
    public let alias: String
    public let label: String
    public let user: String?
    public let identityFile: String?
    public let isDefault: Bool
    public let isConnectable: Bool
}

public struct HostGroupView: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let members: [ProfileRef]
    public var isMultiProfile: Bool { members.count > 1 }
    public var defaultMember: ProfileRef {
        members.first(where: { $0.isDefault }) ?? members[0]
    }
}

public enum HostGrouping {
    /// Fold rows into groups. Rows with the same non-nil groupName collapse into
    /// one group; nil-group rows each become a singleton. Members are ordered
    /// default-first, then by user (nil users last), then by alias. Groups are
    /// ordered by where their first member appears in the input.
    public static func groups(from rows: [HostRow]) -> [HostGroupView] {
        var order: [String] = []          // group key, in first-seen order
        var buckets: [String: [HostRow]] = [:]

        for row in rows {
            let key = row.groupName ?? "\u{0}single:\(row.alias)"
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(row)
        }

        return order.map { key in
            let rows = buckets[key]!
            let sorted = rows.sorted { a, b in
                if a.isDefault != b.isDefault { return a.isDefault }         // default first
                switch (a.user, b.user) {
                case let (x?, y?) where x != y: return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.alias < b.alias
                }
            }
            let members = sorted.map { r in
                ProfileRef(id: r.alias, alias: r.alias,
                           label: (r.user?.isEmpty == false ? r.user! : r.alias),
                           user: r.user, identityFile: r.identityFile,
                           isDefault: r.isDefault, isConnectable: r.isConnectable)
            }
            let title = rows.first?.groupName ?? members[0].alias
            return HostGroupView(id: key, title: title, members: members)
        }
    }
}
