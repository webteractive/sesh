import Foundation

// Results the app sends back to the CLI. These are also the shapes
// `sesh … --json` prints, so a field change here is a change to the CLI's
// documented output.

/// One logical host: a lone alias, or a profile group sharing a hostname.
public struct HostInfo: Codable, Sendable, Equatable {
    /// The profile group's name, or the alias of a lone host. Accepted
    /// anywhere a host ref is.
    public var key: String
    public var name: String
    public var hostname: String?
    /// Workspace name; nil is Default.
    public var workspace: String?
    /// Default profile first.
    public var profiles: [ProfileInfo]

    public init(key: String, name: String, hostname: String?, workspace: String?, profiles: [ProfileInfo]) {
        self.key = key
        self.name = name
        self.hostname = hostname
        self.workspace = workspace
        self.profiles = profiles
    }
}

public struct ProfileInfo: Codable, Sendable, Equatable {
    public var alias: String
    public var label: String
    public var user: String?
    public var port: String?
    public var identityFile: String?
    public var isDefault: Bool
    /// False for wildcard or multi-pattern aliases, which can't be opened.
    public var isConnectable: Bool
    public var sshCommand: String
    /// Every option written under this alias in ~/.ssh/sesh.conf.
    public var options: [SSHProperty]

    public init(alias: String, label: String, user: String?, port: String?, identityFile: String?,
                isDefault: Bool, isConnectable: Bool, sshCommand: String, options: [SSHProperty]) {
        self.alias = alias
        self.label = label
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.isDefault = isDefault
        self.isConnectable = isConnectable
        self.sshCommand = sshCommand
        self.options = options
    }
}

public struct WorkspaceInfo: Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    /// 1-based sidebar position.
    public var position: Int
    public var hostCount: Int

    public init(id: UUID, name: String, position: Int, hostCount: Int) {
        self.id = id
        self.name = name
        self.position = position
        self.hostCount = hostCount
    }
}

public struct HostsEntryInfo: Codable, Sendable, Equatable {
    public var id: UUID
    public var ip: String
    public var hostnames: [String]
    public var note: String?
    public var isEnabled: Bool
    /// Enabled, but an earlier line outside Sesh's section maps one of its
    /// hostnames, and that line usually wins.
    public var isOverridden: Bool
    /// 1-based position in Sesh's section.
    public var position: Int

    public init(id: UUID, ip: String, hostnames: [String], note: String?, isEnabled: Bool,
                isOverridden: Bool, position: Int) {
        self.id = id
        self.ip = ip
        self.hostnames = hostnames
        self.note = note
        self.isEnabled = isEnabled
        self.isOverridden = isOverridden
        self.position = position
    }
}

public struct HostsFileStatusInfo: Codable, Sendable, Equatable {
    public var path: String
    /// False when Sesh's section no longer matches its entries; `sesh
    /// hosts-file reapply` rewrites it.
    public var inSync: Bool
    public var entryCount: Int
    public var enabledCount: Int
    public var overridden: [HostsEntryInfo]

    public init(path: String, inSync: Bool, entryCount: Int, enabledCount: Int, overridden: [HostsEntryInfo]) {
        self.path = path
        self.inSync = inSync
        self.entryCount = entryCount
        self.enabledCount = enabledCount
        self.overridden = overridden
    }
}

public struct ConfigStatusInfo: Codable, Sendable, Equatable {
    /// The user's ssh config; nil until one is chosen (Sesh then assumes
    /// ~/.ssh/config).
    public var configPath: String?
    public var managedPath: String
    /// The Include line is in the config and the managed file exists, so
    /// connections use `ssh <alias>`.
    public var isLinked: Bool

    public init(configPath: String?, managedPath: String, isLinked: Bool) {
        self.configPath = configPath
        self.managedPath = managedPath
        self.isLinked = isLinked
    }
}

public struct TerminalInfo: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var isSelected: Bool

    public init(id: String, name: String, isSelected: Bool) {
        self.id = id
        self.name = name
        self.isSelected = isSelected
    }
}

