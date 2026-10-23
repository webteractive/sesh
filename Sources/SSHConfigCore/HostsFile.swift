import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One /etc/hosts mapping as Sesh renders it. A disabled entry is the same
/// line commented out — how people toggle hosts entries by hand.
public struct HostsLine: Equatable, Sendable {
    public var ip: String
    public var hostnames: [String]
    public var note: String?
    public var isEnabled: Bool

    public init(ip: String, hostnames: [String], note: String? = nil, isEnabled: Bool = true) {
        self.ip = ip
        self.hostnames = hostnames
        self.note = note
        self.isEnabled = isEnabled
    }

    public var rendered: String {
        var line = (isEnabled ? "" : "# ") + ip + " " + hostnames.joined(separator: " ")
        if let note, !note.isEmpty { line += " # " + note }
        return line
    }
}

/// What `HostsFile.mergeImport` decided: entries to switch on or off, new
/// lines to add, and how many candidates were already known.
public struct HostsImportMerge<ID: Hashable> {
    public var enable: Set<ID> = []
    public var disable: Set<ID> = []
    public var added: [HostsLine] = []
    public var skipped = 0

    public init() {}
}

public enum HostsFileError: Error, Equatable {
    /// A Sesh start marker without its end marker (or the reverse). Writing
    /// would mean guessing where Sesh's section stops, so nothing is written.
    case damagedBlock
    case notUTF8
}

/// Pure text operations on /etc/hosts. Sesh owns one fenced block and never
/// edits outside it — except `importCandidates`, which moves adopted lines
/// into the block.
public enum HostsFile {
    public static let startMarker = "# --- SESH START (managed by Sesh, edits here are overwritten) ---"
    public static let endMarker = "# --- SESH END ---"

    /// Blocks other tools own and rewrite; their lines are never imported.
    private static let foreignBlocks: [(start: String, end: String)] = [
        ("# Added by Docker Desktop", "# End of section"),
        ("# --- SWITCHHOSTS_CONTENT_START ---", "# --- SWITCHHOSTS_CONTENT_END ---"),
    ]

    /// System names macOS needs; never adopted by import.
    private static let systemHostnames: Set<String> = ["localhost", "broadcasthost"]

    public static func renderBlock(_ lines: [HostsLine]) -> String {
        ([startMarker] + lines.map(\.rendered) + [endMarker]).joined(separator: "\n")
    }

    /// Replaces Sesh's block in place, or appends one (after a blank line)
    /// when the file has none. Everything outside the block is untouched.
    public static func replacingBlock(in text: String, with lines: [HostsLine]) throws -> String {
        var all = splitLines(text)
        let block = renderBlock(lines)
        if let range = try blockRange(in: all) {
            all.replaceSubrange(range, with: [block])
            return all.joined(separator: "\n")
        }
        guard !text.isEmpty else { return block + "\n" }
        var result = text
        if !result.hasSuffix("\n") { result += "\n" }
        if !result.hasSuffix("\n\n") { result += "\n" }
        return result + block + "\n"
    }

    /// The entries currently written in Sesh's block, or nil when there is no
    /// block. Unparseable lines inside the block are skipped.
    public static func managedLines(in text: String) throws -> [HostsLine]? {
        let all = splitLines(text)
        guard let range = try blockRange(in: all) else { return nil }
        return all[range].dropFirst().dropLast().compactMap(parseLine)
    }

