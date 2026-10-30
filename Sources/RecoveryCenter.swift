import SwiftUI
import AVFoundation
import AppKit

struct RecoverySummary {
    var image: NSImage?
    var date: Date?
    var seconds: Double = 0
    var bytes: Int64 = 0
    var count = 0
    var issue: String?
    static func load(_ folder: URL) async -> Self {
        var result = Self(); result.bytes = SpyCacheInventory.size(folder)
        result.date = ReplayCrashRecovery.manifest(in: folder)?.createdAt ?? (try? folder.resourceValues(forKeys: [.creationDateKey])).flatMap { $0.creationDate }
        let indexed = Dictionary((ReplayCrashRecovery.manifest(in: folder)?.segments ?? []).map { ($0.file, $0.end - $0.start) }, uniquingKeysWith: { first, _ in first })
        var thumbnailAttempts = 0
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])) ?? [])
            .filter { $0.pathExtension.lowercased() == "mov" && (try? $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).map { $0.isRegularFile == true && $0.isSymbolicLink != true } == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in files {
            if Task.isCancelled { return result }
            let asset = AVURLAsset(url: url)
            let duration: Double?
            if let known = indexed[url.lastPathComponent], known.isFinite, known > 0 { duration = known }
            else { duration = try? await asset.load(.duration).seconds }
            if let duration, duration.isFinite, duration > 0 {
                result.seconds += duration; result.count += 1
                if result.image == nil && thumbnailAttempts < 3 {
                    thumbnailAttempts += 1
                    let generator = AVAssetImageGenerator(asset: asset); generator.maximumSize = CGSize(width: 300, height: 170); generator.appliesPreferredTrackTransform = true
                    if let image = try? await generator.image(at: .zero).image { result.image = NSImage(cgImage: image, size: .zero) }
                }
            }
        }
        if result.count == 0 { result.issue = "Готовые видеосегменты не найдены. Исходные файлы оставлены на месте." }
        return result
    }
}

@MainActor extension AppModel {
    func previewRecovery(_ folder: URL) async {
        guard !saving, !busy, !manualRecording, bufferPreview == nil, recoveryFolders.contains(where: { $0.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path }) else { return }
        busy = true
        let pinned = cacheURL.appendingPathComponent("preview-recovery-" + UUID().uuidString, isDirectory: true)
        defer { busy = false }
        do {
            // A private pin allows Finder or cleanup to move the original later
            // without invalidating the immutable composition shown by the player.
            try await Task.detached(priority: .userInitiated) {
                guard (try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).isSymbolicLink != true else { throw SpyError.message("Папка восстановления изменилась.") }
                try FileManager.default.createDirectory(at: pinned, withIntermediateDirectories: false)
                for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                    let target = pinned.appendingPathComponent(file.lastPathComponent)
                    do { try FileManager.default.linkItem(at: file, to: target) } catch { try FileManager.default.copyItem(at: file, to: target) }
                }
            }.value
            let snapshot = try await ReplayCrashRecovery.snapshot(in: pinned)
            let playback = try await BufferPlayback.prepare(snapshot, levels: AudioLevels())
            var clip = Clip(url: pinned.appendingPathComponent("Recovery.virtual"), date: Date(), bytes: playback.bytes, duration: playback.duration, managed: false)
            clip.name = "Предпросмотр восстановления"
            var preview = BufferPreview(directory: pinned, clip: clip, capturedAt: Date(), playback: playback, snapshot: snapshot, separateAudio: true)
            preview.recoveryOrigin = folder
            bufferPreview = preview
            journal.record(.info, "Просмотр восстановления", "Подготовлено " + preciseClock(playback.duration) + ". Исходные сегменты сохранены.")
        } catch {
            try? FileManager.default.removeItem(at: pinned)
            showError(error.localizedDescription, topic: "Просмотр восстановления")
        }
    }
}

struct RecoveryCenterView: View {
    @ObservedObject var model: AppModel
    @State private var refreshID = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Незавершённые записи", systemImage: "arrow.counterclockwise.circle").font(.title2.bold())
                Spacer()
                Button("Обновить") { model.refreshRecoveryFolders(); refreshID = UUID() }
            }
            Text("Сначала посмотрите готовые сегменты, затем сохраните весь ролик или нужный фрагмент. Пропущенные или повреждённые сегменты не включаются в просмотр; исходная папка остаётся на месте.").font(.caption).foregroundStyle(Theme.muted)
            if model.recoveryFolders.isEmpty { Text("Незавершённых записей нет.").foregroundStyle(Theme.green) }
            ForEach(model.recoveryFolders.reversed(), id: \.self) { folder in RecoveryFolderRow(folder: folder, model: model).id(folder.path + refreshID.uuidString) }
            Button("Управлять местом в кэше") { model.section = 7 }
        }.task { model.refreshRecoveryFolders() }
    }
}

private struct RecoveryFolderRow: View {
    let folder: URL
    @ObservedObject var model: AppModel
    @State private var summary: RecoverySummary?
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if let image = summary?.image { Image(nsImage: image).resizable().scaledToFit() }
                else { Image(systemName: "video.badge.ellipsis").font(.largeTitle).foregroundStyle(Theme.muted) }
            }.frame(width: 160, height: 90).background(.black, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 8) {
                Text(summary?.date?.formatted(date: .abbreviated, time: .shortened) ?? "Несохранённая запись").font(.headline).help(folder.path)
                if let summary {
                    Text("\(preciseClock(summary.seconds)) · \(detailedFileSize(summary.bytes)) · сегментов: \(summary.count)").font(.caption).foregroundStyle(Theme.muted)
                    if let issue = summary.issue { Text(issue).font(.caption).foregroundStyle(.orange) }
                } else { ProgressView().controlSize(.small) }
                HStack {
                    Button("Посмотреть") { Task { await model.previewRecovery(folder) } }.buttonStyle(.borderedProminent).foregroundStyle(Theme.accentInk)
                    Button("Сохранить всё") { Task { await model.recoverRecording(folder) } }.buttonStyle(.bordered)
                    Button { NSWorkspace.shared.activateFileViewerSelecting([folder]) } label: { Image(systemName: "folder") }.help("Показать исходники")
                }.disabled(model.saving || model.busy || model.manualRecording || model.bufferPreview != nil)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(14).background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
            .task(id: folder) {
                let task = Task.detached(priority: .utility) { await RecoverySummary.load(folder) }
                let value = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
                if !Task.isCancelled { summary = value }
            }
    }
}