public struct SettingsInfo: Codable, Sendable, Equatable {
    /// The terminal Connect opens, after fallbacks.
    public var terminal: TerminalInfo
    public var terminals: [TerminalInfo]
    /// "system", "light", or "dark".
    public var appearance: String
    public var config: ConfigStatusInfo

    public init(terminal: TerminalInfo, terminals: [TerminalInfo], appearance: String, config: ConfigStatusInfo) {
        self.terminal = terminal
        self.terminals = terminals
        self.appearance = appearance
        self.config = config
    }
}

public struct UpdateInfo: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case upToDate, available, installing, failed
    }

    public var state: State
    public var currentVersion: String
    public var latestVersion: String?
    /// False when the release has no disk image and checksum to install from.
    public var isInstallable: Bool
    public var releasePage: String?
    public var message: String?

    public init(state: State, currentVersion: String, latestVersion: String? = nil, isInstallable: Bool = false,
                releasePage: String? = nil, message: String? = nil) {
        self.state = state
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
        self.isInstallable = isInstallable
        self.releasePage = releasePage
        self.message = message
    }
}

public struct StatusInfo: Codable, Sendable, Equatable {
    public var appVersion: String
    public var appPath: String
    public var protocolVersion: Int
    public var hostCount: Int
    public var profileCount: Int
    public var workspaceCount: Int
    public var config: ConfigStatusInfo
    public var hostsFile: HostsFileStatusInfo
    public var terminal: TerminalInfo
    /// Set once a background check has found a newer release.
    public var availableUpdate: String?

    public init(appVersion: String, appPath: String, protocolVersion: Int, hostCount: Int, profileCount: Int,
                workspaceCount: Int, config: ConfigStatusInfo, hostsFile: HostsFileStatusInfo,
                terminal: TerminalInfo, availableUpdate: String?) {
        self.appVersion = appVersion
        self.appPath = appPath
        self.protocolVersion = protocolVersion
        self.hostCount = hostCount
        self.profileCount = profileCount
        self.workspaceCount = workspaceCount
        self.config = config
        self.hostsFile = hostsFile
        self.terminal = terminal
        self.availableUpdate = availableUpdate
    }
}

/// What happened, for commands with nothing richer to return.
public struct ActionResult: Codable, Sendable, Equatable {
    public var message: String
    /// Items created, where that's meaningful.
    public var added: Int?
    /// Items left alone because Sesh already had them.
    public var skipped: Int?
    public var changed: Int?

    public init(_ message: String, added: Int? = nil, skipped: Int? = nil, changed: Int? = nil) {
        self.message = message
        self.added = added
        self.skipped = skipped
        self.changed = changed
    }
}

public struct TextResult: Codable, Sendable, Equatable {
    public var path: String
    public var text: String

    public init(path: String, text: String) {
        self.path = path
        self.text = text
    }
}

/// The store's export, plus the hosts only ~/.ssh/config has.
public struct ExportInfo: Codable, Sendable, Equatable {
    public var archive: SeshArchive
    /// Group keys of `archive` hosts that come from ~/.ssh/config, not Sesh.
    public var configOnly: [String]

    public init(archive: SeshArchive, configOnly: [String]) {
        self.archive = archive
        self.configOnly = configOnly
    }
}

/// Which items of an export file Sesh already has.
public struct ImportPreview: Codable, Sendable, Equatable {
    /// Group keys whose every alias Sesh already has.
    public var existingHosts: [String]
    /// Indices into `hostsEntries` Sesh already has.
    public var existingHostsEntries: [Int]
    /// Host aliases in the user's ~/.ssh/config, lowercased, for flagging an
    /// import that would replace one (see `SeshArchive.risks`).
    public var configAliases: [String]

    public init(existingHosts: [String], existingHostsEntries: [Int], configAliases: [String]) {
        self.existingHosts = existingHosts
        self.existingHostsEntries = existingHostsEntries
        self.configAliases = configAliases
    }
}
