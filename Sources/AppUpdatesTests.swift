import AppKit

@MainActor enum AppUpdatesTests {
    static func run(directory: URL) async throws {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        try verify(try SpyVersion("1.12.0") > SpyVersion("1.11.9"), "Semantic versions compare numerically")
        try verify(try SpyVersion("v1.12.0") == SpyVersion("1.12"), "Version prefix and missing patch normalize")
        for text in ["../bad", "1", "1.2-beta", "1..3", "-1.2", "99999999999999999999999.0"] {
            do { _ = try SpyVersion(text); throw SpyError.message("TEST FAILED: invalid version accepted") }
            catch { try verify(!(error.localizedDescription.hasPrefix("TEST FAILED")), "Invalid version is rejected") }
        }
        let asset = SpyUpdateRelease.Asset(name: "Spy-99.0.0-macOS-arm64.zip", size: 100,
            digest: "sha256:" + String(repeating: "a", count: 64), browser_download_url: URL(string: "https://github.com/Pechivoa/Spy/releases/download/v99.0.0/Spy-99.0.0-macOS-arm64.zip")!)
        let release = SpyUpdateRelease(tag_name: "v99.0.0", html_url: URL(string: "https://github.com/Pechivoa/Spy/releases/tag/v99.0.0")!, draft: false, prerelease: false, assets: [asset])
        try verify(try release.archive().name == asset.name, "Release validates exact repository, tag, archive and SHA256")
        let wrong = SpyUpdateRelease(tag_name: "v99.0.0", html_url: URL(string: "https://evil.example/release")!, draft: false, prerelease: false, assets: [asset])
        var denied = false
        do { _ = try wrong.archive() } catch { denied = true }
        try verify(denied, "Unrelated release URL cannot become an update source")
        let safe = directory.appendingPathComponent("SafeZip")
        let minimal = safe.appendingPathComponent("Spy.app/Contents/MacOS", isDirectory: true)
        try files.createDirectory(at: minimal, withIntermediateDirectories: true)
        try Data("executable".utf8).write(to: minimal.appendingPathComponent("Spy"))
        try Data("metadata".utf8).write(to: safe.appendingPathComponent("Spy.app/Contents/Info.plist"))
        let archive = directory.appendingPathComponent("safe.zip")
        try SpyUpdateInstaller.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", safe.appendingPathComponent("Spy.app").path, archive.path])
        let bytes = try Data(contentsOf: archive)
        try SpyUpdateArchive.inspect(bytes)
        var escaped = bytes
        let old = Data("Spy.app/".utf8), replacement = Data("../evil/".utf8)
        var start = 0
        while let range = escaped.range(of: old, in: start..<escaped.count) { escaped.replaceSubrange(range, with: replacement); start = range.lowerBound + replacement.count }
        for invalid in [escaped, bytes.prefix(20)] {
            var rejected = false
            do { try SpyUpdateArchive.inspect(Data(invalid)) } catch { rejected = true }
            try verify(rejected, "Traversal and incomplete ZIP fail before extraction")
        }
        try files.createSymbolicLink(atPath: safe.appendingPathComponent("Spy.app/Escape").path, withDestinationPath: "/tmp")
        let symlinkZip = directory.appendingPathComponent("symlink.zip")
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zip.currentDirectoryURL = safe
        zip.arguments = ["-qry", "--symlinks", symlinkZip.path, "Spy.app"]
        try zip.run(); zip.waitUntilExit()
        var rejectedLink = false
        do { try SpyUpdateArchive.inspect(Data(contentsOf: symlinkZip)) } catch { rejectedLink = true }
        try verify(rejectedLink, "Symlink ZIP cannot escape staging or alter unrelated files")
        print("PASS: semantic version policy, fixed release origin/digest, safe ZIP headers, traversal/symlink/truncation rejection")

        let fixtureRoot = directory.appendingPathComponent("Fixtures")
        let source = fixtureRoot.appendingPathComponent("Candidate/Spy.app")
        let installed = fixtureRoot.appendingPathComponent("Installed/Spy.app")
        let rollback = fixtureRoot.appendingPathComponent("Rollback/Spy.app")
        if files.fileExists(atPath: source.path) {
            let pin = try SpyUpdateInstaller.validate(candidate: source, current: installed, expectedVersion: "99.0.0")
            var deniedDowngrade = false
            do { _ = try SpyUpdateInstaller.validate(candidate: installed, current: source, expectedVersion: "98.0.0") } catch { deniedDowngrade = true }
            try verify(deniedDowngrade, "Signed older release cannot downgrade the app")
            let corrupt = fixtureRoot.appendingPathComponent("Broken.app")
            try files.copyItem(at: source, to: corrupt)
            let executable = corrupt.appendingPathComponent("Contents/MacOS/Spy")
            let handle = try FileHandle(forWritingTo: executable); try handle.seekToEnd(); try handle.write(contentsOf: Data("tampered".utf8)); try handle.close()
            var deniedSignature = false
            do { _ = try SpyUpdateInstaller.validate(candidate: corrupt, current: installed, expectedVersion: "99.0.0") } catch { deniedSignature = true }
            try verify(deniedSignature, "A modified executable never passes signed update validation")
            func plan(_ destination: URL) throws -> SpyInstallPlan {
                let stage = directory.appendingPathComponent("Spy/Updates/staging-" + UUID().uuidString)
                let unpacked = stage.appendingPathComponent("unpacked")
                try files.createDirectory(at: unpacked, withIntermediateDirectories: true)
                let candidate = unpacked.appendingPathComponent("Spy.app"); try files.copyItem(at: source, to: candidate)
                return SpyInstallPlan(parentPID: 2_000_000_000, destination: destination, candidate: candidate, stage: stage, certificate: pin, version: "99.0.0")
            }
            let success = try plan(installed)
            try SpyUpdateInstaller.execute(success, launch: false)
            try verify(try version(installed) == "99.0.0" && files.fileExists(atPath: success.stage.appendingPathComponent("PreviousSpy.zip").path),
                "Actual signed replacement installs the new app and keeps the old app as ZIP")
            let failure = try plan(rollback)
            var rolledBack = false
            do { try SpyUpdateInstaller.execute(failure, launch: false, afterReplacement: { throw SpyError.message("Synthetic post-replacement error") }) }
            catch { rolledBack = true }
            try verify(try rolledBack && version(rollback) == "98.0.0" && SpyUpdateInstaller.identity(rollback).certificate == pin,
                "Failure after replacement restores the exact signed old app")
            print("PASS: actual certificate/DR validation, tampered code rejection, downgrade protection, installed app replacement and rollback with backup")
        } else { print("SKIP: optional signed installer fixtures are absent") }
        if ProcessInfo.processInfo.environment["SPY_UPDATE_NETWORK_TEST"] == "1" {
            let updates = AppUpdates(); await updates.check()
            guard let value = updates.release else { throw SpyError.message("TEST FAILED: live release check: " + (updates.status ?? "unknown")) }
            let asset = try value.archive()
            let (temporary, response) = try await URLSession.shared.download(for: URLRequest(url: asset.browser_download_url), delegate: SpyUpdateDownloadLimit(limit: asset.size))
            defer { try? files.removeItem(at: temporary) }
            let data = try Data(contentsOf: temporary)
            try verify((response as? HTTPURLResponse)?.statusCode == 200 && data.count == asset.size && "sha256:" + SpyUpdateInstaller.hash(data) == asset.digest,
                "Real GitHub archive download is complete and matches release digest")
            try SpyUpdateArchive.inspect(data)
            print("PASS: live GitHub release API, bounded redirect-aware ZIP download, SHA256 and archive inspection")
        }
    }
    private static func verify(_ condition: Bool, _ message: String) throws { try SelfTest.require(condition, message) }
    private static func version(_ app: URL) throws -> String {
        let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as! [String: Any]
        return value["CFBundleShortVersionString"] as! String
    }
}
