import SwiftUI
import AppKit

struct CaptureTuningSettingsView: View {
    @ObservedObject var settings: CaptureTuningSettings
    var locked: Bool
    var previewLoader: (@MainActor () async throws -> NSImage)? = nil
    @State private var previewImage: NSImage?
    @State private var loadingPreview = false
    @State private var previewError: String?
    @State private var hevcAvailable: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if locked {
                Label("Остановите запись, чтобы изменить формат, лимит кэша и приватные области.", systemImage: "lock")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let issue = settings.validationIssue ?? settings.persistenceIssue {
                HStack {
                    Text(issue).font(.system(size: 11)).foregroundStyle(.red)
                    Spacer()
                    Button("Сбросить раздел") { settings.reset() }.disabled(locked)
                }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Видеоформат", selection: $settings.codec) {
                        ForEach(CaptureVideoCodec.allCases) { codec in
                            Text(codec.title).tag(codec).disabled(codec == .hevc && hevcAvailable == false)
                        }
                    }
                    Toggle("Задать битрейт вручную", isOn: Binding(get: { settings.bitrateMbps > 0 }, set: { settings.bitrateMbps = $0 ? 10 : 0 }))
                    if settings.bitrateMbps > 0 {
                        Stepper(value: $settings.bitrateMbps, in: 1...80, step: 0.5) {
                            Text("Средний битрейт: \(settings.bitrateMbps, specifier: "%.1f") Мбит/с").monospacedDigit()
                        }
                    } else {
                        Text("Авто: используется битрейт выбранного качества.").foregroundStyle(.secondary)
                    }
                    Text(hevcAvailable == false
                         ? "Аппаратный HEVC недоступен на этом Mac. H.264 остаётся доступен."
                         : "HEVC использует аппаратное кодирование. Совместимость внешних плееров зависит от поддержки HEVC; H.264 удобнее для обмена.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.font(.system(size: 12)).padding(8)
            } label: { Label("Формат и размер видео", systemImage: "film") }.disabled(locked)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Ограничить буфер по размеру", isOn: Binding(get: { settings.cacheLimitGB > 0 }, set: { settings.cacheLimitGB = $0 ? 2 : 0 }))
                    if settings.cacheLimitGB > 0 {
                        Stepper(value: $settings.cacheLimitGB, in: 0.25...500, step: 0.25) {
                            Text("Лимит: \(settings.cacheLimitGB, specifier: "%.2f") ГБ").monospacedDigit()
                        }
                    }
                    Text("Старые сегменты удаляются, когда достигнут лимит времени или размера. Текущие сегменты, закреплённый предпросмотр и ручная запись могут занимать дополнительное место.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.font(.system(size: 12)).padding(8)
            } label: { Label("Размер кэша повтора", systemImage: "internaldrive") }.disabled(locked)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Закрывать выбранные области в новых записях", isOn: $settings.masksEnabled).disabled(locked)
                    if settings.masksEnabled && settings.masks.isEmpty {
                        Text("Областей пока нет. Добавьте прямоугольник, чтобы скрыть часть кадра.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text(previewImage == nil ? "Схема кадра" : "Кадр для настройки областей")
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        if let previewLoader {
                            Button {
                                loadingPreview = true; previewError = nil
                                Task { @MainActor in
                                    do {
                                        let image = try await previewLoader()
                                        guard image.size.width > 0, image.size.height > 0 else { throw CaptureTuningError.invalid("Источник вернул пустое изображение.") }
                                        previewImage = image
                                    } catch { previewError = error.localizedDescription }
                                    loadingPreview = false
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    if loadingPreview { ProgressView().controlSize(.small) }
                                    else { Image(systemName: "arrow.clockwise") }
                                    Text(loadingPreview ? "Получаю изображение…" : "Обновить изображение экрана")
                                }
                            }.controlSize(.small).disabled(loadingPreview)
                        }
                    }
                    if let previewError { Text(previewError).font(.system(size: 10)).foregroundStyle(.red) }
                    RecordingMaskEditor(masks: $settings.masks, image: previewImage,
                        editable: settings.masksEnabled && !locked)
                    HStack {
                        Button { settings.addMask() } label: { Label("Добавить область", systemImage: "plus") }
                            .disabled(locked || !settings.masksEnabled || settings.masks.count >= 16)
                        Spacer()
                        Text("\(settings.masks.count) / 16").monospacedDigit().foregroundStyle(.secondary)
                    }.font(.system(size: 11))
                    Text("Потяните по кадру, чтобы закрыть прямоугольник. Координаты относительны выбранному экрану или окну. Чёрные области применяются до кодирования; старые видео не меняются.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("После смены источника или размера окна обновите изображение и проверьте расположение областей.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if previewImage == nil {
                        Text("Для точной настройки получите изображение источника. Пока показана только схема, а не ваш экран.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }.font(.system(size: 12)).padding(8)
            } label: { Label("Приватные области", systemImage: "rectangle.dashed.badge.record") }
        }
        .task { hevcAvailable = CaptureEncodingOptions.hardwareHEVCAvailable() }
    }
}

struct RecordingMaskEditor: View {
    @Binding var masks: [RecordingMask]
    var image: NSImage?
    var editable = true
    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?

    private var aspect: CGFloat {
        guard let image, image.size.width > 0, image.size.height > 0 else { return 16 / 9 }
        return image.size.width / image.size.height
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    if let image {
                        Image(nsImage: image).resizable().interpolation(.high)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    } else {
                        illustrativeFrame
                    }
                    ForEach(masks) { mask in
                        let rect = normalizedRect(mask, size: geometry.size)
                        Rectangle().fill(.black.opacity(0.96))
                            .overlay(alignment: .topLeading) {
                                Text(mask.title).font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.white).lineLimit(1).padding(4)
                            }
                            .overlay(Rectangle().stroke(Color.purple, lineWidth: 1.5))
                            .frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                            .allowsHitTesting(false)
                    }
                    if let dragStart, let dragEnd {
                        let rect = dragRect(dragStart, dragEnd, size: geometry.size)
                        Rectangle().fill(.black.opacity(0.8)).overlay(Rectangle().stroke(.white, style: StrokeStyle(lineWidth: 1, dash: [4])))
                            .frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY).allowsHitTesting(false)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped().contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        guard editable, masks.count < 16 else { return }
                        if dragStart == nil { dragStart = value.startLocation }
                        dragEnd = value.location
                    }
                    .onEnded { value in
                        defer { dragStart = nil; dragEnd = nil }
                        guard editable, masks.count < 16, geometry.size.width > 0, geometry.size.height > 0 else { return }
                        let rect = dragRect(dragStart ?? value.startLocation, value.location, size: geometry.size)
                        guard rect.width >= 4, rect.height >= 4 else { return }
                        masks.append(RecordingMask(title: "Область \(masks.count + 1)",
                            x: rect.minX / geometry.size.width, y: rect.minY / geometry.size.height,
                            width: rect.width / geometry.size.width, height: rect.height / geometry.size.height))
                    })
            }
            .aspectRatio(aspect, contentMode: .fit)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.gray.opacity(0.4)))
            .accessibilityLabel("Редактор приватных областей: потяните по изображению для добавления прямоугольника")
            ForEach($masks) { $mask in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        TextField("Название области", text: $mask.title).textFieldStyle(.roundedBorder)
                        Button { masks.removeAll { $0.id == mask.id } } label: { Image(systemName: "trash") }
                            .help("Удалить область")
                    }
                    HStack(spacing: 10) {
                        percentControl("X", value: mask.x, range: 0...max(0, 1 - mask.width)) { mask.x = $0 }
                        percentControl("Y", value: mask.y, range: 0...max(0, 1 - mask.height)) { mask.y = $0 }
                        percentControl("Ш", value: mask.width, range: 0.005...max(0.005, 1 - mask.x)) { mask.width = $0 }
                        percentControl("В", value: mask.height, range: 0.005...max(0.005, 1 - mask.y)) { mask.height = $0 }
                    }
                }.font(.system(size: 10)).disabled(!editable)
            }
        }
    }

    private var illustrativeFrame: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [.indigo.opacity(0.7), .blue.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 5) { ForEach(0..<3) { _ in Circle().fill(.white.opacity(0.35)).frame(width: 6, height: 6) } }
                RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.12)).frame(height: 10)
                RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.1)).frame(maxWidth: 150).frame(height: 10)
                Spacer()
                Text("СХЕМА КАДРА").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            }.padding(16)
        }
    }

    private func percentControl(_ label: String, value: Double, range: ClosedRange<Double>, set: @escaping (Double) -> Void) -> some View {
        Stepper(value: Binding(get: { min(range.upperBound, max(range.lowerBound, value)) }, set: set), in: range, step: 0.01) {
            Text("\(label): \(Int((min(1, max(0, value.isFinite ? value : 0)) * 100).rounded()))%").monospacedDigit().frame(minWidth: 46, alignment: .leading)
        }
    }
    private func normalizedRect(_ mask: RecordingMask, size: CGSize) -> CGRect {
        let x = mask.x.isFinite ? min(1, max(0, mask.x)) : 0
        let y = mask.y.isFinite ? min(1, max(0, mask.y)) : 0
        let width = mask.width.isFinite ? min(1 - x, max(0, mask.width)) : 0
        let height = mask.height.isFinite ? min(1 - y, max(0, mask.height)) : 0
        return CGRect(x: x * size.width, y: y * size.height, width: width * size.width, height: height * size.height)
    }
    private func dragRect(_ start: CGPoint, _ end: CGPoint, size: CGSize) -> CGRect {
        let x1 = min(size.width, max(0, start.x)), y1 = min(size.height, max(0, start.y))
        let x2 = min(size.width, max(0, end.x)), y2 = min(size.height, max(0, end.y))
        return CGRect(x: min(x1, x2), y: min(y1, y2), width: abs(x1 - x2), height: abs(y1 - y2))
    }
}
