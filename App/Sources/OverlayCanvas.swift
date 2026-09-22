import SwiftUI
import LightshotKit

/// Drawing shared by the three overlay surfaces (screenshot rect, window hover, recording): the
/// even-odd dimming that punches the live region out, and the pixel-dimension readout pill.
enum OverlayCanvas {
    /// Dim the whole screen, punching `box` out so the live region shows the real screen through
    /// the transparent window.
    static func dim(_ context: inout GraphicsContext, size: CGSize, punchingOut box: CGRect?) {
        var dimmed = Path(CGRect(origin: .zero, size: size))
        if let box { dimmed.addRect(box) }
        context.fill(dimmed, with: .color(.black.opacity(0.45)), style: FillStyle(eoFill: true))
    }

    /// The live `W × H` readout in a pill above `box` (or below it when there is no room above).
    static func drawReadout(_ context: inout GraphicsContext, width: Int, height: Int, around box: CGRect) {
        let label = context.resolve(
            Text("\(width) × \(height)")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
        )
        let textSize = label.measure(in: CGSize(width: 400, height: 40))
        let aboveY = box.minY - textSize.height / 2 - 8
        let center = CGPoint(
            x: box.midX,
            y: aboveY - textSize.height / 2 >= 0 ? aboveY : box.maxY + textSize.height / 2 + 8
        )
        let pill = CGRect(
            x: center.x - textSize.width / 2 - 6, y: center.y - textSize.height / 2 - 3,
            width: textSize.width + 12, height: textSize.height + 6
        )
        context.fill(Path(roundedRect: pill, cornerRadius: 4), with: .color(.black.opacity(0.6)))
        context.draw(label, at: center, anchor: .center)
    }
}
