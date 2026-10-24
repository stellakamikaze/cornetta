import CoreAudio
import Foundation

/// Tap globale sull'audio di sistema: tutto ciò che il Mac riproduce, esclusa Cornetta.
final class SystemAudioTap {
    let tapID: AudioObjectID
    let uid: String

    init() throws {
        let own = try? CoreAudio.processObject(pid: getpid())
        if own == nil { Diagnostics.log("Cornetta non è fra i processi audio: il tap non la esclude") }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: own.map { [$0] } ?? [])
        description.uuid = UUID()
        description.name = "Cornetta"
        description.muteBehavior = .unmuted
        description.isPrivate = true

        var id = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &id),
                  "Accesso all'audio di sistema (controlla il permesso «Registrazione audio di sistema»)")
        tapID = id
        uid = description.uuid.uuidString
    }

    var format: AudioStreamBasicDescription? {
        try? CoreAudio.value(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
    }

    func destroy() {
        AudioHardwareDestroyProcessTap(tapID)
    }
}
