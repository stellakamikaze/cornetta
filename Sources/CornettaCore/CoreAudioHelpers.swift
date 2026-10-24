import CoreAudio
import Foundation

public struct CoreAudioError: LocalizedError {
    public let operation: String
    public let status: OSStatus

    public init(_ operation: String, _ status: OSStatus) {
        self.operation = operation
        self.status = status
    }

    public var errorDescription: String? {
        "\(operation) non riuscito (OSStatus \(status) \(fourCC(status)))"
    }

    private func fourCC(_ value: OSStatus) -> String {
        let n = UInt32(bitPattern: value)
        let bytes = [24, 16, 8, 0].map { UInt8((n >> $0) & 0xFF) }
        guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return "" }
        return "'" + String(decoding: bytes, as: UTF8.self) + "'"
    }
}

@inline(__always)
func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw CoreAudioError(operation, status) }
}

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
             _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

enum CoreAudio {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         initial: T) throws -> T {
        var addr = address(selector, scope)
        var result = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &result) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) }
        try check(status, "Lettura proprietà \(selector)")
        return result
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cf: Unmanaged<CFString>?
        try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &cf), "Lettura stringa \(selector)")
        guard let cf else { throw CoreAudioError("Lettura stringa \(selector)", kAudioHardwareUnspecifiedError) }
        return cf.takeRetainedValue() as String
    }

    /// Converte un PID nell'oggetto processo di Core Audio.
    static func processObject(pid: pid_t) throws -> AudioObjectID {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pidValue = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<pid_t>.size), &pidValue, &size, &object),
                  "Ricerca del processo")
        // Per un PID senza oggetto processo Core Audio non dà errore: restituisce kAudioObjectUnknown.
        guard object != kAudioObjectUnknown else { throw CoreAudioError("Ricerca del processo", kAudioHardwareBadObjectError) }
        return object
    }

    /// Lista di oggetti Core Audio (processi, dispositivi) letta da una proprietà.
    static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &list) == noErr else { return [] }
        return Array(list.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func defaultInputDevice() -> AudioObjectID? {
        let id = try? value(system, kAudioHardwarePropertyDefaultInputDevice, initial: AudioObjectID(kAudioObjectUnknown))
        guard let id, id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        let id = try? value(system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(kAudioObjectUnknown))
        guard let id, id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func deviceName(_ device: AudioObjectID) -> String {
        (try? string(device, kAudioObjectPropertyName)) ?? "dispositivo sconosciuto"
    }

    /// Numero di canali per ogni stream di input del dispositivo, in ordine.
    static func inputStreamChannels(_ device: AudioObjectID) throws -> [Int] {
        var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size), "Configurazione stream")
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        try check(AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw), "Configurazione stream")
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }
}
