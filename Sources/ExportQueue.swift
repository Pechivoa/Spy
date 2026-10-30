import SwiftUI
import AVFoundation

struct ExportQueueItem: Identifiable {
    enum Phase: String, Codable { case paused, preparing, waiting, running, cancelling, completed, cancelled, failed }
    let id: UUID
    let title: String
    let sourceKey: String
    let range: PreviewRange
    var microphoneEnabled = true
    var gains = AudioLevels()
    var phase: Phase = .preparing
    var progress: Double = 0
    var result: URL?
    var error: String?
    var retainedDirectory: URL?
    var pending: Bool { [.paused, .preparing, .waiting, .running, .cancelling].contains(phase) }
    var status: String {
        switch phase {
        case .paused: return "Приостановлено · можно продолжить"
        case .preparing: return "Подготовка"
        case .waiting: return "Ожидает"
        case .running: return "Сохраняется · \(Int(progress * 100))%"
        case .cancelling: return "Отменяется…"
        case .completed: return "Сохранено"
        case .cancelled: return "Отменено"
        case .failed: return "Ошибка"
        }
    }
}

struct QueuedExportPlan {
    let directory: URL
    let export: (@escaping (Float) -> Void) async throws -> URL
}

/// Each job owns its pinned inputs and frozen selection/audio settings. Closing
/// a viewer, changing its selection or deleting an original cannot retarget it.
@MainActor final class ExportQueueController: ObservableObject {
    @Published private(set) var items: [ExportQueueItem] = []
    @Published private(set) var pausing = false
    private var plans: [UUID: QueuedExportPlan] = [:]
    private var preparations: [UUID: Task<Void, Never>] = [:]
    private var runner: Task<Void, Never>?
    private var runningID: UUID?
    private var outcomes: [UUID: Result<URL, Error>] = [:]
    private var waiters: [UUID: Int] = [:]
    private let pendingChanged: (Int) -> Void
    private let canStart: () -> Bool
    private let diagnostic: (String, Bool) -> Void
    private var durableStore: DurableExportStore?
    private var records: [UUID: DurableExportJob] = [:]
    private var directories: [UUID: URL] = [:]
    private var durableFactory: ((DurableExportJob, URL) async throws -> QueuedExportPlan)?
    var pendingCount: Int { items.filter(\.pending).count }
    var restoredCount: Int { items.filter { $0.phase == .paused }.count }
    func canResume(_ id: UUID) -> Bool { records[id] != nil && [.paused, .failed].contains(item(id)?.phase ?? .completed) }
    var protectedDirectories: Set<URL> { Set(items.filter { $0.pending || $0.phase == .failed }.compactMap { directories[$0.id] }) }

    func configureDurability(root: URL, factory: @escaping (DurableExportJob, URL) async throws -> QueuedExportPlan) throws {
        guard durableStore == nil else { return }
        let store = try DurableExportStore(root: root)
        durableStore = store; durableFactory = factory
        for (record, directory) in store.scan(report: { [diagnostic] in diagnostic($0, true) }) {
            guard records[record.id] == nil else { diagnostic("Повторяется идентификатор задачи; исходники сохранены.", true); continue }
            let range = try record.range
            records[record.id] = record; directories[record.id] = directory
            var item = ExportQueueItem(id: record.id, title: record.title, sourceKey: record.sourceKey, range: range,
                microphoneEnabled: record.microphone, gains: record.gains,
                phase: record.phase == "cancelled" || record.phase == "cancelling" ? .cancelled : .paused)
            item.error = record.issue; item.retainedDirectory = directory
            items.append(item)
        }
        changed()
    }
    @discardableResult func enqueueDurable(_ record: DurableExportJob, directory: URL) throws -> UUID {
        guard let store = durableStore, let factory = durableFactory else { throw SpyError.message("Сохраняемая очередь недоступна. Проверьте журнал и папку кэша.") }
        try store.write(record, in: directory)
        records[record.id] = record; directories[record.id] = directory
        return enqueue(title: record.title, sourceKey: record.sourceKey, range: try record.range, directory: directory,
            microphone: record.microphone, gains: record.gains, id: record.id) { try await factory(record, directory) }
    }
    func resume(_ id: UUID) {
        guard !pausing, let item = item(id), item.phase == .paused || item.phase == .failed,
              let record = records[id], let directory = directories[id], let factory = durableFactory else { return }
        outcomes[id] = nil
        update(id) { $0.phase = .preparing; $0.error = nil; $0.progress = 0 }
        prepare(id, directory: directory) { try await factory(record, directory) }
    }
    func resumeRestored() { for id in items.filter({ $0.phase == .paused }).map(\.id) { resume(id) } }
    func pauseAll() async {
        guard !pausing else { return }
        pausing = true
        let tasks = Array(preparations.values), running = runner
        tasks.forEach { $0.cancel() }; running?.cancel()
        for task in tasks { await task.value }
        await running?.value
        for id in items.filter({ $0.pending && $0.phase != .paused }).map(\.id) {
            update(id) { $0.phase = .paused; $0.error = nil }
            plans[id] = nil
        }
        pausing = false
    }
    func checkpointPublication(_ id: UUID, receipt: ExportPublicationReceipt) throws {
        guard var record = records[id], let directory = directories[id], let store = durableStore else { throw SpyError.message("Задача сохранения недоступна.") }
        record.receipt = receipt
        try store.write(record, in: directory); records[id] = record
    }

