import SwiftUI
import AVFoundation

struct TimelineViewport: Equatable {
    let duration: Double
    let zoom: Double
    let center: Double
    var length: Double { max(0.001, duration / max(1, min(16, zoom))) }
    var start: Double { max(0, min(max(0, duration - length), center - length / 2)) }
    var end: Double { min(duration, start + length) }
    func fraction(_ time: Double) -> Double { max(0, min(1, (time - start) / length)) }
    func time(fraction: Double) -> Double { start + max(0, min(1, fraction)) * length }
}

@MainActor final class TimelineHoverLoader: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var actualTime: Double = 0
    private var task: Task<Void, Never>?
    private var request = UUID()
    private var lastTick: Int?
    private let cache = NSCache<NSNumber, NSImage>()
    init() { cache.countLimit = 32; cache.totalCostLimit = 12_000_000 }
    func request(asset: AVAsset, time: Double) {
        let tick = Int((time * 60).rounded())
        guard tick != lastTick else { return }
        lastTick = tick; task?.cancel(); request = UUID()
        let id = request
        if let cached = cache.object(forKey: NSNumber(value: tick)) { image = cached; actualTime = time; return }
        image = nil
        task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 70_000_000)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 360, height: 202)
                generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
                generator.requestedTimeToleranceAfter = generator.requestedTimeToleranceBefore
                let result = try await withTaskCancellationHandler {
                    try await generator.image(at: CMTime(seconds: time, preferredTimescale: 60_000))
                } onCancel: { generator.cancelAllCGImageGeneration() }
                try Task.checkCancellation()
                guard let self, self.request == id else { return }
                let image = NSImage(cgImage: result.image, size: .zero)
                self.cache.setObject(image, forKey: NSNumber(value: tick), cost: result.image.bytesPerRow * result.image.height)
                self.image = image; self.actualTime = result.actualTime.seconds
            } catch { /* A failed thumbnail must not interrupt the player. */ }
        }
    }
    func cancel() { request = UUID(); lastTick = nil; task?.cancel(); task = nil; image = nil }
}

