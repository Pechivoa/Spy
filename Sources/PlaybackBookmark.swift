import Foundation

struct PlaybackBookmark: Codable, Equatable {
    var position: Double
    var start: Double
    var end: Double
    var rate: Float = 1
    var microphone = true
    var systemGain: Double = 1
    var microphoneGain: Double = 1
    var looping = false
    var sourceBytes: Int64 = 0
    var sourceDuration: Double = 0

    func validated(bytes: Int64, duration: Double) -> PlaybackBookmark? {
        guard duration.isFinite, duration > 0, sourceBytes == bytes,
              abs(sourceDuration - duration) < 0.01,
              [position, start, end, systemGain, microphoneGain].allSatisfy(\.isFinite),
              start >= 0, end > start, end <= duration + 0.001 else { return nil }
        var value = self
        value.position = max(0, min(position, duration))
        value.end = min(end, duration)
        value.rate = PlayerEditingState.supportedRates.contains(rate) ? rate : 1
        value.systemGain = min(1, max(0, systemGain)); value.microphoneGain = min(1, max(0, microphoneGain))
        return value
    }
}

@MainActor extension AppModel {
    func rememberPlayback(_ bookmark: PlaybackBookmark, for url: URL, bytes: Int64, duration: Double) {
        var bookmark = bookmark
        bookmark.sourceBytes = bytes; bookmark.sourceDuration = duration
        guard bookmark.validated(bytes: bytes, duration: duration) != nil else { return }
        var value = metadata.get(url)
        guard value.playback != bookmark else { return }
        value.playback = bookmark
        do { try metadata.set(value, for: url) }
        catch { journal.record(.warning, "Позиция просмотра", describeError(error)) }
    }
}
