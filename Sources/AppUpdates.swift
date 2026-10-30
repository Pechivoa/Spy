import SwiftUI
import CryptoKit
import Security
import Darwin

struct SpyVersion: Comparable, Equatable {
    let parts: [Int]
    init(_ value: String) throws {
        let text = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(pieces.count), pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) && Int($0) != nil }) else {
            throw SpyError.message("Неверный номер версии обновления.")
        }
        parts = pieces.map { Int($0)! }
    }
    static func < (lhs: Self, rhs: Self) -> Bool {
        for i in 0..<max(lhs.parts.count, rhs.parts.count) {
            let a = i < lhs.parts.count ? lhs.parts[i] : 0, b = i < rhs.parts.count ? rhs.parts[i] : 0
            if a != b { return a < b }
        }
        return false
    }
    static func == (lhs: Self, rhs: Self) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

struct SpyUpdateRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let size: Int64
        let digest: String?
        let browser_download_url: URL
    }
    let tag_name: String
    let html_url: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    func archive() throws -> Asset {
        _ = try SpyVersion(tag_name)
        let name = "Spy-\(tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name)-macOS-arm64.zip"
        guard !draft, !prerelease,
              html_url.absoluteString == "https://github.com/Pechivoa/Spy/releases/tag/\(tag_name)",
              let asset = assets.first(where: { $0.name == name }), (1...200_000_000).contains(asset.size),
              asset.browser_download_url.absoluteString == "https://github.com/Pechivoa/Spy/releases/download/\(tag_name)/\(name)",
              let digest = asset.digest, digest.hasPrefix("sha256:"), digest.count == 71,
              digest.dropFirst(7).allSatisfy({ $0.isHexDigit }) else {
            throw SpyError.message("В выпуске нет подходящего проверяемого ZIP для этого Mac.")
        }
        return asset
    }
}

struct SpyInstallPlan: Codable {
    let parentPID: Int32
    let destination: URL
    let candidate: URL
    let stage: URL
    let certificate: String
    let version: String
}

@MainActor enum SpyUpdateTermination {
    static func request(_ terminate: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }) {
        // AppKit's terminate-later loop must start from the run loop, outside
        // both a Swift task and a main-queue block. Its nested loop cannot
        // drain the main queue while such a block is still executing.
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated { terminate() }
        }
    }
}

