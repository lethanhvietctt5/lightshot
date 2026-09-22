import AVFoundation
import LightshotKit

/// The microphones the recorder toolbar can list (spec 0006, story 20), from AVFoundation's
/// discovery session: built-in and external inputs, the system default flagged.
struct AVAudioInputService: AudioInputService {
    func availableInputs() async -> [AudioInputDevice] {
        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        )
        return session.devices.map { device in
            AudioInputDevice(id: device.uniqueID, name: device.localizedName, isDefault: device.uniqueID == defaultID)
        }
    }
}
