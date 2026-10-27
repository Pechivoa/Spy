import Foundation
import SwiftUI

struct ReplayMarker: Codable, Equatable, Identifiable {
    var id = UUID()
    let sourceSeconds: Double
    let date: Date
    var title: String
    var contentSeconds: Double? = nil
}

struct ClipMarker: Codable, Equatable, Identifiable {
    let id: UUID
    var seconds: Double
    var title: String
}

struct MarkerSnapshotMetadata: Codable {
    static let fileName = "marker-timeline.json"
    let files: [String]
    let intervals: [SpySourceInterval]
    let markers: [ReplayMarker]
    static func persist(_ snapshot: SpySnapshot) throws {
        guard !snapshot.markers.isEmpty else { return }
        let value = MarkerSnapshotMetadata(files: snapshot.urls.map(\.lastPathComponent), intervals: snapshot.sourceIntervals, markers: snapshot.markers)
        try JSONEncoder().encode(value).write(to: snapshot.directory.appendingPathComponent(fileName), options: .atomic)
    }
    static func load(_ directory: URL) -> MarkerSnapshotMetadata? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.files.count == value.intervals.count else { return nil }
        return value
    }
}

enum MarkerTimeline {
    static func positions(in snapshot: SpySnapshot) -> [ClipMarker] {
        let total = snapshot.sourceIntervals.reduce(0) { $0 + max(0, $1.end - $1.start) }
        let trim = max(0, total - snapshot.requestedSeconds)
        return snapshot.markers.compactMap { marker in
            var cursor = 0.0
            for interval in snapshot.sourceIntervals {
                defer { cursor += max(0, interval.end - interval.start) }
                if marker.sourceSeconds >= interval.start, marker.sourceSeconds < interval.end {
                    let position = cursor + marker.sourceSeconds - interval.start - trim
                    guard position >= -0.0001, position <= min(total, snapshot.requestedSeconds) else { return nil }
                    return ClipMarker(id: marker.id, seconds: max(0, position), title: marker.title)
                }
            }
            return nil
        }.sorted { $0.seconds < $1.seconds }
    }
    static func selected(_ markers: [ClipMarker], start: Double, end: Double) -> [ClipMarker] {
        markers.filter { $0.seconds >= start - 1.0 / 60_000 && $0.seconds < end }
            .map { ClipMarker(id: $0.id, seconds: max(0, $0.seconds - start), title: $0.title) }
    }
}

@MainActor extension AppModel {
    func openBufferPreview() async {
        showMainWindow?()
        if !previewMode { NSApp.activate(ignoringOtherApps: true) }
        if bufferPreview != nil { return }
        guard canPreviewBuffer else {
            message = recording ? "Дождитесь готовности буфера." : "Сначала включите мгновенный повтор."
            return
        }
        await previewBuffer()
    }
    var canAddMomentMarker: Bool { recording && !busy && !shuttingDown && (minutes > 0 || manualRecording) && !privacyPaused }
    func addMomentMarker() {
        guard canAddMomentMarker, let marker = engine.addMomentMarker() else { return }
        message = "Метка добавлена · " + marker.title
        journal.record(.info, "Метка момента", marker.title)
        queueAutoMoment(marker)
        if notificationsEnabled && !previewMode { toast.show(title: "Метка добавлена", detail: marker.title, displayID: displayID) }
    }
    func storeMarkers(_ markers: [ClipMarker], for url: URL) {
        guard !markers.isEmpty else { return }
        do {
            var value = metadata.get(url); value.markers = markers
            try metadata.set(value, for: url)
        } catch { journal.record(.warning, "Метки видео", "Видео сохранено, но метки не записаны.\n" + describeError(error)) }
    }
}

struct MomentMarkerStrip: View {
    let markers: [ClipMarker]
    let onSeek: (Double) -> Void
    var body: some View {
        if !markers.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    Label("Метки", systemImage: "bookmark.fill").foregroundStyle(Theme.muted)
                    ForEach(markers) { marker in
                        Button { onSeek(marker.seconds) } label: {
                            Text(marker.title + " · " + frameClock(marker.seconds)).lineLimit(1)
                        }.buttonStyle(.bordered).controlSize(.small)
                            .accessibilityLabel("Перейти к метке " + marker.title)
                    }
                }.font(.system(size: 10))
            }.frame(height: 28)
        }
    }
}