enum SpyUpdateInstaller {
    static let identifier = "local.spy.mac"
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func run(_ executable: String, _ arguments: [String]) throws {
        let task = Process(); task.executableURL = URL(fileURLWithPath: executable); task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        try task.run(); task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw SpyError.message("Не удалось выполнить шаг обновления: " + URL(fileURLWithPath: executable).lastPathComponent) }
    }
    static func identity(_ app: URL) throws -> (certificate: String, requirement: Data) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), nil) == errSecSuccess else {
            throw SpyError.message("Подпись приложения повреждена. Обновление остановлено.")
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              dictionary[kSecCodeInfoIdentifier as String] as? String == identifier,
              let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certificates.first else {
            throw SpyError.message("Для этой подписи автоматическая установка недоступна. Используйте ZIP или собственную подписанную сборку.")
        }
        var requirement: SecRequirement?, data: CFData?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyData(requirement, [], &data) == errSecSuccess, let data else { throw SpyError.message("Не удалось проверить идентификатор подписи.") }
        return (hash(SecCertificateCopyData(leaf) as Data), data as Data)
    }
    static func validate(candidate: URL, current: URL, expectedVersion: String) throws -> String {
        let files = FileManager.default
        for app in [candidate, current] {
            guard app.pathExtension == "app", app.standardizedFileURL == app.resolvingSymlinksInPath().standardizedFileURL,
                  let bundle = Bundle(url: app), bundle.bundleIdentifier == identifier,
                  (try app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).isSymbolicLink != true,
                  files.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/Spy").path) else { throw SpyError.message("Неверный пакет приложения для обновления.") }
        }
        guard let old = Bundle(url: current)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let new = Bundle(url: candidate)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              new == expectedVersion, try SpyVersion(new) > SpyVersion(old) else { throw SpyError.message("Устанавливать можно только более новую версию Spy.") }
        if let minimum = Bundle(url: candidate)?.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            guard try SpyVersion(minimum) <= SpyVersion("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)") else {
                throw SpyError.message("Новая Spy требует более новую macOS. Текущая версия сохранена.")
            }
        }
        let first = try identity(current), second = try identity(candidate)
        guard first.certificate == second.certificate, first.requirement == second.requirement else {
            throw SpyError.message("Подпись новой версии отличается от установленной. Автоматическая замена отменена.")
        }
        return first.certificate
    }
    /// The helper runs from an unchanged copy of the installed executable. It
    /// waits for normal app termination; it never kills Spy or changes TCC.
    static func execute(_ plan: SpyInstallPlan, launch: Bool = true, afterReplacement: (() throws -> Void)? = nil) throws {
        let files = FileManager.default
        guard plan.parentPID > 1, plan.destination.pathExtension == "app", plan.stage.path.contains("/Spy/Updates/staging-"),
              plan.candidate.deletingLastPathComponent().lastPathComponent == "unpacked",
              plan.candidate.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path == plan.stage.standardizedFileURL.path else { throw SpyError.message("Неверный план установки.") }
        let deadline = Date().addingTimeInterval(120)
        while kill(plan.parentPID, 0) == 0 {
            if files.fileExists(atPath: plan.stage.appendingPathComponent("cancelled").path) { throw CancellationError() }
            guard Date() < deadline else { throw SpyError.message("Spy ещё работает. Обновление не выполнялось.") }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let lockURL = plan.stage.deletingLastPathComponent().appendingPathComponent("install-" + hash(Data(plan.destination.standardizedFileURL.path.utf8)) + ".lock")
        let lock = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw SpyError.message("Не удалось подготовить установку обновления.") }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { close(lock); throw SpyError.message("Другое обновление Spy уже устанавливается.") }
        defer { flock(lock, LOCK_UN); close(lock) }
        guard !files.fileExists(atPath: plan.stage.appendingPathComponent("cancelled").path),
              try validate(candidate: plan.candidate, current: plan.destination, expectedVersion: plan.version) == plan.certificate else { throw SpyError.message("Проверка обновления не пройдена.") }
        let parent = plan.destination.deletingLastPathComponent()
        guard files.isWritableFile(atPath: parent.path) else { throw SpyError.message("Папка приложения недоступна для записи. Перенесите Spy в доступную папку Applications.") }
        let staged = parent.appendingPathComponent(".Spy-update-" + UUID().uuidString + ".app")
        let old = parent.appendingPathComponent(".Spy-previous-" + UUID().uuidString + ".app")
        defer { try? files.removeItem(at: staged) }
        try run("/usr/bin/ditto", [plan.candidate.path, staged.path])
        _ = try validate(candidate: staged, current: plan.destination, expectedVersion: plan.version)
        try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", plan.destination.path, plan.stage.appendingPathComponent("PreviousSpy.zip").path])
        try files.moveItem(at: plan.destination, to: old)
        do {
            try files.moveItem(at: staged, to: plan.destination)
            guard try identity(plan.destination).certificate == plan.certificate else { throw SpyError.message("Проверка установленной версии не пройдена.") }
            try afterReplacement?()
            try Data("Установлена Spy \(plan.version). Резервная копия: \(plan.stage.appendingPathComponent("PreviousSpy.zip").path)".utf8)
                .write(to: plan.stage.deletingLastPathComponent().appendingPathComponent("last-result.txt"), options: .atomic)
            if launch { try run("/usr/bin/open", [plan.destination.path]) }
        } catch {
            try? files.removeItem(at: plan.destination)
            try files.moveItem(at: old, to: plan.destination)
            throw error
        }
        try? files.removeItem(at: old)
    }
    static func helper(planURL: URL) -> Int32 {
        do {
            let plan = try JSONDecoder().decode(SpyInstallPlan.self, from: Data(contentsOf: planURL))
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Spy/Updates")
            guard plan.stage.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path,
                  plan.stage.lastPathComponent.hasPrefix("staging-") else { throw SpyError.message("Неверная папка установки.") }
            defer {
                for name in ["unpacked", "Update.zip", "SpyInstaller", "plan.json", "cancelled"] {
                    try? FileManager.default.removeItem(at: plan.stage.appendingPathComponent(name))
                }
            }
            do { try execute(plan) }
            catch {
                try? Data(("Обновление не установлено: " + error.localizedDescription).utf8).write(to: plan.stage.deletingLastPathComponent().appendingPathComponent("last-result.txt"), options: .atomic)
                if !FileManager.default.fileExists(atPath: plan.stage.appendingPathComponent("cancelled").path) { try? run("/usr/bin/open", [plan.destination.path]) }
                throw error
            }
            return 0
        } catch { fputs(error.localizedDescription + "\n", stderr); return 1 }
    }
}

