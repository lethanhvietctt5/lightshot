import AVFoundation
import LightshotKit

/// `CameraService` over AVFoundation (spec 0006, story 27): the cameras the toolbar's menu lists.
struct AVCameraService: CameraService {
    func availableCameras() async -> [CameraDevice] {
        let defaultID = AVCaptureDevice.default(for: .video)?.uniqueID
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video, position: .unspecified
        )
        return discovery.devices.map {
            CameraDevice(id: $0.uniqueID, name: $0.localizedName, isDefault: $0.uniqueID == defaultID)
        }
    }
}
