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

    /// CleanShot's selection chrome — an L-bracket at each corner and a short bar at each edge's
    /// midpoint, white over a soft dark edge — drawn on the eight handle points the models
    /// hit-test. Shared by the recording selection and the editor's crop (LIG-47).
    static func drawSelectionChrome(_ context: inout GraphicsContext, around box: CGRect, arm: CGFloat = 16) {
        let handles = selectionChrome(for: box, arm: arm)
        context.stroke(handles, with: .color(.black.opacity(0.35)), style: StrokeStyle(lineWidth: 5, lineCap: .round))
        context.stroke(handles, with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .butt))
    }

    private static func selectionChrome(for box: CGRect, arm: CGFloat) -> Path {
        // Short sides get shorter arms, so the brackets never meet on a small box.
        let arm = min(arm, box.width / 3, box.height / 3)
        let half = arm / 2
        var path = Path()
        for handle in Handle.allCases {
            let p = handlePoint(handle, in: Rect(x: box.minX, y: box.minY, width: box.width, height: box.height)).cgPoint
            switch handle {
            case .topLeft:
                path.move(to: CGPoint(x: p.x, y: p.y + arm)); path.addLine(to: p); path.addLine(to: CGPoint(x: p.x + arm, y: p.y))
            case .topRight:
                path.move(to: CGPoint(x: p.x - arm, y: p.y)); path.addLine(to: p); path.addLine(to: CGPoint(x: p.x, y: p.y + arm))
            case .bottomRight:
                path.move(to: CGPoint(x: p.x, y: p.y - arm)); path.addLine(to: p); path.addLine(to: CGPoint(x: p.x - arm, y: p.y))
            case .bottomLeft:
                path.move(to: CGPoint(x: p.x + arm, y: p.y)); path.addLine(to: p); path.addLine(to: CGPoint(x: p.x, y: p.y - arm))
            case .top, .bottom:
                path.move(to: CGPoint(x: p.x - half, y: p.y)); path.addLine(to: CGPoint(x: p.x + half, y: p.y))
            case .left, .right:
                path.move(to: CGPoint(x: p.x, y: p.y - half)); path.addLine(to: CGPoint(x: p.x, y: p.y + half))
            }
        }
        return path
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
