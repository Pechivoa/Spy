import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DiagnosticsView: View {
    @ObservedObject var controller: RecordingDiagnostics
    let onRun: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.shield").font(.title2).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Проверить запись").font(.headline)
                    Text("Кадры видео и звук каждого выбранного источника.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
                Spacer()
                if controller.running {
                    Button("Отменить") { controller.cancel() }
                } else {
                    Button("Проверить", action: onRun).buttonStyle(.borderedProminent).tint(Theme.accent)
                }
            }
            if controller.running {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text(controller.progress).font(.caption).foregroundStyle(Theme.muted)
                }
            } else if controller.results.isEmpty {
                Text("При включённой записи Spy проверит последние 5 секунд буфера. При выключенной — создаст короткий временный фрагмент и удалит его после проверки. Для проверки звука включите его в другом приложении и произнесите несколько слов.")
                    .font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            if !controller.results.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(controller.results) { result in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: icon(result.status)).foregroundStyle(color(result.status)).frame(width: 16)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(result.title).font(.subheadline.weight(.medium))
                                    Spacer()
                                    Text(result.status.title).font(.caption).foregroundStyle(color(result.status))
                                }
                                Text(result.detail).font(.caption).foregroundStyle(Theme.muted)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                HStack(spacing: 12) {
                    if let checkedAt = controller.checkedAt {
                        Text(checkedAt.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(controller.reportText, forType: .string)
                    } label: { Label("Копировать", systemImage: "doc.on.doc") }
                    Button { saveReport() } label: { Label("Сохранить TXT", systemImage: "square.and.arrow.down") }
                }.controlSize(.small)
            }
        }
        .padding(16)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
    }

    private func icon(_ status: RecordingDiagnosticStatus) -> String {
        switch status {
        case .passed: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        case .notSelected: return "minus.circle"
        }
    }

    private func color(_ status: RecordingDiagnosticStatus) -> Color {
        switch status {
        case .passed: return Theme.green
        case .warning: return .orange
        case .failed: return Theme.danger
        case .notSelected: return Theme.muted
        }
    }

    private func saveReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Spy-проверка-записи.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try controller.reportText.write(to: url, atomically: true, encoding: .utf8) }
        catch { NSAlert(error: error).runModal() }
    }
}
