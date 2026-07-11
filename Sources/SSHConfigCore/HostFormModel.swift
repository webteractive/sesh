import Foundation

public struct CredentialRow: Equatable, Sendable {
    public var user: String
    public var port: String
    public var identityFile: String
    public var extras: [SSHProperty]
    public init(user: String, port: String = "", identityFile: String = "", extras: [SSHProperty] = []) {
        self.user = user; self.port = port; self.identityFile = identityFile; self.extras = extras
    }
    /// Core + preserved-extra properties for this row (HostName supplied by the form).
    func properties(hostName: String) -> [SSHProperty] {
        var p: [SSHProperty] = []
        p.set("HostName", hostName)
        p.set("User", user)
        p.set("Port", port)
        p.set("IdentityFile", identityFile)
        p.append(contentsOf: extras.filter { !$0.key.isEmpty })
        return p
    }
}

public struct HostFormModel: Equatable, Sendable {
    public var displayName: String
    public var hostName: String
    public var rows: [CredentialRow]
    public init(displayName: String, hostName: String, rows: [CredentialRow]) {
        self.displayName = displayName; self.hostName = hostName; self.rows = rows
    }

    public func validationError() -> String? {
        let name = displayName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "Name is required." }
        // Must yield a real alias: at least one ASCII letter or digit.
        if !name.contains(where: { $0.isASCII && ($0.isLetter || $0.isNumber) }) {
            return "Name must contain letters or numbers."
        }
        if hostName.trimmingCharacters(in: .whitespaces).isEmpty { return "Host (ip or domain) is required." }
        if rows.isEmpty { return "At least one user is required." }
        if rows.contains(where: { $0.user.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return "Every credential row needs a user."
        }
        return nil
    }
}

public struct HostFormPlan: Equatable, Sendable {
    public struct Upsert: Equatable, Sendable {
        public let alias: String
        public let properties: [SSHProperty]
        public let isDefault: Bool
        public let groupName: String?
        public init(alias: String, properties: [SSHProperty], isDefault: Bool, groupName: String?) {
            self.alias = alias; self.properties = properties; self.isDefault = isDefault; self.groupName = groupName
        }
    }
    public let upserts: [Upsert]
    public let deleteAliases: [String]
}

public enum HostFormReconciler {
    public static func plan(_ form: HostFormModel,
                            existing: [(alias: String, user: String?)],
                            allAliases: Set<String>) -> HostFormPlan {
        let host = form.hostName.trimmingCharacters(in: .whitespaces)
        let base = uniqueAlias(ProfileFactory.sanitizedAlias(form.displayName.trimmingCharacters(in: .whitespaces)),
                               taken: allAliases, existingForThisGroup: Set(existing.map(\.alias)))
        let multi = form.rows.count > 1
        let groupName: String? = multi ? base : nil

        var taken = allAliases
        var usedExisting = Set<String>()
        var upserts: [HostFormPlan.Upsert] = []

        for (i, r) in form.rows.enumerated() {
            let user = r.user.trimmingCharacters(in: .whitespaces)
            let alias: String
            if i == 0 {
                alias = base
            } else if let match = existing.first(where: { $0.user == user && !usedExisting.contains($0.alias) }) {
                alias = match.alias                      // stability: unchanged user keeps its alias
            } else {
                alias = uniqueAlias("\(base)-\(ProfileFactory.sanitizedAlias(user))",
                                    taken: taken, existingForThisGroup: [])
            }
            usedExisting.insert(alias)
            taken.insert(alias)
            upserts.append(.init(alias: alias,
                                 properties: r.properties(hostName: host),
                                 isDefault: i == 0,
                                 groupName: groupName))
        }
        let keep = Set(upserts.map(\.alias))
        let deletes = existing.map(\.alias).filter { !keep.contains($0) }
        return HostFormPlan(upserts: upserts, deleteAliases: deletes)
    }

    /// Prefer `candidate`; if taken by an alias NOT belonging to this group,
    /// suffix -2, -3… (an alias already in this group is fine to reuse).
    private static func uniqueAlias(_ candidate: String, taken: Set<String>,
                                    existingForThisGroup: Set<String>) -> String {
        if !taken.contains(candidate) || existingForThisGroup.contains(candidate) { return candidate }
        var n = 2
        while taken.contains("\(candidate)-\(n)") { n += 1 }
        return "\(candidate)-\(n)"
    }
}
