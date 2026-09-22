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

/// The latest microphone level, `0...1`, written from the capture queue and read by the pill's
/// meter on the main thread — hence the lock.
final class AudioLevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Float = 0

    var level: Float {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
