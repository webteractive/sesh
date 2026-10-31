import AppKit
import Foundation
import SSHConfigCore

/// Settings' "Install sesh Command": links /usr/local/bin/sesh to the CLI
/// inside this app, behind the standard administrator prompt.
extension AppModel {
    var commandLineHelperPath: String { CommandLineInstall.helperPath(inApp: Bundle.main.bundlePath) }

    var commandLineState: CommandLineInstall.State {
        CommandLineInstall.state(target: commandLineHelperPath)
    }

    /// Returns an error message, or nil when linked (or the prompt was cancelled).
    func installCommandLineTool() -> String? {
        guard FileManager.default.isExecutableFile(atPath: commandLineHelperPath) else {
            return "This copy of Sesh doesn't include the sesh command."
        }
        guard let script = NSAppleScript(source: CommandLineInstall.privilegedLinkScript(target: commandLineHelperPath)) else {
            return "Couldn't prepare the install."
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return nil }
        if (errorInfo[NSAppleScript.errorNumber] as? Int) == -128 { return nil }
        if case .blocked = commandLineState {
            return "\(CommandLineInstall.linkPath) is a file, not a link, so Sesh left it alone. Move it, then try again."
        }
        return "Couldn't install the command: \(errorInfo[NSAppleScript.errorMessage] as? String ?? "unknown error")"
    }
}