    init(pendingChanged: @escaping (Int) -> Void = { _ in }, canStart: @escaping () -> Bool = { true }, diagnostic: @escaping (String, Bool) -> Void = { _, _ in }) {
        self.pendingChanged = pendingChanged; self.canStart = canStart; self.diagnostic = diagnostic
    }
    @discardableResult func enqueue(title: String, sourceKey: String, range: PreviewRange, directory: URL,
                                    microphone: Bool = true, gains: AudioLevels = AudioLevels(), id: UUID = UUID(),
                                    prepare: @escaping () async throws -> QueuedExportPlan) -> UUID {
        // Retain all live work, and bound completed history.
        if items.count >= 50 { clearFinished() }
        items.append(ExportQueueItem(id: id, title: title, sourceKey: sourceKey, range: range, microphoneEnabled: microphone, gains: gains))
        changed()
        self.prepare(id, directory: directory, operation: prepare)
        return id
    }
    private func prepare(_ id: UUID, directory: URL, operation: @escaping () async throws -> QueuedExportPlan) {
        preparations[id] = Task { [weak self] in
            guard let self else { return }
            do {
                let plan = try await operation()
                try Task.checkCancellation()
                self.plans[id] = plan
                self.update(id) { $0.phase = .waiting }
                self.preparations[id] = nil
                self.pump()
            } catch {
                self.fail(id, directory: directory, error: error, cancelled: Task.isCancelled)
                self.preparations[id] = nil
                self.pump()
            }
        }
    }
    func item(_ id: UUID) -> ExportQueueItem? { items.first { $0.id == id } }
    func existing(sourceKey: String, range: PreviewRange, microphone: Bool, gains: AudioLevels, includeCompleted: Bool = false) -> UUID? {
        items.last { ($0.pending || includeCompleted && $0.phase == .completed && $0.result.map { FileManager.default.fileExists(atPath: $0.path) } == true) && $0.sourceKey == sourceKey && $0.range == range && $0.microphoneEnabled == microphone && $0.gains == gains }?.id
    }
    func pending(sourceKey: String, range: PreviewRange?, microphone: Bool, gains: AudioLevels) -> Bool {
        items.contains { $0.pending && $0.sourceKey == sourceKey && $0.range == range && $0.microphoneEnabled == microphone && $0.gains == gains }
    }
    func saved(sourceKey: String, range: PreviewRange?, microphone: Bool, gains: AudioLevels) -> URL? {
        items.reversed().first { $0.phase == .completed && $0.sourceKey == sourceKey && $0.range == range && $0.microphoneEnabled == microphone && $0.gains == gains && $0.result.map { FileManager.default.fileExists(atPath: $0.path) } == true }?.result
    }
    func cancel(_ id: UUID) {
        guard let item = item(id), item.pending else { return }
        if item.phase == .preparing || item.phase == .cancelling && preparations[id] != nil {
            update(id) { $0.phase = .cancelling }; preparations[id]?.cancel(); return
        }
        if runningID == id { update(id) { $0.phase = .cancelling }; runner?.cancel(); return }
        guard markCancelled(id) else { return }
        if let directory = plans.removeValue(forKey: id)?.directory ?? directories[id] { try? FileManager.default.removeItem(at: directory) }
        outcomes[id] = .failure(CancellationError())
        update(id) { $0.phase = .cancelled }
        pump()
    }
    func clearFinished() {
        var cleared = Set<UUID>()
        for item in items where !item.pending {
            do {
                if let directory = directories[item.id] {
                    let manifest = directory.appendingPathComponent(DurableExportJob.fileName)
                    if item.phase == .cancelled, FileManager.default.fileExists(atPath: directory.path) {
                        try durableStore?.validateDirectory(directory)
                        try FileManager.default.removeItem(at: directory)
                    } else if FileManager.default.fileExists(atPath: manifest.path) { try FileManager.default.removeItem(at: manifest) }
                }
                records[item.id] = nil; directories[item.id] = nil; cleared.insert(item.id)
            } catch { diagnostic("Не удалось убрать задачу: " + describeError(error), true) }
        }
        items.removeAll { cleared.contains($0.id) }
        outcomes = outcomes.filter { item($0.key) != nil || waiters[$0.key] != nil }
        changed()
    }
    func result(_ id: UUID) async throws -> URL {
        waiters[id, default: 0] += 1
        defer {
            waiters[id, default: 1] -= 1
            if waiters[id] == 0 { waiters[id] = nil; if item(id) == nil { outcomes[id] = nil } }
        }
        if let outcome = outcomes[id] { return try outcome.get() }
        while let item = item(id) {
            if let result = item.result { return result }
            if item.phase == .cancelled { throw CancellationError() }
            if item.phase == .failed { throw SpyError.message(item.error ?? "Не удалось сохранить фрагмент.") }
            if item.phase == .paused { throw SpyError.message("Возобновите восстановленную задачу в очереди сохранения.") }
            try await Task.sleep(nanoseconds: 50_000_000)
            if let outcome = outcomes[id] { return try outcome.get() }
        }
        throw SpyError.message("Задача сохранения уже удалена из очереди.")
    }
    private func update(_ id: UUID, _ body: (inout ExportQueueItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        body(&items[index]); changed()
        if var record = records[id], let directory = directories[id], let store = durableStore {
            guard record.phase != items[index].phase.rawValue || record.issue != items[index].error else { return }
            record.phase = items[index].phase.rawValue; record.issue = items[index].error
            do { try store.write(record, in: directory); records[id] = record }
            catch { diagnostic("Не удалось записать состояние очереди. Исходники сохранены.\n" + describeError(error), true) }
        }
    }
    private func changed() { pendingChanged(items.filter { $0.pending && $0.phase != .paused }.count) }
    private func markCancelled(_ id: UUID) -> Bool {
        guard var record = records[id], let directory = directories[id], let store = durableStore else { return true }
        record.phase = "cancelled"
        do { try store.write(record, in: directory); records[id] = record; return true }
        catch {
            update(id) { $0.phase = .failed; $0.error = "Не удалось сохранить отмену. Исходники оставлены: " + error.localizedDescription; $0.retainedDirectory = directory }
            return false
        }
    }
    private func fail(_ id: UUID, directory: URL, error: Error, cancelled: Bool) {
        if pausing, cancelled || error is CancellationError {
            outcomes[id] = nil
            update(id) { $0.phase = .paused; $0.error = nil; $0.retainedDirectory = directory }
            return
        }
        if cancelled || error is CancellationError {
            guard markCancelled(id) else { return }
            try? FileManager.default.removeItem(at: directory)
            outcomes[id] = .failure(CancellationError())
            update(id) { $0.phase = .cancelled; $0.error = nil }
        } else {
            let retained = directory.deletingLastPathComponent().appendingPathComponent("record-queue-" + id.uuidString)
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            var recovery: URL?
            if records[id] != nil || files.contains(where: { $0.pathExtension == "mov" }) {
                do { if directory != retained { try FileManager.default.moveItem(at: directory, to: retained) }; recovery = retained }
                catch { recovery = directory }
            } else { try? FileManager.default.removeItem(at: directory) }
            outcomes[id] = .failure(error)
            if records[id] != nil, let recovery { directories[id] = recovery }
            update(id) { $0.phase = .failed; $0.error = error.localizedDescription; $0.retainedDirectory = recovery }
            diagnostic(describeError(error) + (recovery.map { "\nИсходник: " + $0.path } ?? ""), true)
        }
    }
    private func pump() {
        guard !pausing, runner == nil, let item = items.first(where: { $0.pending && $0.phase != .paused }), item.phase == .waiting, let plan = plans[item.id] else { return }
        let id = item.id
        runningID = id
        runner = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.item(id)?.phase == .completed || self.item(id)?.phase == .cancelled {
                    try? FileManager.default.removeItem(at: plan.directory)
                }
                self.plans[id] = nil; self.runningID = nil; self.runner = nil; self.pump()
            }
            do {
                while !self.canStart() { try await Task.sleep(nanoseconds: 100_000_000) }
                try Task.checkCancellation()
                self.update(id) { $0.phase = .running }
                let result = try await plan.export { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.item(id)?.phase == .running else { return }
                        self.update(id) { $0.progress = max($0.progress, min(0.99, Double(value))) }
                    }
                }
                // The export operation checks cancellation before publication.
                // Once a file is published, keep the truthful completed result.
                self.outcomes[id] = .success(result)
                self.update(id) { $0.result = result; $0.progress = 1; $0.phase = .completed }
            } catch {
                self.fail(id, directory: plan.directory, error: error, cancelled: Task.isCancelled)
            }
        }
    }
}
