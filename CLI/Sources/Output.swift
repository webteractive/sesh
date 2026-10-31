import ArgumentParser
import Darwin
import Foundation
import SSHConfigCore

enum CLIError: Error {
    /// The app refused or couldn't do the request.
    case app(ControlFailure)
    case unreachable(String)
    case unsupported(String)
    case invalid(String)
    case notFound(String)
    case failed(String)
    case confirmationRequired(String)
    case declined

    var code: String {
        switch self {
        case .app(let failure): failure.code.rawValue
        case .unreachable: "unreachable"
        case .unsupported: "unsupported"
        case .invalid: "invalid"
        case .notFound: "notFound"
        case .failed: "failed"
        case .confirmationRequired: "confirmationRequired"
        case .declined: "cancelled"
        }
    }

    var message: String {
        switch self {
        case .app(let failure): failure.message
        case .unreachable(let m), .unsupported(let m), .invalid(let m), .notFound(let m), .failed(let m),
             .confirmationRequired(let m): m
        case .declined: "Nothing was changed."
        }
    }

    /// Documented in the root command's help; scripts branch on these.
    var exitCode: Int32 {
        switch code {
        case "invalid": 2
        case "notFound": 3
        case "ambiguous": 4
        case "conflict": 5
        case "cancelled": 6
        case "unreachable": 7
        case "unsupported": 8
        case "confirmationRequired": 9
        default: 1
        }
    }
}

/// `--json`, shared by every command that prints a result.
struct OutputOptions: ParsableArguments {
    @Flag(help: "Print JSON for scripts and agents instead of text. Errors become {\"error\": {\"code\", \"message\"}} on stdout.")
    var json = false

    /// Runs `body` and prints its result as JSON or as `human` text. Errors
    /// print to stderr (or as JSON) and exit with their documented code.
    func emit<T: Encodable>(_ body: () throws -> T, human: (T) -> String) throws {
        do {
            let value = try body()
            if json {
                print(Self.encode(value))
            } else {
                let text = human(value)
                if !text.isEmpty { print(text) }
            }
        } catch let error as CLIError {
            throw fail(error)
        } catch let error as ExitCode {
            throw error
        } catch {
            throw fail(.failed(error.localizedDescription))
        }
    }

    func fail(_ error: CLIError) -> ExitCode {
        if json {
            print(Self.encode(["error": ["code": error.code, "message": error.message]]))
        } else {
            FileHandle.standardError.write(Data("error: \(error.message)\n".utf8))
        }
        return ExitCode(error.exitCode)
    }

    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = ControlProtocol.encoder()
        encoder.outputFormatting.insert(.prettyPrinted)
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

/// Asks before something that can't be undone. Without a terminal to ask
/// on, `--yes` is required.
enum Confirm {
    static func check(_ question: String, yes: Bool) throws {
        if yes { return }
        guard isatty(STDIN_FILENO) != 0 else {
            throw CLIError.confirmationRequired("\(question) Pass --yes to confirm without a prompt.")
        }
        FileHandle.standardError.write(Data("\(question) [y/N] ".utf8))
        guard let answer = readLine()?.lowercased(), answer == "y" || answer == "yes" else {
            throw CLIError.declined
        }
    }
}

/// Aligned columns for human output.
enum Table {
    static func render(_ header: [String], _ rows: [[String]]) -> String {
        let all = [header] + rows
        let widths = header.indices.map { column in all.map { $0[column].count }.max() ?? 0 }
        return all.map { row in
            row.enumerated().map { index, cell in
                index == row.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }.joined(separator: "  ").trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }
}

/// "key: value" lines with the keys lined up.
enum Fields {
    static func render(_ fields: [(String, String?)]) -> String {
        let shown = fields.compactMap { key, value in value.map { (key, $0) } }
        let width = shown.map(\.0.count).max() ?? 0
        return shown.map { "\(($0.0 + ":").padding(toLength: width + 1, withPad: " ", startingAt: 0)) \($0.1)" }
            .joined(separator: "\n")
    }
}

/// Closing line for list output, pointing scripts at the JSON form.
func jsonHint(_ command: String) -> String {
    "\n\nFor scripts and agents: \(command) --json"
}

func plural(_ count: Int, _ singular: String, _ pluralForm: String? = nil) -> String {
    "\(count) \(count == 1 ? singular : pluralForm ?? singular + "s")"
}
