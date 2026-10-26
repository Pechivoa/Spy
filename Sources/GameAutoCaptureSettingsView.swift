import SwiftUI

struct GameAutoCaptureSettingsView: View {
    @ObservedObject var controller: GameAutoCaptureController

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("Автозапуск для игр", systemImage: "gamecontroller")
                .font(.system(size: 18, weight: .semibold))
            Toggle("Включать повтор при запуске выбранной игры", isOn: $controller.enabled)
                .disabled(!controller.configurationReadable)
            Text("Работает, пока Spy открыт. После закрытия последней выбранной игры буфер автоматически сохранится, а повтор остановится. Повтор, включённый вами, продолжит работать.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).lineSpacing(3)
            Label(controller.status, systemImage: controller.ownsReplay ? "record.circle" : "clock")
                .font(.system(size: 12)).foregroundStyle(controller.ownsReplay ? Theme.green : Theme.muted)
            if let error = controller.error {
                Text(error).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled)
                if controller.configurationReadable {
                    Button("Повторить попытку") { controller.retry() }.buttonStyle(.bordered)
                } else {
                    Button("Сбросить повреждённый список игр", role: .destructive) { controller.resetUnreadableApplications() }
                        .buttonStyle(.bordered)
                }
            }
            Divider().overlay(Theme.border)
            HStack(spacing: 10) {
                Menu("Добавить открытое приложение") {
                    let choices = controller.runningApplications.filter { !controller.selectedBundleIDs.contains($0.id) }
                    if choices.isEmpty { Text("Нет доступных приложений") }
                    ForEach(choices) { application in
                        Button(application.name) { controller.add(application) }
                    }
                }
                Button { controller.refreshRunningApplications() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Обновить список открытых приложений")
                Button("Выбрать .app…") { controller.chooseApplications() }
            }.buttonStyle(.bordered).disabled(!controller.configurationReadable)
            if controller.selectedApplications.isEmpty {
                Text("Добавьте .app игры. Переключение между окнами не влияет на запись.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            ForEach(controller.selectedApplications) { application in
                HStack(spacing: 12) {
                    Image(systemName: "gamecontroller.fill").foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(application.name).font(.system(size: 13, weight: .medium))
                        Text(application.bundleID).font(.system(size: 10)).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 8)
                    if controller.activeApplications.contains(where: { $0.id == application.id }) {
                        Text("Запущено").font(.system(size: 11)).foregroundStyle(Theme.green)
                    }
                    Button { controller.remove(application) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.bordered).help("Убрать из автозапуска")
                }.padding(12).background(Color.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
            }
            Text("После ручной остановки автозапуск ждёт закрытия всех выбранных игр. Если доступ к записи ещё не выдан, включите повтор вручную один раз.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(3)
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border))
        .onAppear { controller.refreshRunningApplications() }
    }
}
