import SwiftUI
import AppKit

func detailedFileSize(_ bytes: Int64) -> String {
    if bytes < 1024 { return "\(max(0, bytes)) Б" }
    let units = ["КБ", "МБ", "ГБ", "ТБ", "ПБ"]
    var value = Double(bytes) / 1024, unit = 0
    while value >= 1024 && unit < units.count - 1 { value /= 1024; unit += 1 }
    return String(format: "%.1f %@", locale: Locale(identifier: "ru_RU"), value, units[unit])
}

enum SpyCacheKind: String, CaseIterable {
    case live, preview, queued, recovery, updates, other
    var title: String {
        switch self { case .live: return "Текущий буфер"; case .preview: return "Временные просмотры"; case .queued: return "Очередь сохранения"; case .recovery: return "Записи для восстановления"; case .updates: return "Резервные копии обновлений"; case .other: return "Другие служебные данные" }
    }
}
struct SpyCacheEntry: Identifiable {
    var id: URL { url }
    let url: URL
    let kind: SpyCacheKind
    let bytes: Int64
    let date: Date
    let removable: Bool
}

enum SpyCacheInventory {
    static func kind(_ name: String, update: Bool = false) -> SpyCacheKind {
        if update { return .updates }
        if name.hasPrefix("replay-") { return .live }
        if name.hasPrefix("preview-") || name.hasPrefix("save-") { return .preview }
        if name.hasPrefix("queue-") { return .queued }
        if name.hasPrefix("record-") || name.hasPrefix("recovery-retained-") { return .recovery }
        return .other
    }
    static func size(_ root: URL) -> Int64 {
        guard let values = try? root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey]), values.isSymbolicLink != true else { return 0 }
        if values.isDirectory != true { return Int64(values.fileSize ?? 0) }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let v = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { continue }
            if v.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if v.isRegularFile == true { total += Int64(v.fileSize ?? 0) }
        }
        return total
    }
    static func scan(cache: URL, updates: URL) -> [SpyCacheEntry] {
        [cache, updates].flatMap { root -> [SpyCacheEntry] in
            guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey])).map({ $0.isSymbolicLink != true }) == true else { return [] }
            return ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey])) ?? []).compactMap { url in
                guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey]), v.isSymbolicLink != true else { return nil }
                let kind = Self.kind(url.lastPathComponent, update: root == updates)
                let updateDone = kind == .updates && v.isDirectory == true && url.lastPathComponent.hasPrefix("staging-") &&
                    !FileManager.default.fileExists(atPath: url.appendingPathComponent("SpyInstaller").path) &&
                    !FileManager.default.fileExists(atPath: url.appendingPathComponent("Update.zip").path)
                let removable = v.isDirectory == true && (kind == .preview || kind == .recovery || updateDone)
                return SpyCacheEntry(url: url, kind: kind, bytes: size(url), date: v.creationDate ?? .distantPast, removable: removable)
            }
        }.sorted { $0.date > $1.date }
    }
    static func validateRemoval(_ url: URL, cache: URL, updates: URL) throws -> SpyCacheEntry {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey])).map({ $0.isSymbolicLink != true }) == true,
              [cache.resolvingSymlinksInPath().standardizedFileURL.path, updates.resolvingSymlinksInPath().standardizedFileURL.path].contains(canonical.deletingLastPathComponent().path),
              let item = scan(cache: cache, updates: updates).first(where: { $0.url.resolvingSymlinksInPath().standardizedFileURL.path == canonical.path }), item.removable else {
            throw SpyError.message("Эти данные защищены или уже изменились. Обновите список.")
        }
        guard !ReplayCrashRecovery.hasLiveOwner(cache) else { throw SpyError.message("Другая Spy использует кэш. Завершите запись в ней перед очисткой.") }
        return item
    }
}

