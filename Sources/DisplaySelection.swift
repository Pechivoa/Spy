import AppKit

enum DisplaySelection {
    /// Numeric display IDs can change after a reconnect, sleep or reboot.
    /// Once known, UUID is authoritative even if the old ID is reused.
    static func resolve(id: CGDirectDisplayID, uuid: String?, choices: [DisplayChoice]) -> DisplayChoice? {
        if let uuid, !uuid.isEmpty {
            return choices.first { $0.uuid == uuid }
        }
        return choices.first { $0.id == id }
    }

    @MainActor static func connected() -> [DisplayChoice] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return nil }
            let uuid = CGDisplayCreateUUIDFromDisplayID(id).map {
                CFUUIDCreateString(nil, $0.takeRetainedValue()) as String
            }
            return DisplayChoice(id: id, name: screen.localizedName, uuid: uuid)
        }
    }
}
