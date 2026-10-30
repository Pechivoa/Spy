import SwiftUI
import AVFoundation

struct TimelineThumbnail: Identifiable {
    let id: Int
    let seconds: Double
    let image: CGImage?
}

enum TimelineThumbnailGenerator {
    static let maximumSize = CGSize(width: 200, height: 112)

    /// The midpoint of each equal interval avoids asking the decoder for an
    /// image at the exact end of a movie, where there is no video frame.
    static func sampleTimes(duration: Double, count requestedCount: Int = 8) -> [Double] {
        guard duration.isFinite, duration > 0, requestedCount > 0 else { return [] }
        let count = min(16, requestedCount)
        return (0..<count).map { duration * (Double($0) + 0.5) / Double(count) }
    }

    /// One decoder, bounded output size, and sequential asynchronous requests.
    /// Individual failures leave a placeholder; cancellation stops the decoder.
    static func generate(url: URL, duration: Double, count: Int = 8) async throws -> [TimelineThumbnail] {
        try await generate(asset: AVURLAsset(url: url), duration: duration, count: count)
    }

    static func generate(asset: AVAsset, duration: Double, count: Int = 8, start: Double = 0, end: Double? = nil) async throws -> [TimelineThumbnail] {
        try Task.checkCancellation()
        let first = max(0, min(start, duration)), last = min(duration, end ?? duration)
        let times = sampleTimes(duration: max(0, last - first), count: count).map { $0 + first }
        guard !times.isEmpty else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)
        return try await withTaskCancellationHandler {
            var result: [TimelineThumbnail] = []
            for (index, seconds) in times.enumerated() {
                try Task.checkCancellation()
                let image: CGImage?
                do {
                    image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 60_000)).image
                } catch {
                    try Task.checkCancellation()
                    image = nil
                }
                result.append(TimelineThumbnail(id: index, seconds: seconds, image: image))
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            generator.cancelAllCGImageGeneration()
        }
    }
}

struct TimelineThumbnailStrip: View {
    let asset: AVAsset
    let assetID: String
    let duration: Double
    let selectionStart: Double
    let selectionEnd: Double
    let onSeek: (Double) -> Void
    @State private var thumbnails: [TimelineThumbnail] = []
    @State private var loading = true

    init(url: URL, duration: Double, selectionStart: Double, selectionEnd: Double, onSeek: @escaping (Double) -> Void) {
        self.init(asset: AVURLAsset(url: url), assetID: url.absoluteString, duration: duration, selectionStart: selectionStart, selectionEnd: selectionEnd, onSeek: onSeek)
    }
    init(asset: AVAsset, assetID: String, duration: Double, selectionStart: Double, selectionEnd: Double, onSeek: @escaping (Double) -> Void) {
        self.asset = asset; self.assetID = assetID; self.duration = duration
        self.selectionStart = selectionStart; self.selectionEnd = selectionEnd; self.onSeek = onSeek
    }

    private var displayed: [TimelineThumbnail] {
        thumbnails.isEmpty ? TimelineThumbnailGenerator.sampleTimes(duration: duration).enumerated().map {
            TimelineThumbnail(id: $0.offset, seconds: $0.element, image: nil)
        } : thumbnails
    }
    private var unavailable: Bool {
        !loading && !thumbnails.isEmpty && thumbnails.allSatisfy { $0.image == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("Кадры буфера").font(.system(size: 11, weight: .medium))
                Spacer()
                if loading {
                    ProgressView().controlSize(.mini)
                    Text("Загрузка миниатюр…")
                } else {
                    Text(unavailable ? "Миниатюры недоступны · используйте плеер" : "Нажмите кадр для перехода")
                }
            }.font(.system(size: 10)).foregroundStyle(Theme.muted)
            GeometryReader { geometry in
                let count = displayed.count
                let width = max(1, (geometry.size.width - CGFloat(max(0, count - 1)) * 4) / CGFloat(max(1, count)))
                HStack(alignment: .top, spacing: 4) {
                    ForEach(displayed) { thumbnail in
                        let intervalStart = duration * Double(thumbnail.id) / Double(max(1, count))
                        let intervalEnd = duration * Double(thumbnail.id + 1) / Double(max(1, count))
                        let selected = intervalEnd > selectionStart && intervalStart < selectionEnd
                        Button { onSeek(thumbnail.seconds) } label: {
                            VStack(spacing: 4) {
                                ZStack {
                                    Rectangle().fill(Theme.panel)
                                    if let image = thumbnail.image {
                                        Image(decorative: image, scale: 2)
                                            .resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
                                    } else {
                                        Image(systemName: "video").font(.system(size: 14)).foregroundStyle(Theme.muted)
                                    }
                                }
                                .frame(width: width, height: width * 9 / 16)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Theme.accent : Theme.border, lineWidth: selected ? 2 : 1))
                                .opacity(selected ? 1 : 0.35)
                                Text(duration < 10 ? preciseClock(thumbnail.seconds) : clockText(thumbnail.seconds))
                                    .font(.system(size: 9, design: .monospaced)).monospacedDigit()
                                    .foregroundStyle(selected ? Color.white : Theme.muted)
                            }.frame(width: width)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Перейти к \(preciseClock(thumbnail.seconds))")
                        .help("Перейти к " + preciseClock(thumbnail.seconds))
                    }
                }
            }.frame(height: 70)
        }
        .task(id: assetID + "|" + String(duration)) {
            thumbnails = []; loading = true
            do {
                let result = try await TimelineThumbnailGenerator.generate(asset: asset, duration: duration)
                try Task.checkCancellation()
                thumbnails = result; loading = false
            } catch {
                if !Task.isCancelled { loading = false }
            }
        }
    }
}