struct EditingTimeline: View {
    @ObservedObject var editor: PlayerEditingState
    let sourceID: String
    @State private var thumbnails: [TimelineThumbnail] = []
    @StateObject private var hover = TimelineHoverLoader()
    @State private var hoverPosition: CGPoint?
    @State private var zoom: Double = 1
    @State private var center: Double = 0
    private var viewport: TimelineViewport { TimelineViewport(duration: max(0.001, editor.duration), zoom: zoom, center: center) }
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Label(frameClock(max(0, editor.rangeEnd - editor.rangeStart)), systemImage: "scissors")
                    .foregroundStyle(Theme.accent).monospacedDigit()
                Text("фрагмент").foregroundStyle(Theme.muted)
                Spacer()
                if zoom > 1 {
                    Button { center = max(viewport.length / 2, viewport.start) } label: { Image(systemName: "chevron.left") }
                        .disabled(viewport.start <= 0).help("Сдвинуть шкалу влево").accessibilityLabel("Сдвинуть шкалу влево")
                    Button { center = min(editor.duration - viewport.length / 2, viewport.end) } label: { Image(systemName: "chevron.right") }
                        .disabled(viewport.end >= editor.duration).help("Сдвинуть шкалу вправо").accessibilityLabel("Сдвинуть шкалу вправо")
                }
                Button { changeZoom(zoom / 2) } label: { Image(systemName: "minus.magnifyingglass") }.disabled(zoom <= 1).help("Уменьшить шкалу")
                Text("\(Int(zoom))×").monospacedDigit().foregroundStyle(Theme.muted).frame(width: 24)
                Button { changeZoom(zoom * 2) } label: { Image(systemName: "plus.magnifyingglass") }.disabled(zoom >= 16).help("Увеличить шкалу у позиции плеера")
                Button("Всё видео") { editor.selectAll(); changeZoom(1) }
            }.font(.system(size: 11)).buttonStyle(.borderless).controlSize(.small)
            GeometryReader { geometry in
                let width = max(1, geometry.size.width)
                let first = viewport.fraction(editor.rangeStart) * width
                let last = viewport.fraction(editor.rangeEnd) * width
                ZStack(alignment: .leading) {
                    HStack(spacing: 2) {
                        ForEach(0..<10, id: \.self) { index in
                            ZStack {
                                Theme.panel
                                if let image = thumbnails.first(where: { $0.id == index })?.image {
                                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                                } else { Image(systemName: "video").foregroundStyle(Theme.muted.opacity(0.5)) }
                            }.frame(width: max(1, (width - 18) / 10), height: 54).clipped()
                        }
                    }.clipShape(RoundedRectangle(cornerRadius: 5)).allowsHitTesting(false)
                    Rectangle().fill(.black.opacity(0.6)).frame(width: first, height: 54).allowsHitTesting(false)
                    Rectangle().fill(.black.opacity(0.6)).frame(width: max(0, width - last), height: 54).offset(x: last).allowsHitTesting(false)
                    RoundedRectangle(cornerRadius: 3).stroke(Theme.accent, lineWidth: 2)
                        .background(Theme.accent.opacity(0.1)).frame(width: max(1, last - first), height: 54).offset(x: first).allowsHitTesting(false)
                    Color.clear.contentShape(Rectangle()).frame(height: 54)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in editor.seek(viewport.time(fraction: value.location.x / width)) })
                        .accessibilityElement().accessibilityLabel("Позиция видео")
                        .accessibilityValue(frameClock(editor.currentTime))
                        .accessibilityAdjustableAction { direction in editor.stepFrames(direction == .increment ? 1 : -1) }
                    ForEach(editor.markers) { marker in
                        if marker.seconds >= viewport.start && marker.seconds <= viewport.end {
                            Image(systemName: "bookmark.fill").font(.system(size: 9)).foregroundStyle(.orange)
                                .position(x: viewport.fraction(marker.seconds) * width, y: 0).allowsHitTesting(false)
                        }
                    }
                    Rectangle().fill(.white).frame(width: 2, height: 66)
                        .overlay(alignment: .top) { Image(systemName: "arrowtriangle.down.fill").font(.system(size: 9)).offset(y: -3) }
                        .position(x: viewport.fraction(editor.currentTime) * width, y: 27).allowsHitTesting(false)
                    handle("Начало фрагмента", time: editor.rangeStart, width: width, start: true).position(x: first, y: 27)
                    handle("Конец фрагмента", time: editor.rangeEnd, width: width, start: false).position(x: last, y: 27)
                }.coordinateSpace(name: "Spy.EditingTimeline")
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hoverPosition = location
                            if let asset = editor.asset { hover.request(asset: asset, time: min(max(0, editor.duration - 0.0001), viewport.time(fraction: location.x / width))) }
                        case .ended: hoverPosition = nil; hover.cancel()
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if let position = hoverPosition {
                            VStack(spacing: 0) {
                                Group {
                                    if let image = hover.image { Image(nsImage: image).resizable().scaledToFit() }
                                    else { ProgressView().controlSize(.small) }
                                }.frame(width: 150, height: 84).background(.black)
                                Text(frameClock(hover.image == nil ? viewport.time(fraction: position.x / width) : hover.actualTime))
                                    .font(.system(size: 10, design: .monospaced)).padding(5).frame(maxWidth: .infinity)
                            }.frame(width: 150).background(Theme.panel).clipShape(RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
                                .shadow(color: .black.opacity(0.4), radius: 12, y: 5)
                                .offset(x: min(max(0, position.x - 75), max(0, width - 150)), y: -120).allowsHitTesting(false)
                        }
                    }
            }.frame(height: 54)
            HStack {
                ForEach(0..<5, id: \.self) { index in
                    if index > 0 { Spacer(minLength: 0) }
                    Text(viewport.length < 10 ? preciseClock(viewport.start + viewport.length * Double(index) / 4) : clockText(viewport.start + viewport.length * Double(index) / 4))
                }
            }.font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.muted)
            HStack(spacing: 8) {
                Text("I").foregroundStyle(Theme.accent)
                Text(frameClock(editor.rangeStart)).monospacedDigit()
                Text("—").foregroundStyle(Theme.muted)
                Text("O").foregroundStyle(Theme.accent)
                Text(frameClock(editor.rangeEnd)).monospacedDigit()
                Spacer()
                Button("Смотреть фрагмент") { editor.seek(editor.rangeStart, resume: true) }.buttonStyle(.borderless)
            }.font(.system(size: 10)).foregroundStyle(Theme.muted)
        }.disabled(editor.duration <= 0 || editor.isSaving)
            .task(id: sourceID + "|\(viewport.start)|\(viewport.end)") {
                hover.cancel(); thumbnails = []
                guard let asset = editor.asset, editor.duration > 0 else { return }
                do {
                    let value = try await TimelineThumbnailGenerator.generate(asset: asset, duration: editor.duration, count: 10, start: viewport.start, end: viewport.end)
                    try Task.checkCancellation(); thumbnails = value
                } catch { }
            }.onDisappear { hover.cancel() }
    }
    private func changeZoom(_ value: Double) { center = editor.currentTime; zoom = max(1, min(16, value)) }
    private func handle(_ title: String, time: Double, width: Double, start: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(Theme.accent)
            .overlay { Capsule().fill(.black.opacity(0.4)).frame(width: 2, height: 19) }
            .frame(width: 10, height: 62).padding(.horizontal, 7).contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("Spy.EditingTimeline")).onChanged { value in
                let selected = viewport.time(fraction: value.location.x / width)
                if start { editor.setStart(selected) } else { editor.setEnd(selected) }
            })
            .accessibilityElement().accessibilityLabel(title).accessibilityValue(frameClock(time))
            .accessibilityAdjustableAction { direction in
                let selected = time + (direction == .increment ? editor.frameDuration : -editor.frameDuration)
                if start { editor.setStart(selected) } else { editor.setEnd(selected) }
            }
    }
}

