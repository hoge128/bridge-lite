import CoreGraphics
import SwiftUI

// MARK: - Zoom state

@Observable
final class ZoomState {
    var scale: CGFloat = 1.0
    var offset: CGSize = .zero
    var fitImageSize: CGSize = .zero
    var viewSize: CGSize = .zero
    var baseOffset: CGSize = .zero
    var imagePixelWidth: CGFloat = 0

    func reset() {
        scale = 1.0; offset = .zero; baseOffset = .zero
    }

    func clampOffset() {
        let hw = max(0, (fitImageSize.width  * scale - viewSize.width)  / 2)
        let hh = max(0, (fitImageSize.height * scale - viewSize.height) / 2)
        offset.width  = max(-hw, min(hw, offset.width))
        offset.height = max(-hh, min(hh, offset.height))
    }

    func applyScaleDelta(_ delta: CGFloat, around point: CGPoint) {
        let old = scale
        scale = max(1.0, min(8.0, scale * (1 + delta)))
        guard scale != old else { return }
        let ratio = (scale - old) / old
        offset.width  -= (point.x - offset.width)  * ratio
        offset.height -= (point.y - offset.height) * ratio
        clampOffset()
    }

    func toggleFitOrHundred(at cursor: CGPoint) {
        if scale < 1.5 {
            let target = min(8.0, max(1.0, imagePixelWidth / max(1, fitImageSize.width)))
            var newOff = CGSize(width:  -cursor.x * (target - 1),
                                height: -cursor.y * (target - 1))
            let hw = max(0, (fitImageSize.width  * target - viewSize.width)  / 2)
            let hh = max(0, (fitImageSize.height * target - viewSize.height) / 2)
            newOff.width  = max(-hw, min(hw, newOff.width))
            newOff.height = max(-hh, min(hh, newOff.height))
            withAnimation(.easeOut(duration: 0.18)) {
                scale = target; offset = newOff; baseOffset = newOff
            }
        } else {
            withAnimation(.easeOut(duration: 0.18)) {
                scale = 1.0; offset = .zero; baseOffset = .zero
            }
        }
    }
}

// MARK: - ZoomableImage

struct ZoomableImage: View {
    let image: CGImage
    let orientation: Image.Orientation
    let zoom: ZoomState

    var body: some View {
        GeometryReader { geo in
            let viewSize = geo.size
            let fitSize = fitImageSize(in: viewSize)

            Image(decorative: image, scale: 1.0, orientation: orientation)
                .resizable()
                .scaledToFit()
                .scaleEffect(zoom.scale)
                .offset(zoom.offset)
                .frame(width: viewSize.width, height: viewSize.height)
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            guard zoom.scale > 1.0 else { return }
                            zoom.offset = CGSize(
                                width:  zoom.baseOffset.width  + value.translation.width,
                                height: zoom.baseOffset.height + value.translation.height)
                            zoom.clampOffset()
                        }
                        .onEnded { _ in zoom.baseOffset = zoom.offset }
                )
                .onAppear {
                    zoom.viewSize = viewSize
                    zoom.fitImageSize = fitSize
                    zoom.imagePixelWidth = CGFloat(image.width)
                }
                .onChange(of: viewSize) { _, new in
                    zoom.viewSize = new
                    zoom.fitImageSize = fitImageSize(in: new)
                    zoom.clampOffset()
                }
        }
    }

    private var nativeSize: CGSize {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        switch orientation {
        case .left, .right, .leftMirrored, .rightMirrored: return CGSize(width: h, height: w)
        default: return CGSize(width: w, height: h)
        }
    }

    private func fitImageSize(in viewSize: CGSize) -> CGSize {
        let s = nativeSize
        guard s.width > 0, s.height > 0, viewSize.width > 0, viewSize.height > 0 else { return viewSize }
        let ia = s.width / s.height, va = viewSize.width / viewSize.height
        return ia > va
            ? CGSize(width: viewSize.width,       height: viewSize.width  / ia)
            : CGSize(width: viewSize.height * ia, height: viewSize.height)
    }
}