@MainActor final class AppUpdates: ObservableObject {
    @Published private(set) var release: SpyUpdateRelease?
    @Published private(set) var status: String?
    @Published private(set) var working = false
    @Published private(set) var pendingInstall = false
    private var helperProcess: Process?
    private var stage: URL?
    var canInstall: (() -> Bool)?
    init(loadReceipt: Bool = false) {
        if loadReceipt {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let file = root.appendingPathComponent("Spy/Updates/last-result.txt")
            if let data = try? Data(contentsOf: file), data.count <= 16_384 { status = String(data: data, encoding: .utf8) }
        }
    }
    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.13.1" }
    var hasUpdate: Bool { release.map { (try? SpyVersion($0.tag_name) > SpyVersion(Self.currentVersion)) == true } ?? false }
    func check() async {
        guard !working else { return }; working = true; defer { working = false }
        status = "Проверяю GitHub…"
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/Pechivoa/Spy/releases/latest")!)
            request.timeoutInterval = 30; request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Spy/" + Self.currentVersion, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 2_000_000 else { throw SpyError.message("GitHub временно недоступен. Повторите проверку позже.") }
            let value = try JSONDecoder().decode(SpyUpdateRelease.self, from: data); _ = try value.archive()
            release = value; status = hasUpdate ? "Доступна Spy " + value.tag_name : "Установлена актуальная версия"
        } catch { release = nil; status = error.localizedDescription }
    }
    func install() async {
        guard !working, hasUpdate, canInstall?() != false, let release else { return }
        working = true; defer { working = false }
        status = "Скачиваю обновление…"
        let files = FileManager.default
        var directory: URL?
        do {
            let asset = try release.archive()
            let current = Bundle.main.bundleURL.standardizedFileURL
            _ = try SpyUpdateInstaller.identity(current)
            guard files.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
                throw SpyError.message("Перенесите Spy в доступную для записи папку Applications.")
            }
            let root = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Spy/Updates", isDirectory: true)
            let folder = root.appendingPathComponent("staging-" + UUID().uuidString, isDirectory: true)
            try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); directory = folder
            var request = URLRequest(url: asset.browser_download_url); request.timeoutInterval = 120
            let (temporary, response) = try await URLSession.shared.download(for: request, delegate: SpyUpdateDownloadLimit(limit: asset.size))
            defer { try? files.removeItem(at: temporary) }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize == Int(asset.size) else { throw SpyError.message("Архив обновления загружен не полностью.") }
            status = "Проверяю архив и подпись…"
            let bytes = try Data(contentsOf: temporary, options: .mappedIfSafe)
            guard "sha256:" + SpyUpdateInstaller.hash(bytes) == asset.digest?.lowercased() else { throw SpyError.message("Контрольная сумма обновления не совпала.") }
            let archive = folder.appendingPathComponent("Update.zip"); try files.moveItem(at: temporary, to: archive)
            let unpacked = folder.appendingPathComponent("unpacked", isDirectory: true)
            try files.createDirectory(at: unpacked, withIntermediateDirectories: false)
            // Check archive names before extraction; normal app resource forks
            // (__MACOSX) are allowed, absolute paths and parent traversal are not.
            try SpyUpdateArchive.inspect(bytes)
            try await Task.detached { try SpyUpdateInstaller.run("/usr/bin/unzip", ["-q", archive.path, "Spy.app/*", "-d", unpacked.path]) }.value
            let candidate = unpacked.appendingPathComponent("Spy.app")
            let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
            let certificate = try SpyUpdateInstaller.validate(candidate: candidate, current: current, expectedVersion: version)
            let plan = SpyInstallPlan(parentPID: ProcessInfo.processInfo.processIdentifier, destination: current, candidate: candidate, stage: folder, certificate: certificate, version: version)
            let planURL = folder.appendingPathComponent("plan.json")
            try JSONEncoder().encode(plan).write(to: planURL, options: .atomic)
            let helperURL = folder.appendingPathComponent("SpyInstaller")
            let embedded = current.appendingPathComponent("Contents/Helpers/SpyInstaller")
            let helperSource = files.isExecutableFile(atPath: embedded.path) ? embedded : Bundle.main.executableURL!
            try files.copyItem(at: helperSource, to: helperURL)
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperURL.path)
            guard canInstall?() != false else { throw SpyError.message("Установка отложена: завершите ручную запись или сохранение и повторите попытку.") }
            let process = Process(); process.executableURL = helperURL; process.arguments = ["--spy-install-update", planURL.path]
            try process.run(); helperProcess = process; stage = folder; pendingInstall = true
            status = "Сохраняю сессию и перезапускаю Spy…"
            SpyUpdateTermination.request()
        } catch {
            if let directory { try? files.removeItem(at: directory) }
            status = error.localizedDescription
        }
    }
    func cancelInstall() {
        guard pendingInstall || helperProcess != nil else { return }
        if let stage { try? Data().write(to: stage.appendingPathComponent("cancelled")) }
        if helperProcess?.isRunning == true { helperProcess?.terminate() }
        helperProcess = nil; pendingInstall = false; status = "Обновление отложено. Spy продолжает работать."
    }

}

struct AppUpdatesView: View {
    @ObservedObject var updates: AppUpdates
    var installAllowed: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Обновления Spy", systemImage: "arrow.down.app").font(.system(size: 19, weight: .semibold))
            Text("Установлена версия " + AppUpdates.currentVersion).font(.system(size: 12)).foregroundStyle(Theme.muted)
            HStack {
                Button("Проверить обновления") { Task { await updates.check() } }.disabled(updates.working)
                if updates.hasUpdate {
                    Button("Скачать и установить") { Task { await updates.install() } }.buttonStyle(.borderedProminent).disabled(updates.working || !installAllowed)
                }
                if updates.working { ProgressView().controlSize(.small) }
            }
            if let status = updates.status { Text(status).font(.system(size: 12)).textSelection(.enabled) }
            Text("Проверка выполняется по кнопке. Перед заменой Spy сохраняет сессию; архив и подпись проверяются. Для ручной записи сначала нажмите «Завершить и сохранить».")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
            Link("Выпуски на GitHub", destination: URL(string: "https://github.com/Pechivoa/Spy/releases")!)
        }.buttonStyle(.bordered)
    }
}
