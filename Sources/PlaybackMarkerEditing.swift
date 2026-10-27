import Foundation

func frameClock(_ seconds: Double) -> String {
    let value = seconds.isFinite ? min(max(0, seconds), Double(Int64.max / 1000 - 1)) : 0
    let milliseconds = Int64((value * 1000).rounded())
    return String(format: "%02lld:%02lld.%03lld", milliseconds / 60_000, milliseconds / 1000 % 60, milliseconds % 1000)
}

@MainActor extension AppModel {
    @discardableResult func addBufferPreviewMarker(_ previewID: UUID, at seconds: Double) -> ClipMarker? {
        guard !saving, let current = bufferPreview, current.id == previewID,
              seconds.isFinite, current.clip.duration > 0 else { return nil }
        let position = min(max(0, seconds), max(0, current.clip.duration - 1.0 / 60_000))
        let marker = ClipMarker(id: UUID(), seconds: position, title: "Метка \(current.momentMarkers.count + 1)")
        bufferPreview?.addedMarkers.append(marker)
        journal.record(.info, "Метка в просмотре", "Метка на \(frameClock(position)) добавлена в текущий снимок.")
        return marker
    }

    @discardableResult func addPlaybackMarker(_ clip: Clip, at seconds: Double) -> ClipMarker? {
        guard !saving, seconds.isFinite, clip.duration > 0, FileManager.default.fileExists(atPath: clip.url.path) else { return nil }
        var value = metadata.get(clip.url)
        let position = min(max(0, seconds), max(0, clip.duration - 1.0 / 60_000))
        let marker = ClipMarker(id: UUID(), seconds: position, title: "Метка \(value.markers.count + 1)")
        value.markers.append(marker); value.markers.sort { $0.seconds < $1.seconds }
        do {
            try metadata.set(value, for: clip.url)
            objectWillChange.send()
            journal.record(.info, "Метка в видео", clip.url.lastPathComponent + " · " + frameClock(position))
            return marker
        } catch {
            showError("Не удалось сохранить метку: " + error.localizedDescription, topic: "Метка в видео", details: describeError(error))
            return nil
        }
    }
}
