import AppKit
import Carbon

enum ShortcutAction: UInt32, Identifiable, CaseIterable {
    case save = 1, toggle = 2, save30 = 3, save60 = 4, save300 = 5, save600 = 6, manual = 7, preview = 8, marker = 9
    var id: UInt32 { rawValue }
    var title: String {
        switch self {
        case .save: return "Сохранить выбранное время"
        case .toggle: return "Включить / остановить буфер"
        case .save30: return "Сохранить 30 секунд"
        case .save60: return "Сохранить 1 минуту"
        case .save300: return "Сохранить 5 минут"
        case .save600: return "Сохранить 10 минут"
        case .manual: return "Начать / завершить ручную запись"
        case .preview: return "Открыть просмотр буфера"
        case .marker: return "Добавить метку момента"
        }
    }
    var seconds: Double? {
        switch self { case .save30: return 30; case .save60: return 60; case .save300: return 300; case .save600: return 600; default: return nil }
    }
    static var quick: [ShortcutAction] { [.save30, .save60, .save300, .save600] }
    var shortTitle: String { switch self { case .save30: return "30 сек"; case .save60: return "1 мин"; case .save300: return "5 мин"; case .save600: return "10 мин"; default: return title } }
}

struct Shortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String
    static let saveDefault = Shortcut(keyCode: 1, modifiers: UInt32(cmdKey | optionKey), keyLabel: "S")
    static let toggleDefault = Shortcut(keyCode: 15, modifiers: UInt32(cmdKey | optionKey), keyLabel: "R")
    static let previewDefault = Shortcut(keyCode: 35, modifiers: UInt32(cmdKey | optionKey), keyLabel: "P")
    static let markerDefault = Shortcut(keyCode: 46, modifiers: UInt32(cmdKey | optionKey | shiftKey), keyLabel: "M")
    var label: String {
        var value = ""
        if modifiers & UInt32(controlKey) != 0 { value += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { value += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { value += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { value += "⌘" }
        return value + keyLabel
    }
    func sameCombination(as other: Shortcut) -> Bool { keyCode == other.keyCode && modifiers == other.modifiers }
    var validationError: String? {
        if keyCode > 127 || keyCode == 53 || (54...63).contains(keyCode) { return "Выберите обычную клавишу или F-клавишу. Esc отменяет назначение." }
        let supported = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        if modifiers & ~supported != 0 { return "Это сочетание не поддерживается." }
        let isFunction = Self.keyNames[keyCode]?.hasPrefix("F") == true
        if modifiers & UInt32(cmdKey | optionKey | controlKey) == 0 && !isFunction {
            return "Добавьте ⌘, ⌥ или ⌃, чтобы сочетание не мешало обычному вводу."
        }
        return nil
    }
    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.keyLabel = keyLabel
    }
    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        var flags: UInt32 = 0
        if event.modifierFlags.contains(.command) { flags |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.option) { flags |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { flags |= UInt32(controlKey) }
        if event.modifierFlags.contains(.shift) { flags |= UInt32(shiftKey) }
        modifiers = flags
        keyLabel = Self.keyNames[keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Клавиша \(keyCode)"
    }
    // Physical key labels stay recognizable when the user switches RU / EN.
    static let keyNames: [UInt32: String] = [
        0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",
        12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",
        22:"6",23:"5",24:"=",25:"9",26:"7",27:"−",28:"8",29:"0",30:"]",31:"O",
        32:"U",33:"[",34:"I",35:"P",36:"↩",37:"L",38:"J",39:"'",40:"K",41:";",
        42:"\\",43:",",44:"/",45:"N",46:"M",47:".",48:"Tab",49:"Пробел",50:"`",
        51:"⌫",65:"Num .",67:"Num *",69:"Num +",71:"Clear",75:"Num /",76:"Num ↩",
        78:"Num −",81:"Num =",82:"Num 0",83:"Num 1",84:"Num 2",85:"Num 3",86:"Num 4",
        87:"Num 5",88:"Num 6",89:"Num 7",91:"Num 8",92:"Num 9",96:"F5",97:"F6",
        98:"F7",99:"F3",100:"F8",101:"F9",103:"F11",105:"F13",106:"F16",107:"F14",
        109:"F10",111:"F12",113:"F15",114:"Help",115:"Home",116:"Page Up",117:"⌦",
        118:"F4",119:"End",120:"F2",121:"Page Down",122:"F1",123:"←",124:"→",125:"↓",126:"↑"
    ]
}

struct ShortcutBindings: Codable, Equatable {
    var save: Shortcut
    var toggle: Shortcut
    var quick30: Shortcut
    var quick60: Shortcut
    var quick300: Shortcut
    var quick600: Shortcut
    var manual: Shortcut
    var preview: Shortcut
    var marker: Shortcut
    static func quickDefault(_ key: UInt32) -> Shortcut { Shortcut(keyCode: key, modifiers: UInt32(cmdKey | optionKey), keyLabel: Shortcut.keyNames[key] ?? "?") }
    init(save: Shortcut = .saveDefault, toggle: Shortcut = .toggleDefault,
         quick30: Shortcut = quickDefault(18), quick60: Shortcut = quickDefault(19),
         quick300: Shortcut = quickDefault(20), quick600: Shortcut = quickDefault(21), manual: Shortcut = Shortcut(keyCode: 9, modifiers: UInt32(cmdKey | optionKey), keyLabel: "V"),
         preview: Shortcut = .previewDefault, marker: Shortcut = .markerDefault) {
        self.save=save; self.toggle=toggle; self.quick30=quick30; self.quick60=quick60; self.quick300=quick300; self.quick600=quick600; self.manual=manual
        self.preview=preview; self.marker=marker
    }
    enum CodingKeys: String, CodingKey { case save, toggle, quick30, quick60, quick300, quick600, manual, preview, marker }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(save: try c.decodeIfPresent(Shortcut.self, forKey: .save) ?? .saveDefault,
                  toggle: try c.decodeIfPresent(Shortcut.self, forKey: .toggle) ?? .toggleDefault,
                  quick30: try c.decodeIfPresent(Shortcut.self, forKey: .quick30) ?? Self.quickDefault(18),
                  quick60: try c.decodeIfPresent(Shortcut.self, forKey: .quick60) ?? Self.quickDefault(19),
                  quick300: try c.decodeIfPresent(Shortcut.self, forKey: .quick300) ?? Self.quickDefault(20),
                  quick600: try c.decodeIfPresent(Shortcut.self, forKey: .quick600) ?? Self.quickDefault(21),
                  manual: try c.decodeIfPresent(Shortcut.self, forKey: .manual) ?? Shortcut(keyCode: 9, modifiers: UInt32(cmdKey | optionKey), keyLabel: "V"),
                  preview: try c.decodeIfPresent(Shortcut.self, forKey: .preview) ?? .previewDefault,
                  marker: try c.decodeIfPresent(Shortcut.self, forKey: .marker) ?? .markerDefault)
        // Preserve older user bindings if they collide with newly added defaults.
        var seen: [Shortcut] = [save, toggle]
        for (action, key) in zip(ShortcutAction.quick + [.manual, .preview, .marker], [CodingKeys.quick30, .quick60, .quick300, .quick600, .manual, .preview, .marker]) {
            if !c.contains(key), seen.contains(where: { $0.sameCombination(as: self[action]) }) {
                for code: UInt32 in [18,19,20,21,22,23,25,26,28,29] {
                    let fallback=Shortcut(keyCode: code, modifiers: UInt32(cmdKey | controlKey | optionKey | shiftKey), keyLabel: Shortcut.keyNames[code]!)
                    if !seen.contains(where: { $0.sameCombination(as: fallback) }) { self[action]=fallback; break }
                }
            }
            seen.append(self[action])
        }
    }
    subscript(_ action: ShortcutAction) -> Shortcut {
        get { switch action { case .save: return save; case .toggle: return toggle; case .save30: return quick30; case .save60: return quick60; case .save300: return quick300; case .save600: return quick600; case .manual: return manual; case .preview: return preview; case .marker: return marker } }
        set { switch action { case .save: save=newValue; case .toggle: toggle=newValue; case .save30: quick30=newValue; case .save60: quick60=newValue; case .save300: quick300=newValue; case .save600: quick600=newValue; case .manual: manual=newValue; case .preview: preview=newValue; case .marker: marker=newValue } }
    }
    func validate() throws {
        var seen: [Shortcut] = []
        for action in ShortcutAction.allCases {
            let value=self[action]
            if let issue=value.validationError { throw SpyError.message(issue) }
            if seen.contains(where: { $0.sameCombination(as: value) }) { throw SpyError.message("Для действий нужны разные сочетания клавиш.") }
            seen.append(value)
        }
    }
    static func load(from defaults: UserDefaults) -> ShortcutBindings {
        guard let data=defaults.data(forKey: "shortcuts"), let value=try? JSONDecoder().decode(Self.self, from: data), (try? value.validate()) != nil else { return Self() }
        return value
    }
    func persist(to defaults: UserDefaults) { if let data=try? JSONEncoder().encode(self) { defaults.set(data, forKey: "shortcuts") } }
}

final class HotKeys {
    private var handler: EventHandlerRef?
    private var refs: [EventHotKeyRef] = []
    private(set) var bindings: ShortcutBindings
    private(set) var suspended = false
    private(set) var registered = false
    private(set) var registrationError: String?
    let callback: (UInt32) -> Void
    init(bindings: ShortcutBindings, callback: @escaping (UInt32) -> Void) {
        self.bindings = bindings; self.callback = callback
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr else { return result }
            guard id.signature == 0x5350594B else { return OSStatus(eventNotHandledErr) }
            Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue().callback(id.id)
            return noErr
        }, 1, &spec, pointer, &handler)
        guard status == noErr else { registrationError = "Обработчик клавиш недоступен (\(status))."; return }
        do { try register(bindings) } catch { registrationError = error.localizedDescription }
    }
    private func releaseKeys() { refs.forEach { UnregisterEventHotKey($0) }; refs = []; registered = false }
    private func register(_ value: ShortcutBindings) throws {
        guard handler != nil else { throw SpyError.message("Не удалось подключить горячие клавиши.") }
        for action in ShortcutAction.allCases {
            let shortcut = value[action]
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: 0x5350594B, id: action.rawValue), GetApplicationEventTarget(), 0, &ref)
            guard status == noErr, let ref else {
                releaseKeys()
                throw SpyError.message("Сочетание \(shortcut.label) занято или недоступно. Выберите другое (код \(status)).")
            }
            refs.append(ref)
        }
        registered = true; suspended = false; registrationError = nil
    }
    func configure(_ value: ShortcutBindings) throws {
        try value.validate()
        let previous = bindings
        releaseKeys()
        do { try register(value); bindings = value }
        catch {
            let failure = error
            try? register(previous)
            registrationError = failure.localizedDescription
            throw failure
        }
    }
    func suspend() { releaseKeys(); suspended = true }
    func resume() throws { guard suspended else { return }; try register(bindings) }
    deinit { releaseKeys(); if let handler { RemoveEventHandler(handler) } }
}
