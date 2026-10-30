import AVFoundation

enum AssetExportOperation {
    // AVFoundation explicitly supports cancelling an in-flight export. This
    // wrapper exposes only that operation to the concurrent cancel handler.
    private final class Cancellation: @unchecked Sendable {
        let exporter: AVAssetExportSession
        init(_ exporter: AVAssetExportSession) { self.exporter = exporter }
        func cancel() { exporter.cancelExport() }
    }
    static func run(_ exporter: AVAssetExportSession, progress: @escaping (Float) -> Void = { _ in }) async throws {
        let cancellation = Cancellation(exporter)
        let monitor = Task {
            while !Task.isCancelled {
                progress(min(0.99, max(0, exporter.progress)))
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        defer { monitor.cancel() }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            await exporter.export()
            try Task.checkCancellation()
            guard exporter.status == .completed else {
                throw exporter.error ?? SpyError.message("Не удалось сохранить видео.")
            }
            progress(1)
        } onCancel: { cancellation.cancel() }
    }
}
