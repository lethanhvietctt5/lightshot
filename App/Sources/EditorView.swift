import SwiftUI
import LightshotKit

/// The minimal editor surface for the tracer bullet: it shows the captured image and offers a
/// single **Copy** action. No annotation tools yet — those land with the `AnnotationDocument`
/// editor tickets. The Copy button routes back through the coordinator so what reaches the
/// clipboard is the *rendered* image, not the raw capture.
struct EditorView: View {
    let image: CapturedImage
    let onCopy: () -> Void

    private var nsImage: NSImage? { NSImage(data: image.data) }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let nsImage {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                } else {
                    ContentUnavailableView(
                        "Couldn’t display capture",
                        systemImage: "exclamationmark.triangle"
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            HStack {
                Text("\(image.pixelWidth) × \(image.pixelHeight)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy", action: onCopy)
                    .keyboardShortcut("c", modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(minWidth: 480, minHeight: 320)
    }
}
