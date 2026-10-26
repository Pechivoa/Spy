import SwiftUI

struct RecoveryNotice: View {
    @ObservedObject var model: AppModel
    var compact = false
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.counterclockwise.circle").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(compact ? "Есть незавершённая запись" : "Видео можно восстановить")
                    .font(.system(size: compact ? 10 : 13, weight: .semibold))
                if !compact {
                    Text("Остались записи, которые не успели сохраниться: \(model.recoveryFolders.count).")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
            }
            Spacer(minLength: 2)
            Button("Восстановить") {
                if let folder = model.recoveryFolders.last { Task { await model.recoverRecording(folder) } }
            }.buttonStyle(.bordered).controlSize(.small)
                .disabled(model.saving || model.busy || model.manualRecording)
        }
        .padding(compact ? 9 : 14)
        .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }
}
