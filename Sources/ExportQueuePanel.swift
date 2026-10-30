import SwiftUI
import AppKit

struct ExportQueueButton: View {
    @ObservedObject var queue: ExportQueueController
    var inspectionChanged: (Bool) -> Void = { _ in }
    @State private var open = false
    private var failed: Bool { queue.items.contains { $0.phase == .failed } }
    var body: some View {
        Button { open.toggle() } label: {
            Label(queue.pendingCount > 0 ? "\(queue.pendingCount)" : "Очередь", systemImage: failed ? "exclamationmark.triangle" : "list.bullet.rectangle")
                .foregroundStyle(failed ? Theme.danger : Color.primary)
        }.help("Очередь сохранения").accessibilityLabel("Очередь сохранения")
            .popover(isPresented: $open, arrowEdge: .bottom) { ExportQueuePanel(queue: queue).frame(width: 480, height: 450) }
            .onChange(of: open) { _, value in inspectionChanged(value) }
            .onDisappear { inspectionChanged(false) }
    }
}

struct ExportQueuePanel: View {
    @ObservedObject var queue: ExportQueueController
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Очередь сохранения", systemImage: "list.bullet.rectangle").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(queue.pendingCount) в очереди").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            if queue.restoredCount > 0 {
                HStack {
                    Text("Очередь сохранена. Можно продолжить.").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    Spacer()
                    Button { queue.resumeRestored() } label: {
                        Text("Продолжить все").font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .foregroundStyle(Theme.accentInk).background(Theme.accent, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).disabled(queue.pausing)
                }
            }
            if queue.items.contains(where: { $0.pending && $0.phase != .paused }) {
                Button(queue.pausing ? "Приостанавливаю…" : "Приостановить и оставить на потом") { Task { await queue.pauseAll() } }
                    .buttonStyle(.bordered).disabled(queue.pausing)
            }
            if queue.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "film.stack").font(.system(size: 28)).foregroundStyle(Theme.muted)
                    Text("Выберите фрагмент и нажмите «Сохранить».").foregroundStyle(Theme.muted).font(.system(size: 12))
                }.frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(queue.items) { item in
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Image(systemName: item.phase == .completed ? "checkmark.circle.fill" : item.phase == .failed ? "exclamationmark.triangle" : "film")
                                        .foregroundStyle(item.phase == .completed ? Theme.green : Theme.muted)
                                    Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                    Spacer(minLength: 8)
                                    if queue.canResume(item.id) {
                                        Button(item.phase == .failed ? "Повторить" : "Продолжить") { queue.resume(item.id) }
                                            .buttonStyle(.borderless).font(.system(size: 11))
                                    }
                                    if item.pending {
                                        Button { queue.cancel(item.id) } label: { Image(systemName: "xmark") }
                                            .buttonStyle(.borderless).help("Отменить сохранение")
                                            .accessibilityLabel("Отменить «" + item.title + "»").disabled(item.phase == .cancelling)
                                    } else if let result = item.result {
                                        Button("Показать") { NSWorkspace.shared.activateFileViewerSelecting([result]) }.buttonStyle(.borderless).font(.system(size: 11))
                                    }
                                }
                                HStack {
                                    Text(frameClock(item.range.start) + " — " + frameClock(item.range.end)).monospacedDigit()
                                    Spacer()
                                    Text(item.status)
                                }.font(.system(size: 10)).foregroundStyle(Theme.muted)
                                if item.phase == .running || item.phase == .cancelling { ProgressView(value: item.progress).tint(Theme.accent) }
                                if let error = item.error { Text(error).font(.system(size: 11)).foregroundStyle(Theme.danger).textSelection(.enabled) }
                                if let folder = item.retainedDirectory {
                                    HStack {
                                        Text("Данные задачи оставлены для повтора.").font(.system(size: 10)).foregroundStyle(Theme.muted)
                                        Button("Показать") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }.buttonStyle(.borderless).font(.system(size: 10))
                                    }
                                }
                                Divider().overlay(Theme.border)
                            }
                        }
                    }
                }.frame(maxHeight: .infinity)
            }
            HStack {
                Text("Незавершённые задачи сохраняются между запусками. После перезапуска можно продолжить или отменить их.")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Убрать завершённые") { queue.clearFinished() }.buttonStyle(.borderless).font(.system(size: 10))
                    .disabled(queue.items.allSatisfy(\.pending))
            }
        }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.panel)
            .foregroundStyle(.white).preferredColorScheme(.dark).tint(Theme.accent)
    }
}

struct RestoredExportNotice: View {
    @ObservedObject var queue: ExportQueueController
    let open: () -> Void
    var body: some View {
        if queue.restoredCount > 0 {
            HStack(spacing: 12) {
                Image(systemName: "list.bullet.rectangle").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Сохранённая очередь: \(queue.restoredCount)").font(.system(size: 13, weight: .medium))
                    Text("Исходники, границы и звук сохранены. Откройте очередь, чтобы продолжить.").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button("Открыть очередь", action: open).buttonStyle(.bordered)
            }.padding(15).background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

@MainActor extension AppModel {
    func showExportQueue() {
        guard !previewMode else { return }
        queueViewer.present(title: "Spy — Очередь сохранения", frameName: "Spy.ExportQueue",
            preferredSize: NSSize(width: 480, height: 560), minimumSize: NSSize(width: 400, height: 300), onClose: {}) {
                ExportQueuePanel(queue: exportQueue)
            }
    }
}
