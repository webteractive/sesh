import Testing
import Foundation
@testable import SSHConfigCore

/// Mirrors the shape of a real double-spaced /etc/hosts: system header,
/// Docker Desktop's block, hand-added dev names, commented production pins,
/// and a SwitchHosts block.
private let realisticHosts = """
##

# Host Database

#

# localhost is used to configure the loopback interface

# when the system is booting.  Do not change this entry.

##

127.0.0.1\tlocalhost

255.255.255.255\tbroadcasthost

::1             localhost

# Added by Docker Desktop

# To allow the same kube context to work on the host and the container:

127.0.0.1 kubernetes.docker.internal

# End of section

127.0.0.1 makerv2.localhost

127.0.0.1 allaboutcircuits.localhost



# 147.182.184.79 diyhacking.com

# 134.122.119.117 reporting.webteractive.co

# 167.99.79.210 webteractive.co

# 142.93.199.41 bundy.webteractive.co

# 159.223.126.122 www.electronics-lab.com

# --- SWITCHHOSTS_CONTENT_START ---

159.89.55.127 eepower.webteractive.co

# --- SWITCHHOSTS_CONTENT_END ---

"""

@Test func renderEnabledAndDisabledLines() {
    #expect(HostsLine(ip: "127.0.0.1", hostnames: ["a.localhost", "b.localhost"]).rendered
        == "127.0.0.1 a.localhost b.localhost")
    #expect(HostsLine(ip: "142.93.199.41", hostnames: ["bundy.webteractive.co"], note: "staging", isEnabled: false).rendered
        == "# 142.93.199.41 bundy.webteractive.co # staging")
}

@Test func appendsBlockWhenAbsent() throws {
    let lines = [HostsLine(ip: "127.0.0.1", hostnames: ["x.localhost"])]
    let result = try HostsFile.replacingBlock(in: "127.0.0.1 localhost", with: lines)
    #expect(result == "127.0.0.1 localhost\n\n" + HostsFile.renderBlock(lines) + "\n")
}

@Test func renderBlockWrapsLinesInMarkers() {
    let lines = [HostsLine(ip: "127.0.0.1", hostnames: ["x.localhost"])]
    #expect(HostsFile.renderBlock(lines)
        == HostsFile.startMarker + "\n127.0.0.1 x.localhost\n" + HostsFile.endMarker)
}

@Test func replacesExistingBlockInPlace() throws {
    let block1 = HostsFile.renderBlock([HostsLine(ip: "10.0.0.1", hostnames: ["old.test"])])
    let lines2 = [HostsLine(ip: "10.0.0.2", hostnames: ["new.test"])]
    let text = "A\n" + block1 + "\nB\n"
    let result = try HostsFile.replacingBlock(in: text, with: lines2)
    #expect(result == "A\n" + HostsFile.renderBlock(lines2) + "\nB\n")
}

@Test func emptyLinesRemoveBlockContents() throws {
    let text = "A\n" + HostsFile.renderBlock([HostsLine(ip: "10.0.0.1", hostnames: ["old.test"])]) + "\n"
    let result = try HostsFile.replacingBlock(in: text, with: [])
    #expect(result == "A\n" + HostsFile.startMarker + "\n" + HostsFile.endMarker + "\n")
}

@Test func startWithoutEndThrows() {
    let text = "A\n" + HostsFile.startMarker + "\n10.0.0.1 x.test\nB\n"
    #expect(throws: HostsFileError.damagedBlock) {
        try HostsFile.replacingBlock(in: text, with: [])
    }
    #expect(throws: HostsFileError.damagedBlock) {
        try HostsFile.managedLines(in: text)
    }
}

@Test func managedLinesRoundTrip() throws {
    let lines = [
        HostsLine(ip: "127.0.0.1", hostnames: ["a.localhost"]),
        HostsLine(ip: "fe80::1", hostnames: ["b.test", "c.test"], note: "lab", isEnabled: false),
    ]
    let text = try HostsFile.replacingBlock(in: "", with: lines)
    #expect(try HostsFile.managedLines(in: text) == lines)
    #expect(try HostsFile.managedLines(in: "127.0.0.1 localhost\n") == nil)
}

@Test func parseLineRejectsProse() {
    #expect(HostsFile.parseLine("# localhost is used to configure the loopback interface") == nil)
    #expect(HostsFile.parseLine("# Host Database") == nil)
    #expect(HostsFile.parseLine("##") == nil)
    #expect(HostsFile.parseLine("") == nil)
    #expect(HostsFile.parseLine("# 147.182.184.79 diyhacking.com")
        == HostsLine(ip: "147.182.184.79", hostnames: ["diyhacking.com"], isEnabled: false))
    #expect(HostsFile.parseLine("::1             localhost")?.ip == "::1")
    #expect(HostsFile.parseLine("127.0.0.1\ta.test b.test # dev")
        == HostsLine(ip: "127.0.0.1", hostnames: ["a.test", "b.test"], note: "dev"))
}

@Test func importCandidatesFromRealisticFile() throws {
    let (lines, remaining) = try HostsFile.importCandidates(in: realisticHosts)
    #expect(lines.count == 7)
    #expect(lines.filter(\.isEnabled).map(\.hostnames) == [["makerv2.localhost"], ["allaboutcircuits.localhost"]])
    #expect(lines.filter { !$0.isEnabled }.count == 5)
    #expect(lines.contains(HostsLine(ip: "142.93.199.41", hostnames: ["bundy.webteractive.co"], isEnabled: false)))

    // Owned blocks and system lines survive; adopted lines are gone.
    #expect(remaining.contains("127.0.0.1 kubernetes.docker.internal"))
    #expect(remaining.contains("159.89.55.127 eepower.webteractive.co"))
    #expect(remaining.contains("127.0.0.1\tlocalhost"))
    #expect(remaining.contains("# localhost is used to configure the loopback interface"))
    #expect(!remaining.contains("makerv2.localhost"))
    #expect(!remaining.contains("diyhacking.com"))
    // No run of blank lines longer than the input already had.
    #expect(!remaining.contains("\n\n\n\n\n"))
}