@MainActor extension AppModel {
    var updateStorageURL: URL { journal.fileURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Updates") }
    var storageLocked: Bool { recording || busy || saving || manualRecording || bufferPreview != nil || diagnosticsBusy || updates.working || updates.pendingInstall || shuttingDown }
    func trashCacheEntry(_ entry: SpyCacheEntry) async {
        guard !storageLocked else { showError("Закройте просмотр, остановите запись и дождитесь сохранения перед очисткой.", topic: "Очистка кэша"); return }
        busy = true
        defer { busy = false }
        do {
            let cache = cacheURL, updatesRoot = updateStorageURL
            let checked = try await Task.detached(priority: .utility) {
                try SpyCacheInventory.validateRemoval(entry.url, cache: cache, updates: updatesRoot)
            }.value
            try FileManager.default.trashItem(at: checked.url, resultingItemURL: nil)
            journal.record(.info, "Очистка кэша", checked.kind.title + ": " + checked.url.lastPathComponent + " перемещено в Корзину.")
            refreshRecoveryFolders(); refreshDisk()
        } catch { showError(error.localizedDescription, topic: "Очистка кэша") }
    }
}

struct StorageCenterView: View {
    @ObservedObject var model: AppModel
    @State private var entries: [SpyCacheEntry] = []
    @State private var loading = false
    @State private var candidate: SpyCacheEntry?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Использование места", systemImage: "internaldrive").font(.title2.bold())
                Spacer()
                Button("Обновить") { Task { await refresh() } }.disabled(loading)
                if loading { ProgressView().controlSize(.small) }
            }
            Text("Размер файлов: " + detailedFileSize(entries.reduce(0) { $0 + $1.bytes })).font(.headline)
            Text("Просмотры могут разделять данные с буфером. Размер файлов не равен освобождаемому месту. Удалённое останется в Корзине macOS.").font(.caption).foregroundStyle(Theme.muted)
            if model.storageLocked { Label("Очистка доступна после остановки записи и закрытия просмотра", systemImage: "lock.fill").font(.caption).foregroundStyle(.orange) }
            ForEach(SpyCacheKind.allCases, id: \.self) { kind in
                let rows = entries.filter { $0.kind == kind }
                DisclosureGroup {
                    ForEach(rows) { row in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(row.kind.title).lineLimit(1).font(.system(size: 12)).help(row.url.path)
                                Text(row.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            Text(detailedFileSize(row.bytes)).monospacedDigit().font(.caption)
                            Button { NSWorkspace.shared.activateFileViewerSelecting([row.url]) } label: { Image(systemName: "folder") }.help("Показать в Finder")
                            Button { candidate = row } label: { Image(systemName: row.removable ? "trash" : "lock") }
                                .disabled(!row.removable || model.storageLocked).help(row.removable ? "Переместить в Корзину" : "Служебные или активные данные защищены")
                        }.padding(.vertical, 5)
                    }
                } label: {
                    HStack { Text(kind.title); Spacer(); Text(detailedFileSize(rows.reduce(0) { $0 + $1.bytes })).foregroundStyle(Theme.muted) }
                }.padding(14).background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
            }
            Button("Открыть центр восстановления") { model.section = 6 }
        }.task { await refresh() }
        .confirmationDialog("Переместить выбранную папку в Корзину?", isPresented: Binding(get: { candidate != nil }, set: { if !$0 { candidate = nil } }), titleVisibility: .visible) {
            if let candidate { Button("Переместить в Корзину", role: .destructive) { Task { await model.trashCacheEntry(candidate); await refresh() }; self.candidate = nil } }
            Button("Отмена", role: .cancel) { candidate = nil }
        } message: { Text("Проверьте запись в центре восстановления перед удалением. Корзину Spy не очищает.") }
    }
    private func refresh() async {
        guard !loading else { return }; loading = true; defer { loading = false }
        let cache = model.cacheURL, updates = model.updateStorageURL
        entries = await Task.detached(priority: .utility) { SpyCacheInventory.scan(cache: cache, updates: updates) }.value
    }
}
