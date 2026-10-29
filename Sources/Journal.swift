import Foundation
import Combine

enum SpyDates {
    static let timeZone = TimeZone(identifier: "Asia/Novosibirsk")!
}

enum LogLevel: String, Codable, CaseIterable, Identifiable {
    case info, warning, error
    var id: String { rawValue }
    var title: String {
        switch self { case .info: return "Информация"; case .warning: return "Предупреждение"; case .error: return "Ошибка" }
    }
}

struct LogEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    let level: LogLevel
    let topic: String
    let detail: String
    var timestamp: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = SpyDates.timeZone
        formatter.dateFormat = "dd.MM.yyyy HH:mm:ss"
        return formatter.string(from: date)
    }
    var line: String { "[\(timestamp)] [\(level.rawValue.uppercased())] \(topic)\n\(detail)" }
}

@MainActor final class EventJournal: ObservableObject {
    @Published private(set) var entries: [LogEntry] = []
    @Published private(set) var persistenceError: String?
    let fileURL: URL
    let capacity: Int
    var errorCount: Int { entries.filter { $0.level == .error }.count }
    init(fileURL: URL, capacity: Int = 1000) {
        self.fileURL = fileURL; self.capacity = max(1, capacity)
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                entries = Array(try JSONDecoder().decode([LogEntry].self, from: Data(contentsOf: fileURL)).suffix(self.capacity))
            }
        } catch {
            persistenceError = error.localizedDescription
            entries = [LogEntry(level: .warning, topic: "Журнал", detail: "Не удалось прочитать предыдущий журнал. " + describeError(error))]
        }
    }
    func record(_ level: LogLevel, _ topic: String, _ detail: String) {
        entries.append(LogEntry(level: level, topic: topic, detail: detail))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        persist()
    }
    private func persist() {
        do { try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic); persistenceError = nil }
        catch { persistenceError = error.localizedDescription }
    }
    func text(entries selected: [LogEntry]? = nil) -> String {
        let values = (selected ?? entries).sorted { $0.date < $1.date }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.13.0"
        return "Spy \(version) — журнал событий\nmacOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\nЧасовой пояс: \(SpyDates.timeZone.identifier)\nСобытий: \(values.count)\n\n" + values.map(\.line).joined(separator: "\n\n") + "\n"
    }
    func export(to url: URL, entries selected: [LogEntry]? = nil) throws {
        try text(entries: selected).write(to: url, atomically: true, encoding: .utf8)
    }
}

func describeError(_ error: Error, depth: Int = 0) -> String {
    let value = error as NSError
    var text = value.localizedDescription + "\nДомен: \(value.domain) · Код: \(value.code)"
    if let reason = value.localizedFailureReason { text += "\nПричина: " + reason }
    if let suggestion = value.localizedRecoverySuggestion { text += "\nРекомендация: " + suggestion }
    if depth < 3, let underlying = value.userInfo[NSUnderlyingErrorKey] as? Error { text += "\nВложенная ошибка: " + describeError(underlying, depth: depth + 1) }
    return text
}
