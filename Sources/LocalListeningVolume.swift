import Foundation
import CoreAudio

/// Only the physical output volume. ScreenCaptureKit's captured app PCM and
/// the BlackHole output gain are deliberately untouched.
enum LocalListeningVolume {
    struct Control { let element: AudioObjectPropertyElement; let value: Float32 }
    static func controls(device: AudioDeviceID) -> [Control] {
        func control(_ element: AudioObjectPropertyElement) -> Control? {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            var settable: DarwinBoolean = false
            guard AudioObjectHasProperty(device, &address), AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return nil }
            var value: Float32 = 0; var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr, value.isFinite else { return nil }
            return Control(element: element, value: value)
        }
        if let main = control(kAudioObjectPropertyElementMain) { return [main] }
        return [AudioObjectPropertyElement(1), 2].compactMap(control)
    }
    static func value(device: AudioDeviceID) -> Double? {
        let controls = controls(device: device)
        guard !controls.isEmpty else { return nil }
        return Double(controls.reduce(0) { $0 + $1.value } / Float(controls.count))
    }
    static func set(_ volume: Double, device: AudioDeviceID) throws {
        let controls = controls(device: device)
        guard !controls.isEmpty, volume.isFinite else { throw SpyError.message("Устройство не поддерживает управление громкостью macOS. Используйте регулятор на наушниках или мониторе.") }
        func write(_ value: Float32, element: AudioObjectPropertyElement) -> OSStatus {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            var value = value
            return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        }
        for control in controls {
            let status = write(Float32(min(1, max(0, volume))), element: control.element)
            if status != noErr {
                for original in controls { _ = write(original.value, element: original.element) }
                throw SpyError.message("Не удалось изменить громкость наушников: \(status).")
            }
        }
    }
}
