import Foundation

public extension HostFormModel {
    /// The form for editing `entry`'s whole group: the display name (falling
    /// back to the alias), `HostName` from the default member, and one
    /// `CredentialRow` per member, default first (user/port/identityFile plus
    /// any other properties preserved as extras). A lone host yields one row.
    init(editing entry: HostEntry, allHosts: [HostEntry]) {
        // The group's name comes from its default profile: a profile added
        // later has no display name, and its alias would rename the host.
        let members = HostFormModel.members(of: entry, allHosts: allHosts)
        self.init(editing: members, displayName: members[0].displayName ?? members[0].host)
    }

    /// `entry`'s group members, default first, then by alias — the order
    /// `init(editing:allHosts:)` lays out its rows in.
    static func members(of entry: HostEntry, allHosts: [HostEntry]) -> [HostEntry] {
        let members = entry.groupName.map { group in allHosts.filter { $0.groupName == group } } ?? [entry]
        let ordered = members.isEmpty ? [entry] : members
        let defaultMember = ordered.first { $0.isDefaultProfile } ?? ordered[0]
        let rest = ordered.filter { $0 !== defaultMember }.sorted { $0.host < $1.host }
        return [defaultMember] + rest
    }

    private init(editing members: [HostEntry], displayName: String) {
        self.init(displayName: displayName,
                  hostName: members[0].properties.first("HostName") ?? "",
                  rows: members.map { CredentialRow(fromProperties: $0.properties) },
                  workspaceID: members[0].workspaceID)
    }
}
