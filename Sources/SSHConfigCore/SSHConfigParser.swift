import Foundation

public enum ParserError: LocalizedError, Equatable {
    case unreadableFile(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableFile(let path):
            return "Could not read the config file at \(path)."
        }
    }
}

public struct SSHConfigParser {
    public init() {}

    /// Splits "keyword args" honoring the optional single '=' separator.
    /// Returns nil for blank/comment lines.
    static func directive(from line: String) -> (keyword: String, args: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        var keyword = ""
        var idx = trimmed.startIndex
        while idx < trimmed.endIndex, !trimmed[idx].isWhitespace, trimmed[idx] != "=" {
            keyword.append(trimmed[idx])
            idx = trimmed.index(after: idx)
        }
        var rest = trimmed[idx...].drop(while: { $0.isWhitespace })
        if rest.first == "=" {
            rest = rest.dropFirst().drop(while: { $0.isWhitespace })
        }
        guard !keyword.isEmpty else { return nil }
        return (keyword, String(rest))
    }

    public func parse(_ text: String) -> [Segment] {
        guard !text.isEmpty else { return [] }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var segments: [Segment] = []

        enum State {
            case prologue(lines: [String])
            case host(pattern: String, props: [SSHProperty], raw: [String])
            case match(raw: [String])
        }
        var state: State = .prologue(lines: [])

        // Closes the current block. Trailing non-directive lines are split off
        // into a .comment segment so they survive host-block re-rendering.
        func flush() {
            switch state {
            case .prologue(let ls):
                let text = ls.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { segments.append(.prologue(text)) }
            case .host(let pattern, let props, var raw):
                var trailing: [String] = []
                while let last = raw.last, Self.directive(from: last) == nil {
                    trailing.insert(last, at: 0)
                    raw.removeLast()
                }
                segments.append(.hostBlock(ParsedHost(
                    pattern: pattern,
                    properties: props,
                    rawBlock: raw.joined(separator: "\n")
                )))
                let trailingText = trailing.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !trailingText.isEmpty { segments.append(.comment(trailingText)) }
            case .match(var raw):
                var trailing: [String] = []
                while let last = raw.last, Self.directive(from: last) == nil {
                    trailing.insert(last, at: 0)
                    raw.removeLast()
                }
                segments.append(.matchBlock(raw.joined(separator: "\n")))
                let trailingText = trailing.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !trailingText.isEmpty { segments.append(.comment(trailingText)) }
            }
        }

        for line in lines {
            let dir = Self.directive(from: line)
            let keyword = dir?.keyword.lowercased()

            switch keyword {
            case "host":
                guard let dir else { break }
                flush()
                state = .host(pattern: dir.args, props: [], raw: [line])
            case "match":
                flush()
                state = .match(raw: [line])
            case "include":
                // Top-level Include is its own segment; inside a block it belongs to the block.
                switch state {
                case .prologue:
                    flush()
                    segments.append(.include(line.trimmingCharacters(in: .whitespaces)))
                    state = .prologue(lines: [])
                case .host(let pattern, var props, var raw):
                    guard let dir else { break }
                    appendProperty(&props, keyword: dir.keyword, value: dir.args)
                    raw.append(line)
                    state = .host(pattern: pattern, props: props, raw: raw)
                case .match(var raw):
                    raw.append(line)
                    state = .match(raw: raw)
                }
            default:
                switch state {
                case .prologue(var ls):
                    ls.append(line)
                    state = .prologue(lines: ls)
                case .host(let pattern, var props, var raw):
                    if let dir { appendProperty(&props, keyword: dir.keyword, value: dir.args) }
                    raw.append(line)
                    state = .host(pattern: pattern, props: props, raw: raw)
                case .match(var raw):
                    raw.append(line)
                    state = .match(raw: raw)
                }
            }
        }
        flush()
        return segments
    }

    private func appendProperty(_ props: inout [SSHProperty], keyword: String, value: String) {
        guard !value.isEmpty else { return }
        if let i = props.firstIndex(where: { $0.key.caseInsensitiveCompare(keyword) == .orderedSame }) {
            props[i].values.append(value)
        } else {
            props.append(SSHProperty(key: keyword, values: [value]))
        }
    }

    /// Reads and parses the config at `path`. Missing files parse as `[]` (there's
    /// nothing to lose). Existing files that can't be decoded as UTF-8 fall back to
    /// `.isoLatin1` (which decodes any byte sequence), so legitimately-encoded old
    /// configs still parse instead of being treated as empty. Only an outright read
    /// failure (e.g. permissions) throws — callers must not swallow this, since
    /// treating an unreadable file as `[]` would let SyncEngine.syncToFile rewrite
    /// it with only store hosts, destroying Match/Include/global lines.
    public func parseFile(at path: String) throws -> [Segment] {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: expanded))
        } catch {
            throw ParserError.unreadableFile(expanded)
        }
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw ParserError.unreadableFile(expanded)
        }
        return parse(text)
    }

    public func hosts(in segments: [Segment]) -> [ParsedHost] {
        segments.compactMap { if case .hostBlock(let h) = $0 { return h } else { return nil } }
    }
}
