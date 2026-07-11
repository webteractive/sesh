import Foundation

/// Mirrors the Laravel form: 5 core fields + arbitrary extra properties.
public struct HostFormData: Equatable {
    public var host = ""
    public var hostName = ""
    public var user = ""
    public var port = ""
    public var identityFile = ""
    public var extras: [SSHProperty] = []

    public static let coreKeys: Set<String> = ["hostname", "user", "port", "identityfile"]

    /// Laravel's [a-zA-Z0-9._-]+ loosened to allow *, ?, ! and spaces between
    /// patterns so imported wildcard hosts stay editable (see spec).
    public static let hostPatternRegex = #/^[A-Za-z0-9._\-*?!]+( +[A-Za-z0-9._\-*?!]+)*$/#
    // (#/…/# delimiters required: bare /…/ regex literals don't parse in Swift 5 language mode)

    public init() {}

    public init(entry: HostEntry) {
        host = entry.host
        var extraProps = entry.properties.filter { !Self.coreKeys.contains($0.key.lowercased()) }

        // Core fields only surface a single value in the form. When the
        // underlying property carries more (e.g. two IdentityFile lines),
        // stash the remaining values as an extra so they round-trip through
        // properties() instead of being silently dropped on save.
        func consumeCoreValue(_ key: String) -> String {
            guard let prop = entry.properties.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) else {
                return ""
            }
            if prop.values.count > 1 {
                extraProps.append(SSHProperty(key: prop.key, values: Array(prop.values.dropFirst())))
            }
            return prop.values.first ?? ""
        }

        hostName = consumeCoreValue("HostName")
        user = consumeCoreValue("User")
        port = consumeCoreValue("Port")
        identityFile = consumeCoreValue("IdentityFile")
        extras = extraProps
    }

    /// Rebuild the ordered property list: core keys first, extras after.
    public func properties() -> [SSHProperty] {
        var props: [SSHProperty] = []
        props.set("HostName", hostName)
        props.set("User", user)
        props.set("Port", port)
        props.set("IdentityFile", identityFile)
        props.append(contentsOf: extras.filter { !$0.key.isEmpty && !$0.values.allSatisfy(\.isEmpty) })
        return props
    }

    /// nil when valid; otherwise a user-facing message.
    public func validationError(existingHosts: Set<String>) -> String? {
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        if trimmedHost.isEmpty { return "Host is required." }
        if trimmedHost.wholeMatch(of: Self.hostPatternRegex) == nil {
            return "Host may only contain letters, numbers, dots, underscores, hyphens, and the wildcards * ? ! (separate multiple patterns with spaces)."
        }
        if existingHosts.contains(trimmedHost) { return "A host named '\(trimmedHost)' already exists." }
        if !port.isEmpty {
            guard let p = Int(port), (1...65535).contains(p) else {
                return "Port must be between 1 and 65535."
            }
        }
        return nil
    }
}
