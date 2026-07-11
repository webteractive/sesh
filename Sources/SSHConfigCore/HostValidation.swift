import Foundation

/// Guards the launch path: only a strict alias charset may ever reach `ssh`
/// or a terminal app's argv. Hosts arrive here from three sources — manual
/// entry, file import, and file sync — and only the manual form validates on
/// the way in (see HostFormData's looser, wildcard-friendly pattern). A
/// crafted `~/.ssh/config` line (e.g. `Host evil;touch$(id)`) can otherwise
/// reach `launch()` unvalidated, so this check is the last line of defense
/// against shell/ssh-option injection regardless of where the host came from.
///
/// Note: this is deliberately stricter than HostFormData's pattern. Valid
/// launch targets are plain Host aliases — no `user@host`, no `:port`, no
/// wildcards — since the app only ever connects via the alias itself.
public enum HostValidation {
    public static func isSafeToLaunch(_ host: String) -> Bool {
        host.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
    }
}
