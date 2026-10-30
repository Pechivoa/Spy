import SwiftUI
import AppKit

struct ShortcutCaptureSheet: View {
    let action: ShortcutAction
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var candidate: Shortcut?
    @State private var issue: String?
    @State private var monitor: Any?
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("Назначить горячую клавишу", systemImage: "keyboard").font(.system(size: 20, weight: .semibold))
            Text(action.title).font(.system(size: 13)).foregroundStyle(Theme.muted)
            VStack(spacing: 12) {
                Text(candidate?.label ?? "Нажмите сочетание…").font(.system(size: candidate == nil ? 17 : 28, weight: .semibold, design: .monospaced)).foregroundStyle(candidate == nil ? Theme.muted : .white)
                Text("Например: ⌥⌘S, ⌃⇧R или F10").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }.frame(maxWidth: .infinity).padding(.vertical, 30).background(Theme.panel, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(candidate == nil ? Theme.border : Theme.accent.opacity(0.5)))
            Text(issue ?? "Добавьте ⌘, ⌥ или ⌃ к обычной клавише. F-клавиши можно назначать отдельно; на Mac иногда нужно удерживать Fn. Esc — отмена.")
                .font(.system(size: 12)).foregroundStyle(issue == nil ? Theme.muted : Theme.accent).frame(minHeight: 44, alignment: .topLeading)
            HStack {
                Text("Сейчас: " + model.shortcuts[action].label).font(.system(size: 11)).foregroundStyle(Theme.muted)
                Spacer()
                Button("Отмена") { dismiss() }.buttonStyle(.bordered)
                Button("Сохранить") {
                    guard let candidate else { return }
                    do { try model.assignShortcut(candidate, to: action); dismiss() }
                    catch { issue = error.localizedDescription }
                }.buttonStyle(.borderedProminent).foregroundStyle(Theme.accentInk).disabled(candidate == nil || candidate?.validationError != nil)
            }
        }.padding(28).frame(width: 510).background(Theme.background).preferredColorScheme(.dark).tint(Theme.accent)
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard !event.isARepeat else { return nil }
                    if event.keyCode == 53 { dismiss(); return nil }
                    let value = Shortcut(event: event)
                    candidate = value; issue = value.validationError
                    return nil
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
                model.finishShortcutEdit()
            }
    }
}

struct JournalView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var journal: EventJournal
    @State private var filter = "all"
    @State private var search = ""
    private var selected: [LogEntry] {
        journal.entries.filter {
            (filter == "all" || $0.level.rawValue == filter) &&
            (search.isEmpty || ($0.topic + " " + $0.detail).localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                countChip("Событий", count: journal.entries.count, color: Theme.muted)
                countChip("Ошибок", count: journal.errorCount, color: Theme.accent)
                countChip("Предупреждений", count: journal.entries.filter { $0.level == .warning }.count, color: .orange)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 17) {
                HStack {
                    Label("События приложения", systemImage: "text.document").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Button { model.copyJournal(entries: selected) } label: { Label("Копировать", systemImage: "doc.on.doc") }.buttonStyle(.bordered).disabled(selected.isEmpty)
                    Button { model.saveJournal(entries: selected) } label: { Label("Сохранить TXT", systemImage: "square.and.arrow.down") }.buttonStyle(.borderedProminent).foregroundStyle(Theme.accentInk).disabled(selected.isEmpty)
                }
                HStack(spacing: 14) {
                    Picker("Уровень", selection: $filter) {
                        Text("Все события").tag("all")
                        ForEach(LogLevel.allCases) { Text($0.title).tag($0.rawValue) }
                    }.labelsHidden().frame(width: 190)
                    TextField("Поиск по журналу", text: $search).textFieldStyle(.roundedBorder)
                    Text("\(selected.count) записей").font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
                Divider().overlay(Theme.border)
                ScrollView {
                    if selected.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: journal.entries.isEmpty ? "checkmark.shield" : "magnifyingglass").font(.system(size: 30, weight: .light)).foregroundStyle(Theme.muted)
                            Text(journal.entries.isEmpty ? "Событий пока нет" : "По этому фильтру записей нет").font(.system(size: 13)).foregroundStyle(Theme.muted)
                        }.frame(maxWidth: .infinity).padding(.top, 95)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(selected.reversed()) { entry in
                                VStack(alignment: .leading, spacing: 9) {
                                    HStack(spacing: 8) {
                                        Circle().fill(color(entry.level)).frame(width: 6, height: 6)
                                        Text(entry.level.title.uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.6).foregroundStyle(color(entry.level))
                                        Text(entry.topic).font(.system(size: 12, weight: .semibold))
                                        Spacer()
                                        Text(entry.timestamp).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
                                    }
                                    Text(entry.detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.white.opacity(0.72)).lineSpacing(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }.padding(14).background(Color.black.opacity(0.17), in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(entry.level == .error ? Theme.accent.opacity(0.16) : Theme.border))
                            }
                        }
                    }
                }.frame(height: 410)
                HStack {
                    Image(systemName: "internaldrive")
                    Text("Последние \(journal.capacity) событий сохраняются между запусками.")
                    Spacer()
                    Text("Экспортируется текущий фильтр.")
                }.font(.system(size: 10)).foregroundStyle(Theme.muted)
            }.padding(20).background(Theme.panel, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border))
            if let issue = journal.persistenceError {
                Text("Не удалось сохранить журнал на диске: " + issue).font(.system(size: 12)).foregroundStyle(Theme.accent)
            }
        }
    }
    private func color(_ level: LogLevel) -> Color {
        switch level { case .error: return Theme.accent; case .warning: return .orange; case .info: return Theme.green }
    }
    private func countChip(_ title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).foregroundStyle(Theme.muted)
            Text("\(count)").fontWeight(.semibold)
        }.font(.system(size: 12)).padding(.horizontal, 15).padding(.vertical, 11).background(Theme.panel, in: Capsule()).overlay(Capsule().stroke(Theme.border))
    }
}