struct PreciseEditingPanel: View {
    @ObservedObject var editor: PlayerEditingState
    @State private var first = ""
    @State private var last = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("Точный монтаж", systemImage: "scissors").font(.headline)
            boundary("Начало", value: $first, start: true)
            boundary("Конец", value: $last, start: false)
            if let error { Text(error).foregroundStyle(Theme.danger).font(.caption) }
            HStack { Text("Фрагмент"); Spacer(); Text(frameClock(editor.rangeEnd - editor.rangeStart)).monospacedDigit().foregroundStyle(Theme.accent) }
            Divider()
            Text("← / → — один кадр · Shift — 10 кадров\nI / O — границы по текущему кадру · Пробел — пауза")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
        }.padding(20).frame(width: 410).background(Theme.panel).foregroundStyle(.white)
            .onAppear { sync() }
            .onChange(of: editor.rangeStart) { _, _ in sync() }.onChange(of: editor.rangeEnd) { _, _ in sync() }
    }
    private func sync() { first = frameClock(editor.rangeStart); last = frameClock(editor.rangeEnd) }
    private func boundary(_ title: String, value: Binding<String>, start: Bool) -> some View {
        HStack {
            Text(title).frame(width: 50, alignment: .leading)
            TextField("00:00.000", text: value).textFieldStyle(.roundedBorder).monospacedDigit().onSubmit { apply(value.wrappedValue, start: start) }
                .accessibilityLabel("Точное время: " + title)
            Button("Задать") { apply(value.wrappedValue, start: start) }
            Button(start ? "I · Здесь" : "O · Здесь") { if start { editor.setStartAtPlayhead() } else { editor.setEndAtPlayhead() } }
        }.font(.system(size: 11)).buttonStyle(.bordered).controlSize(.small)
    }
    private func apply(_ text: String, start: Bool) {
        let parts = text.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]),
              minutes.isFinite, seconds.isFinite, minutes >= 0, minutes.rounded() == minutes, seconds >= 0, seconds < 60,
              minutes * 60 + seconds <= editor.duration else { error = "Введите время в пределах видео: мм:сс.мс."; return }
        error = nil
        let time = minutes * 60 + seconds
        guard start ? time < editor.rangeEnd : time > editor.rangeStart else { error = "Начало должно быть раньше конца фрагмента."; return }
        if start { editor.setStart(time) } else { editor.setEnd(time) }
        sync()
    }
}
