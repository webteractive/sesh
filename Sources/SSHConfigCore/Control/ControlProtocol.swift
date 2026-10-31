import Foundation

/// The wire protocol between the `sesh` command-line tool and the running
/// app. The CLI connects to a Unix socket only the user can open, writes one
/// JSON `ControlRequest`, half-closes, and reads one JSON response back. The
/// app does the work with the same model code its windows use, so the store
/// has one writer and every change shows up in the UI straight away.
public enum ControlProtocol {
    /// Bumped when a request or response changes shape incompatibly.
    public static let version = 1

    /// `~/Library/Application Support/Sesh/control.sock`.
    public static var socketPath: String {
        URL.applicationSupportDirectory.appending(path: "Sesh/control.sock").path
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public struct ControlRequest: Codable, Sendable {
    public var version: Int
    public var command: ControlCommand

    public init(_ command: ControlCommand) {
        self.version = ControlProtocol.version
        self.command = command
    }
}

/// Everything the app can be asked to do. Hosts are named by alias, profile
/// group, or display name; workspaces by name or id; hosts-file entries by
/// id, id prefix, or hostname (see `ControlRefs`).
public enum ControlCommand: Codable, Sendable, Equatable {
    case status

    // SSH hosts
    case listHosts
    case showHost(ref: String)
    case addHost(HostSpec)
    case editHost(ref: String, changes: HostChanges)
    case duplicateHost(ref: String)
    case deleteHosts(refs: [String])
    /// nil workspace moves to Default.
    case moveHosts(refs: [String], workspace: String?)
    case connect(alias: String, terminal: String?)

    // Profiles
    case addProfile(host: String, label: String, user: String, identityFile: String?)
    case editProfile(alias: String, changes: ProfileChanges)
    case removeProfile(alias: String)
    case ungroup(host: String)

    // Workspaces
    case listWorkspaces
    case createWorkspace(name: String)
    case renameWorkspace(ref: String, name: String)
    case deleteWorkspace(ref: String)
    case moveWorkspace(ref: String, placement: WorkspacePlacement)

    // /etc/hosts
    case listHostsEntries
    case showHostsEntry(ref: String)
    case addHostsEntry(ip: String, hostnames: [String], note: String?, enabled: Bool)
    case addHostsText(text: String)
    case editHostsEntry(ref: String, changes: HostsEntryChanges)
    case setHostsEntries(refs: [String], enabled: Bool)
    case duplicateHostsEntry(ref: String)
    case deleteHostsEntries(refs: [String])
    case reapplyHostsFile
    case hostsFileStatus
    case importHostsFile
    case readHostsFile

    // Export and import
    case exportArchive(includeConfigOnly: Bool)
    case previewImport(SeshArchive)
    case importArchive(SeshArchive)

    // ~/.ssh/config
    case configStatus
    case importConfig
    case linkInclude
    case setConfigPath(String)
    case setManagedPath(String)
    case readConfig
    case readManagedFile

    // Settings
    case showSettings
    case setTerminal(String)
    case setAppearance(String)
    case resetSettings

    // Updates
    case checkForUpdates
    case installUpdate
}

/// A new host: one profile. More are added with `addProfile`.
public struct HostSpec: Codable, Sendable, Equatable {
    public var name: String
    public var hostname: String
    public var user: String
    public var port: String?
    public var identityFile: String?
    public var options: [SSHProperty]
    public var workspace: String?

    public init(name: String, hostname: String, user: String, port: String? = nil, identityFile: String? = nil,
                options: [SSHProperty] = [], workspace: String? = nil) {
        self.name = name
        self.hostname = hostname
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.options = options
        self.workspace = workspace
    }
}

/// Changes to one profile's connection settings. nil leaves a field alone;
/// an empty string clears it (user can't be cleared).
public struct ProfileChanges: Codable, Sendable, Equatable {
    public var user: String?
    public var port: String?
    public var identityFile: String?
    /// Options to set, replacing any existing values for the same key.
    public var setOptions: [SSHProperty]
    /// Option keys to remove (case-insensitive).
    public var removeOptions: [String]

    public init(user: String? = nil, port: String? = nil, identityFile: String? = nil,
                setOptions: [SSHProperty] = [], removeOptions: [String] = []) {
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.setOptions = setOptions
        self.removeOptions = removeOptions
    }

    public var isEmpty: Bool {
        user == nil && port == nil && identityFile == nil && setOptions.isEmpty && removeOptions.isEmpty
    }
}

/// Changes to a whole host. `profile` applies to its default profile.
public struct HostChanges: Codable, Sendable, Equatable {
    public var name: String?
    public var hostname: String?
    /// Moves the host when set: a workspace name, or "" for Default.
    public var workspace: String?
    public var profile: ProfileChanges

    public init(name: String? = nil, hostname: String? = nil, workspace: String? = nil,
                profile: ProfileChanges = ProfileChanges()) {
        self.name = name
        self.hostname = hostname
        self.workspace = workspace
        self.profile = profile
    }

    public var isEmpty: Bool { name == nil && hostname == nil && workspace == nil && profile.isEmpty }
}

public struct HostsEntryChanges: Codable, Sendable, Equatable {
    public var ip: String?
    public var hostnames: [String]?
    /// "" clears the note.
    public var note: String?

    public init(ip: String? = nil, hostnames: [String]? = nil, note: String? = nil) {
        self.ip = ip
        self.hostnames = hostnames
        self.note = note
    }

    public var isEmpty: Bool { ip == nil && hostnames == nil && note == nil }
}

public enum WorkspacePlacement: Codable, Sendable, Equatable {
    case up
    case down
    /// Takes the slot of the workspace named by the ref.
    case onto(String)
}

/// One response per request: `result` on success, `error` otherwise.
public struct ControlResponse<Result> {
    public var result: Result?
    public var error: ControlFailure?
    /// Problems beside a result, e.g. a change was saved but ~/.ssh/sesh.conf
    /// couldn't be written. Absent when there are none.
    public var warnings: [String]?

    public init(result: Result, warnings: [String] = []) {
        self.result = result; self.error = nil; self.warnings = warnings.isEmpty ? nil : warnings
    }
    public init(error: ControlFailure) { self.result = nil; self.error = error; self.warnings = nil }
}

extension ControlResponse: Encodable where Result: Encodable {}
extension ControlResponse: Decodable where Result: Decodable {}

/// Only the protocol version of a request, read first so a CLI from another
/// release gets a clear answer instead of a decoding error.
public struct ControlVersionProbe: Decodable {
    public var version: Int
}

/// A request the app refused or couldn't complete.
public struct ControlFailure: Error, Codable, Sendable, Equatable {
    public enum Code: String, Codable, Sendable {
        /// Something went wrong doing the work.
        case failed
        /// No host, profile, workspace, or entry matches the ref.
        case notFound
        /// The ref matches more than one thing.
        case ambiguous
        /// The name, alias, or mapping is already taken.
        case conflict
        /// The input was rejected before anything changed.
        case invalid
        /// The administrator password prompt was dismissed; nothing changed.
        case cancelled
        /// The app and CLI speak different protocol versions.
        case unsupported
    }

    public var code: Code
    public var message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }
}
