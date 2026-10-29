import SwiftUI
import AppKit

struct RecordedSession: Codable, Identifiable {
    struct Event: Codable, Identifiable {
        var id = UUID()
        var date = Date()
        var kind: String
        var title: String
    }
    let id: UUID
    let began: Date
    var ended: Date?
    var lastSeen: Date? = nil
    let source: String
    var events: [Event] = []
    var videos: [URL] = []
    var recoveryFolders: [URL] = []
}

@MainActor final class SessionHistory: ObservableObject {
    @Published private(set) var sessions: [RecordedSession] = []
    @Published private(set) var persistenceIssue: String?
    private let url: URL
    private(set) var activeID: UUID?
    init(url: URL) {
        self.url = url
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                guard size <= 16_000_000 else { throw SpyError.message("Файл истории слишком большой. Исходник оставлен на месте.") }
                sessions = Array(try JSONDecoder().decode([RecordedSession].self, from: Data(contentsOf: url)).suffix(500))
            }
            // An entry left open by a previous process represents an interrupted session.
            if let i = sessions.indices.last, sessions[i].ended == nil {
                let end = sessions[i].lastSeen ?? sessions[i].events.last?.date ?? sessions[i].began
                sessions[i].ended = end
                sessions[i].events.append(.init(date: end, kind: "failure", title: "Предыдущий запуск завершился без штатного закрытия"))
                persist()
            }
        } catch { persistenceIssue = error.localizedDescription }
    }
    func begin(id: UUID, source: String, at date: Date = Date()) {
        guard activeID != id else { return }
        if activeID != nil { end(reason: "Новая сессия", at: date) }
        activeID = id
        sessions.append(RecordedSession(id: id, began: date, source: source, events: [.init(date: date, kind: "start", title: "Запись началась")]))
        if sessions.count > 500 { sessions.removeFirst(sessions.count - 500) }
        persist()
    }
    func event(_ kind: String, _ title: String, at date: Date = Date()) {
        guard let i = sessions.lastIndex(where: { $0.id == activeID }) else { return }
        sessions[i].events.append(.init(date: date, kind: kind, title: title))
        if sessions[i].events.count > 500 { sessions[i].events.removeFirst(sessions[i].events.count - 500) }
        persist()
    }
    func end(reason: String, at date: Date = Date()) {
        guard let i = sessions.lastIndex(where: { $0.id == activeID }) else { return }
        sessions[i].events.append(.init(date: date, kind: "stop", title: reason)); sessions[i].ended = date; sessions[i].lastSeen = date
        activeID = nil; persist()
    }
    func touch(at date: Date = Date()) {
        guard let i = sessions.lastIndex(where: { $0.id == activeID }), date.timeIntervalSince(sessions[i].lastSeen ?? sessions[i].began) >= 30 else { return }
        sessions[i].lastSeen = date; persist()
    }
    func saved(_ video: URL, session: UUID? = nil) {
        let selected = session ?? activeID ?? sessions.last?.id
        guard let i = sessions.lastIndex(where: { $0.id == selected }) else { return }
        let normalized = video.spyFileURL
        if !sessions[i].videos.contains(where: { $0.spyFileURL.path == normalized.path }) { sessions[i].videos.append(normalized); if sessions[i].videos.count > 1000 { sessions[i].videos.removeFirst() }; persist() }
    }
    func copied(_ video: URL, from source: URL) {
        guard let session = sessions.last(where: { $0.videos.contains(where: { $0.spyFileURL.path == source.spyFileURL.path }) }) else { return }
        saved(video, session: session.id)
    }
    func retain(_ folders: [URL], session: UUID?) {
        guard let i = sessions.lastIndex(where: { $0.id == session }) else { return }
        sessions[i].recoveryFolders = Array(Set(sessions[i].recoveryFolders + folders)); persist()
    }
    private func persist() {
        // A damaged history is left untouched for manual recovery.
        guard persistenceIssue == nil else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(sessions).write(to: url, options: .atomic)
        } catch { persistenceIssue = error.localizedDescription }
    }
}

struct SessionHistoryView: View {
    @ObservedObject var history: SessionHistory
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Записи по времени", systemImage: "clock.arrow.circlepath").font(.title2.bold())
            Text("Новые записи, паузы и сбои. Нажмите сохранённое видео, чтобы открыть его.").font(.caption).foregroundStyle(Theme.muted)
            if let issue = history.persistenceIssue { Text("История недоступна: " + issue).foregroundStyle(.orange) }
            if history.sessions.isEmpty { Text("Здесь появится следующая сессия записи.").foregroundStyle(Theme.muted) }
            ForEach(history.sessions.reversed()) { session in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(session.began.formatted(date: .abbreviated, time: .standard)).font(.headline)
                        Spacer()
                        Text(session.ended == nil ? "Записывается" : "Завершена").foregroundStyle(session.ended == nil ? Theme.green : Theme.muted)
                    }
                    Text(session.source).font(.caption).foregroundStyle(Theme.muted)
                    if let index = history.sessions.firstIndex(where: { $0.id == session.id }), index > 0,
                       let previousEnd = history.sessions[index - 1].ended,
                       session.began.timeIntervalSince(previousEnd) > 1 {
                        Label("Между сессиями: " + preciseClock(session.began.timeIntervalSince(previousEnd)) + " без записи", systemImage: "pause.circle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    GeometryReader { geo in
                        let end = session.ended ?? Date()
                        let total = max(1, end.timeIntervalSince(session.began))
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.accent.opacity(0.28))
                            ForEach(session.events.filter { $0.kind == "pause" || $0.kind == "failure" }) { event in
                                let resumed = session.events.first { $0.date > event.date && ($0.kind == "resume" || $0.kind == "stop") }?.date ?? end
                                RoundedRectangle(cornerRadius: 3).fill(event.kind == "failure" ? Color.red : Color.orange)
                                    .frame(width: max(3, geo.size.width * max(0, resumed.timeIntervalSince(event.date)) / total))
                                    .offset(x: geo.size.width * max(0, event.date.timeIntervalSince(session.began)) / total)
                            }
                        }
                    }.frame(height: 8)
                    DisclosureGroup("События · \(session.events.count)") {
                        ForEach(session.events) { event in
                            HStack(alignment: .top) {
                                Text(event.date.formatted(date: .omitted, time: .standard)).monospacedDigit().frame(width: 80, alignment: .leading)
                                Text(event.title).frame(maxWidth: .infinity, alignment: .leading)
                            }.font(.caption).foregroundStyle(event.kind == "failure" ? .orange : Theme.muted)
                        }
                    }
                    ForEach(session.videos, id: \.self) { url in
                        let exists = FileManager.default.fileExists(atPath: url.path)
                        HStack {
                            Button(url.lastPathComponent) {
                                if let clip = model.clips.first(where: { $0.url == url }) { model.selectedClip = clip }
                                else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            }.disabled(!exists)
                            if !exists { Text("Удалено или перемещено").font(.caption).foregroundStyle(Theme.muted) }
                        }
                    }
                    if session.recoveryFolders.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                        Button("Посмотреть готовые сегменты") { model.section = 6 }
                    }
                }.padding(16).background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}
