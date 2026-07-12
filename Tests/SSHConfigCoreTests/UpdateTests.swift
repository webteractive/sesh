import Testing
import Foundation
@testable import SSHConfigCore

@Test func semVerParsesAndCompares() {
    #expect(SemVer("1.2.3") != nil)
    #expect(SemVer("v0.1.0") != nil)
    #expect(SemVer("0.1") != nil)          // missing patch tolerated
    #expect(SemVer("") == nil)
    #expect(SemVer("1.2.3.4") == nil)      // too many parts
    #expect(SemVer("abc") == nil)
    #expect(SemVer("1.0.0")! < SemVer("1.0.1")!)
    #expect(SemVer("0.9.9")! < SemVer("0.10.0")!)
}

@Test func semVerIsNewerOnlyWhenStrictlyGreater() {
    #expect(SemVer.isNewer(latest: "v0.1.1", than: "0.1.0"))
    #expect(!SemVer.isNewer(latest: "0.1.0", than: "0.1.0"))
    #expect(!SemVer.isNewer(latest: "0.0.9", than: "0.1.0"))
    #expect(!SemVer.isNewer(latest: "garbage", than: "0.1.0"))  // unparseable never newer
}

@Test func updateAssetsPicksDmgAndChecksumBySuffix() {
    let assets = [
        ReleaseAsset(name: "Sesh-0.1.1.dmg", downloadURL: URL(string: "https://example.com/Sesh-0.1.1.dmg")!),
        ReleaseAsset(name: "Sesh-0.1.1.dmg.sha256", downloadURL: URL(string: "https://example.com/Sesh-0.1.1.dmg.sha256")!),
        ReleaseAsset(name: "notes.txt", downloadURL: URL(string: "https://example.com/notes.txt")!),
    ]
    let picked = UpdateAssets.select(from: assets)
    #expect(picked.dmg?.lastPathComponent == "Sesh-0.1.1.dmg")
    #expect(picked.checksum?.lastPathComponent == "Sesh-0.1.1.dmg.sha256")
}

@Test func checksumMatchesIsCaseAndWhitespaceTolerant() {
    let data = Data("hello".utf8)
    let hex = UpdateChecksum.sha256Hex(data)
    #expect(UpdateChecksum.matches(data: data, publishedHex: "  \(hex.uppercased())\n"))
    #expect(!UpdateChecksum.matches(data: data, publishedHex: ""))
    #expect(!UpdateChecksum.matches(data: data, publishedHex: "deadbeef"))
}

@Test func selfUpdateScriptWaitsForPidAndQuotesPaths() {
    let script = SelfUpdateScript.render(
        pid: 4242,
        targetAppPath: "/Applications/Sesh.app",
        stagedAppPath: "/tmp/work/Sesh.app",
        workDir: "/tmp/work")
    #expect(script.contains("kill -0 4242"))
    #expect(script.contains("ditto '/tmp/work/Sesh.app' '/Applications/Sesh.app'"))
    #expect(script.contains("xattr -dr com.apple.quarantine '/Applications/Sesh.app'"))
    #expect(script.contains("open '/Applications/Sesh.app'"))
}