    /// Parses `IP host…[ # note]`, or the commented-out (disabled) form
    /// `# IP host…`. Prose comments return nil: the first token must be an IP.
    public static func parseLine(_ raw: String) -> HostsLine? {
        var body = raw.trimmingCharacters(in: .whitespaces)
        var enabled = true
        if body.hasPrefix("#") {
            enabled = false
            body = String(body.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        var note: String?
        if let hash = body.firstIndex(of: "#") {
            let text = body[body.index(after: hash)...].trimmingCharacters(in: .whitespaces)
            note = text.isEmpty ? nil : text
            body = String(body[..<hash])
        }
        let tokens = body.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard tokens.count >= 2, isValidIP(tokens[0]),
              tokens.dropFirst().allSatisfy(isValidHostname) else { return nil }
        return HostsLine(ip: tokens[0], hostnames: Array(tokens.dropFirst()), note: note, isEnabled: enabled)
    }

    /// Lines import would adopt — enabled and commented-out mappings outside
    /// Sesh's block, other tools' blocks, and the system entries — plus the
    /// file text with those lines removed. When a removed line sat between
    /// two blank lines, one of the blanks goes with it so double-spaced files
    /// don't grow gaps.
    public static func importCandidates(in text: String) throws -> (lines: [HostsLine], remaining: String) {
        let all = splitLines(text)
        var excluded = IndexSet()
        if let range = try blockRange(in: all) { excluded.insert(integersIn: range) }
        for (start, end) in foreignBlocks {
            var i = 0
            while i < all.count {
                if trimmed(all[i]) == start {
                    let close = all[(i + 1)...].firstIndex { trimmed($0) == end } ?? all.count - 1
                    excluded.insert(integersIn: i...close)
                    i = close
                }
                i += 1
            }
        }

        var adopted: [HostsLine] = []
        var output: [String] = []
        var i = 0
        while i < all.count {
            if !excluded.contains(i), let line = parseLine(all[i]),
               !line.hostnames.contains(where: { systemHostnames.contains($0.lowercased()) }) {
                adopted.append(line)
                let prevBlank = output.last.map { trimmed($0).isEmpty } ?? false
                // The last element is what follows the file's final newline, so
                // it never counts as the blank after a removed line.
                let nextBlank = i + 2 < all.count && trimmed(all[i + 1]).isEmpty
                i += (prevBlank && nextBlank) ? 2 : 1
                continue
            }
            output.append(all[i])
            i += 1
        }
        return (adopted, output.joined(separator: "\n"))
    }

    /// Lowercased hostnames enabled by lines outside Sesh's block — those
    /// usually win over Sesh's appended block, so a Sesh entry sharing one
    /// may be overridden.
    public static func enabledHostnamesOutsideBlock(in text: String) throws -> Set<String> {
        let all = splitLines(text)
        let range = try blockRange(in: all)
        var names = Set<String>()
        for (index, raw) in all.enumerated() where !(range?.contains(index) ?? false) {
            guard let line = parseLine(raw), line.isEnabled else { continue }
            names.formUnion(line.hostnames.map { $0.lowercased() })
        }
        return names
    }

    /// Returns an error message, or nil when the entry can be written safely.
    public static func validate(ip: String, hostnames: [String], note: String?) -> String? {
        if !isValidIP(ip) { return "'\(ip)' isn't a valid IPv4 or IPv6 address." }
        if hostnames.isEmpty { return "At least one hostname is required." }
        if let bad = hostnames.first(where: { !isValidHostname($0) }) {
            return "'\(bad)' isn't a valid hostname."
        }
        if let note, note.contains(where: \.isNewline) { return "The note must be a single line." }
        return nil
    }

    /// Entries to disable when `id` is enabled: every other enabled entry
    /// sharing any hostname with it (case-insensitive), so at most one enabled
    /// entry maps each name.
    public static func idsToDisable<ID: Hashable>(
        enabling id: ID, entries: [(id: ID, hostnames: [String], isEnabled: Bool)]
    ) -> Set<ID> {
        guard let target = entries.first(where: { $0.id == id }) else { return [] }
        let names = Set(target.hostnames.map { $0.lowercased() })
        return Set(entries
            .filter { $0.id != id && $0.isEnabled && !names.isDisjoint(with: $0.hostnames.map { $0.lowercased() }) }
            .map(\.id))
    }

    /// Folds lines found in the file (`candidates`, in file order) into the
    /// store's entries without changing what any hostname resolves to: the
    /// first enabled line for a name stays live, as the resolver would pick
    /// it, and anything else enabled for that name is turned off. Candidates
    /// that match an existing entry (same IP and hostnames) only adjust its
    /// enabled state; new ones are returned in `added`.
    public static func mergeImport<ID: Hashable>(
        existing: [(id: ID, line: HostsLine)], candidates: [HostsLine]
    ) -> HostsImportMerge<ID> {
        var merge = HostsImportMerge<ID>()
        var claimed = Set<String>()          // names an enabled candidate already resolves
        var claimers = Set<ID>()              // existing entries now holding a claimed name
        var seen = Set<String>()
        let byKey = Dictionary(existing.map { (importKey($0.line), $0) }, uniquingKeysWith: { first, _ in first })

        for candidate in candidates {
            let key = importKey(candidate)
            let names = Set(candidate.hostnames.map { $0.lowercased() })
            let live = candidate.isEnabled && claimed.isDisjoint(with: names)
            if live { claimed.formUnion(names) }
            if let match = byKey[key] {
                merge.skipped += 1
                if live {
                    claimers.insert(match.id)
                    if !match.line.isEnabled { merge.enable.insert(match.id) }
                }
            } else if !seen.insert(key).inserted {
                merge.skipped += 1
            } else {
                var line = candidate
                line.isEnabled = live
                merge.added.append(line)
            }
        }
        for entry in existing where entry.line.isEnabled && !claimers.contains(entry.id)
            && !claimed.isDisjoint(with: entry.line.hostnames.map { $0.lowercased() }) {
            merge.disable.insert(entry.id)
        }
        return merge
    }

    /// AppleScript that replaces `targetPath` with the staged file as root.
    /// Only fixed text and the two paths (as AppleScript string literals run
    /// through `quoted form of`) appear, so no entry text reaches the shell.
    /// The staged file must be a regular, non-empty, non-symlink file; it is
    /// installed beside the target as root:wheel 0644 and renamed over it, so
    /// the live file is replaced in one step and never left truncated. DNS
    /// flush failures don't fail the script — the file has already landed.
    public static func privilegedWriteScript(stagedPath: String, targetPath: String) -> String {
        func literal(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return """
        set p to quoted form of \(literal(stagedPath))
        set n to quoted form of \(literal(targetPath + ".sesh-new"))
        set t to quoted form of \(literal(targetPath))
        do shell script "[ -f " & p & " ] && [ ! -L " & p & " ] && [ -s " & p & " ] && \
        /usr/bin/install -m 0644 -o root -g wheel " & p & " " & n & " && /bin/mv -f " & n & " " & t & \
        " && (/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder; true)" \
        with administrator privileges
        """
    }

    public static func isValidIP(_ s: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1
    }

    public static func isValidHostname(_ s: String) -> Bool {
        s.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
    }

    // MARK: - Helpers

    private static func splitLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    private static func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces)
    }

    /// Identity `mergeImport` matches on: the IP plus lowercased hostnames.
    private static func importKey(_ line: HostsLine) -> String {
        line.ip + " " + line.hostnames.map { $0.lowercased() }.joined(separator: " ")
    }

    /// Index range of Sesh's block (markers included), nil when absent.
    private static func blockRange(in lines: [String]) throws -> ClosedRange<Int>? {
        let start = lines.firstIndex { trimmed($0) == startMarker }
        let end = lines.firstIndex { trimmed($0) == endMarker }
        switch (start, end) {
        case (nil, nil): return nil
        case let (s?, e?) where s < e: return s...e
        default: throw HostsFileError.damagedBlock
        }
    }
}
