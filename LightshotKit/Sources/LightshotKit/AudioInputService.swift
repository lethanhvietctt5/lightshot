import Foundation

/// A microphone the recorder can narrate through (spec 0006, story 20).
public struct AudioInputDevice: Equatable, Identifiable, Sendable {
    /// The OS's stable identifier for the device (`AVCaptureDevice.uniqueID`).
    public let id: String
    public let name: String
    /// Whether this is the system's current default input.
    public let isDefault: Bool

    public init(id: String, name: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

/// The OS microphone seam (spec 0006, story 20): what the recorder toolbar's device menu lists.
/// The audio itself is captured inside `RecordingService` for the take; this only enumerates.
public protocol AudioInputService: Sendable {
    func availableInputs() async -> [AudioInputDevice]
}
