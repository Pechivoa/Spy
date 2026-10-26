import AppKit
import Carbon

@MainActor enum SettingsTests {
    static func run(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let suiteName = "Spy.SettingsTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var bindings = ShortcutBindings()
        let custom = Shortcut(keyCode: 40, modifiers: UInt32(controlKey | optionKey), keyLabel: "K")
        bindings.save = custom
        try bindings.validate()
        bindings.persist(to: defaults)
        try SelfTest.require(ShortcutBindings.load(from: defaults) == bindings, "Custom shortcuts persist across reload")
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option, .capsLock], timestamp: 0, windowNumber: 0, context: nil, characters: "ы", charactersIgnoringModifiers: "ы", isARepeat: false, keyCode: 1)!
        let captured = Shortcut(event: event)
        try SelfTest.require(captured.sameCombination(as: .saveDefault) && captured.label == "⌥⌘S", "Capture uses physical key and ignores Caps Lock")
        let bareLetter = Shortcut(keyCode: 0, modifiers: 0, keyLabel: "A")
        let function = Shortcut(keyCode: 109, modifiers: 0, keyLabel: "F10")
        try SelfTest.require(bareLetter.validationError != nil && function.validationError == nil, "Ordinary keys need modifiers; function keys can stand alone")
        let model = AppModel(preview: true)
        defer { try? FileManager.default.removeItem(at: model.libraryURL.deletingLastPathComponent()) }
        try model.assignShortcut(custom, to: .save)
        do { try model.assignShortcut(custom, to: .toggle); throw SpyError.message("TEST FAILED: duplicate shortcut accepted") }
        catch { try SelfTest.require(model.shortcuts.save == custom && model.shortcuts.toggle == .toggleDefault, "Duplicate assignment preserves both previous shortcuts") }
        model.beginShortcutEdit(.save)
        model.finishShortcutEdit()
        try SelfTest.require(model.editingShortcut == nil && model.hotkeyAvailable, "Cancelling key capture restores availability")
        // Real Carbon registration and replacement, using uncommon bindings so
        // the installed app can keep its normal shortcuts during these tests.
        var testing = ShortcutBindings()
        testing.save = Shortcut(keyCode: 105, modifiers: UInt32(cmdKey | controlKey | optionKey), keyLabel: "F13")
        testing.toggle = Shortcut(keyCode: 107, modifiers: UInt32(cmdKey | controlKey | optionKey), keyLabel: "F14")
        for (action, code) in zip(ShortcutAction.quick + [.manual, .preview, .marker], [UInt32(18), 19, 20, 21, 23, 25, 26]) {
            testing[action] = Shortcut(keyCode: code, modifiers: UInt32(cmdKey | controlKey | optionKey), keyLabel: Shortcut.keyNames[code]!)
        }
        let legacy = try JSONEncoder().encode(["save": ShortcutBindings.quickDefault(18), "toggle": Shortcut.toggleDefault])
        let migrated = try JSONDecoder().decode(ShortcutBindings.self, from: legacy)
        var seven = ShortcutBindings()
        seven.save = .previewDefault; seven.manual = .markerDefault
        var rawSeven = try JSONSerialization.jsonObject(with: JSONEncoder().encode(seven)) as! [String: Any]
        rawSeven.removeValue(forKey: "preview"); rawSeven.removeValue(forKey: "marker")
        let nine = try JSONDecoder().decode(ShortcutBindings.self, from: JSONSerialization.data(withJSONObject: rawSeven))
        try nine.validate()
        try SelfTest.require(nine.save == .previewDefault && nine.manual == .markerDefault &&
                             !nine.preview.sameCombination(as: nine.save) && !nine.marker.sameCombination(as: nine.manual),
                             "Nine-action migration preserves existing bindings and relocates only colliding new defaults")
        try migrated.validate()
        try SelfTest.require(migrated.save == ShortcutBindings.quickDefault(18) && !migrated.quick30.sameCombination(as: migrated.save), "1.2 shortcuts migrate without overriding custom bindings")
        var oldSix = ShortcutBindings(); oldSix.save = oldSix.manual
        var rawOldSix = try JSONSerialization.jsonObject(with: JSONEncoder().encode(oldSix)) as! [String: Any]
        rawOldSix.removeValue(forKey: "manual")
        let migratedSeven = try JSONDecoder().decode(ShortcutBindings.self, from: JSONSerialization.data(withJSONObject: rawOldSix))
        try migratedSeven.validate()
        try SelfTest.require(migratedSeven.save == oldSix.save && !migratedSeven.manual.sameCombination(as: oldSix.save), "1.3 six-key migration preserves custom manual-key collision")
        var triggered: [UInt32] = []
        let keys = HotKeys(bindings: testing) { triggered.append($0) }
        try SelfTest.require(keys.registered, "Carbon registers all seven custom shortcuts: \(keys.registrationError ?? "")")
        var dispatched: EventRef?
        try SelfTest.require(CreateEvent(kCFAllocatorDefault, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, EventAttributes(kEventAttributeUserEvent), &dispatched) == noErr, "Create app-local hotkey event")
        guard let dispatched else { throw SpyError.message("TEST FAILED: missing hotkey event") }
        for action in ShortcutAction.allCases {
            var id = EventHotKeyID(signature: 0x5350594B, id: action.rawValue)
            let parameter = SetEventParameter(dispatched, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &id)
            try SelfTest.require(parameter == noErr && SendEventToEventTarget(dispatched, GetApplicationEventTarget()) == noErr, "Carbon dispatch reaches action " + action.title)
        }
        try SelfTest.require(triggered == ShortcutAction.allCases.map(\.rawValue), "All seven action IDs dispatched")
        try SelfTest.require(ShortcutAction.quick.map { $0.seconds! } == [30, 60, 300, 600], "Quick shortcuts request the exact duration")
        ReleaseEvent(dispatched)
        keys.suspend()
        try SelfTest.require(keys.suspended && !keys.registered, "Capture suspends active global shortcuts")
        try keys.resume()
        try SelfTest.require(keys.registered, "Capture cancellation restores global shortcuts")
        var blocking = ShortcutBindings(save: Shortcut(keyCode: 113, modifiers: UInt32(cmdKey | controlKey | optionKey), keyLabel: "F15"), toggle: Shortcut(keyCode: 106, modifiers: UInt32(cmdKey | controlKey | optionKey), keyLabel: "F16"))
        for (action, code) in zip(ShortcutAction.quick + [.manual, .preview, .marker], [UInt32(18), 19, 20, 21, 23, 25, 26]) {
            blocking[action] = Shortcut(keyCode: code, modifiers: UInt32(cmdKey | controlKey | optionKey | shiftKey), keyLabel: Shortcut.keyNames[code]!)
        }
        let blocker = HotKeys(bindings: blocking) { _ in }
        try SelfTest.require(blocker.registered, "Reserved test bindings registered")
        var conflicting = testing; conflicting.save = blocker.bindings.save
        do { try keys.configure(conflicting); throw SpyError.message("TEST FAILED: occupied shortcut accepted") }
        catch { try SelfTest.require(keys.bindings == testing && keys.registered, "Failed registration rolls back to working bindings") }
        print("PASS: shortcut persistence, RU/EN key labels, validation, duplicate rejection, real Carbon registration and dispatch, suspension, conflict rollback")

        let logURL = directory.appendingPathComponent("journal/events.json")
        let journal = EventJournal(fileURL: logURL, capacity: 4)
        for index in 0..<6 { journal.record(index == 5 ? .error : .info, "Событие \(index)", "Текст №\(index)\nПодробности") }
        try SelfTest.require(journal.entries.count == 4 && journal.entries.first?.topic == "Событие 2" && journal.errorCount == 1, "Journal is bounded and counts errors")
        let reloaded = EventJournal(fileURL: logURL, capacity: 4)
        try SelfTest.require(reloaded.entries == journal.entries, "Journal survives app restart")
        let target = directory.appendingPathComponent("Spy-журнал.txt")
        let errors = journal.entries.filter { $0.level == .error }
        try journal.export(to: target, entries: errors)
        let contents = try String(contentsOf: target, encoding: .utf8)
        try SelfTest.require(contents.contains("[ERROR]") && contents.contains("Текст №5") && !contents.contains("Текст №4") && contents.contains("Часовой пояс:"), "TXT preserves UTF-8, details and active filter")
        let underlying = NSError(domain: "UnderlyingTest", code: 17, userInfo: [NSLocalizedDescriptionKey: "Причина"])
        let outer = NSError(domain: "OuterTest", code: 42, userInfo: [NSLocalizedDescriptionKey: "Ошибка", NSUnderlyingErrorKey: underlying])
        let described = describeError(outer)
        try SelfTest.require(described.contains("OuterTest") && described.contains("42") && described.contains("UnderlyingTest") && described.contains("17"), "Logs preserve error domains, codes and underlying causes")
        try "broken".write(to: logURL, atomically: true, encoding: .utf8)
        let recovered = EventJournal(fileURL: logURL, capacity: 4)
        try SelfTest.require(recovered.entries.first?.level == .warning, "Corrupt journal recovers with warning")
        recovered.record(.info, "Восстановление", "Работает")
        try SelfTest.require(recovered.persistenceError == nil && EventJournal(fileURL: logURL).entries.count == 2, "Recovered journal resumes persistent logging")
        print("PASS: bounded persistent logs, restart, UTF-8 TXT export, filtered export, nested errors, corrupt-file recovery")
    }
}
