import Foundation
import Darwin

/// Directory events catch Finder changes. A light periodic reconciliation also
/// covers a disconnected volume, a replaced directory and network filesystems.
@MainActor final class LibraryMonitor {
    private var source: DispatchSourceFileSystemObject?
    private var debounce: Task<Void, Never>?
    private var timer: Timer?
    private var directory: URL?
    private var generation = UUID()
    private let changed: @MainActor () async -> Void
    init(changed: @escaping @MainActor () async -> Void) { self.changed = changed }
    func watch(_ directory: URL) {
        generation = UUID()
        debounce?.cancel()
        source?.cancel(); source = nil
        self.directory = directory
        attach()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if self.source == nil { self.attach() }
                    self.schedule()
                }
            }
        }
    }
    private func attach() {
        guard let directory else { return }
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let value = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .revoke], queue: .main)
        let current = generation
        value.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                let invalid = self.source?.data.intersection([.rename, .delete, .revoke]).isEmpty == false
                if invalid { self.source?.cancel(); self.source = nil }
                self.schedule()
            }
        }
        value.setCancelHandler { close(descriptor) }
        source = value; value.resume()
    }
    private func schedule() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 180_000_000) } catch { return }
            guard let self, !Task.isCancelled else { return }
            await self.changed()
        }
    }
    func stop() { source?.cancel(); source = nil; timer?.invalidate(); timer = nil; debounce?.cancel(); debounce = nil }
    deinit { source?.cancel(); timer?.invalidate(); debounce?.cancel() }
}