@Test func removingMovedLinesDoesNotLeaveGaps() throws {
    let text = "A\n\n127.0.0.1 x.test\n\nB\n"
    let (lines, remaining) = try HostsFile.importCandidates(in: text)
    #expect(lines.count == 1)
    #expect(remaining == "A\n\nB\n")
}

@Test func importSkipsLinesInsideSeshBlock() throws {
    let text = try HostsFile.replacingBlock(in: "127.0.0.1 outside.test\n",
                                            with: [HostsLine(ip: "10.0.0.1", hostnames: ["inside.test"])])
    let (lines, remaining) = try HostsFile.importCandidates(in: text)
    #expect(lines == [HostsLine(ip: "127.0.0.1", hostnames: ["outside.test"])])
    #expect(remaining.contains("10.0.0.1 inside.test"))
}

@Test func outsideHostnamesIgnoresDisabledAndBlock() throws {
    let text = try HostsFile.replacingBlock(in: realisticHosts,
                                            with: [HostsLine(ip: "10.0.0.1", hostnames: ["x.test"])])
    let names = try HostsFile.enabledHostnamesOutsideBlock(in: text)
    #expect(names.contains("eepower.webteractive.co"))
    #expect(names.contains("makerv2.localhost"))
    #expect(!names.contains("x.test"))
    #expect(!names.contains("diyhacking.com"))
}

@Test func validateRejectsBadInput() {
    #expect(HostsFile.validate(ip: "999.1.1.1", hostnames: ["a.test"], note: nil) != nil)
    #expect(HostsFile.validate(ip: "127.0.0.1", hostnames: [], note: nil) != nil)
    #expect(HostsFile.validate(ip: "127.0.0.1", hostnames: ["a#b"], note: nil) != nil)
    #expect(HostsFile.validate(ip: "127.0.0.1", hostnames: ["a b"], note: nil) != nil)
    #expect(HostsFile.validate(ip: "127.0.0.1", hostnames: ["a.test"], note: "x\ny") != nil)
    #expect(HostsFile.validate(ip: "fe80::1", hostnames: ["my_dev.localhost"], note: nil) == nil)
}

@Test func enablingDisablesSharedHostnames() {
    let entries: [(id: Int, hostnames: [String], isEnabled: Bool)] = [
        (1, ["a", "b"], true),
        (2, ["b"], true),
        (3, ["c"], true),
        (4, ["B"], false),
    ]
    #expect(HostsFile.idsToDisable(enabling: 4, entries: entries) == [1, 2])
}

// MARK: - Import merge

private let aLive = HostsLine(ip: "1.2.3.4", hostnames: ["a.test"])

@Test func importKeepsLiveOutsideLineLive() {
    let existing = [(id: 1, line: HostsLine(ip: "1.2.3.4", hostnames: ["a.test"], isEnabled: false))]
    let merge = HostsFile.mergeImport(existing: existing, candidates: [aLive])
    #expect(merge.enable == [1])
    #expect(merge.disable.isEmpty)
    #expect(merge.added.isEmpty)
    #expect(merge.skipped == 1)
}

@Test func importedLiveLineDisablesClashingEntry() {
    let existing = [(id: 1, line: HostsLine(ip: "10.0.0.1", hostnames: ["A.test"]))]
    let merge = HostsFile.mergeImport(existing: existing, candidates: [aLive])
    #expect(merge.added == [aLive])
    #expect(merge.disable == [1])
}

@Test func laterClashingCandidateComesInDisabled() {
    let second = HostsLine(ip: "2.2.2.2", hostnames: ["A.test"])
    let merge = HostsFile.mergeImport(existing: [(id: Int, line: HostsLine)](), candidates: [aLive, second, aLive])
    #expect(merge.added == [aLive, HostsLine(ip: "2.2.2.2", hostnames: ["A.test"], isEnabled: false)])
    #expect(merge.skipped == 1)
}

@Test func disabledCandidateLeavesEnabledEntryAlone() {
    let existing = [(id: 1, line: aLive)]
    let merge = HostsFile.mergeImport(existing: existing,
                                      candidates: [HostsLine(ip: "1.2.3.4", hostnames: ["a.test"], isEnabled: false)])
    #expect(merge.enable.isEmpty)
    #expect(merge.disable.isEmpty)
    #expect(merge.added.isEmpty)
    #expect(merge.skipped == 1)
}

// MARK: - Privileged write script

@Test func privilegedScriptEscapesPathsForAppleScript() {
    let script = HostsFile.privilegedWriteScript(stagedPath: "/tmp/a\"b\\c", targetPath: "/private/etc/hosts")
    #expect(script.contains(#"quoted form of "/tmp/a\"b\\c""#))
    #expect(script.contains(#"quoted form of "/private/etc/hosts.sesh-new""#))
    #expect(script.hasSuffix("with administrator privileges"))
}

@Test func privilegedScriptReplacesAtomicallyAfterGuards() {
    let script = HostsFile.privilegedWriteScript(stagedPath: "/tmp/x", targetPath: "/private/etc/hosts")
    #expect(script.contains("[ -f "))
    #expect(script.contains("[ ! -L "))
    #expect(script.contains("[ -s "))
    #expect(script.contains("/usr/bin/install -m 0644 -o root -g wheel "))
    #expect(script.contains("/bin/mv -f "))
    #expect(!script.contains(" > "))   // never truncate the live file in place
}
