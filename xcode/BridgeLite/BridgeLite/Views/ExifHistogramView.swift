import SwiftUI

struct ExifHistogramView: View {
    let bars: [ExifBucket]
    @Binding var minText: String
    @Binding var maxText: String

    @State private var activeHandle: ActiveHandle? = nil

    private enum ActiveHandle {
        case left
        case right
        case box(startLeft: Int, startRight: Int, startX: CGFloat)
    }

    private var maxCount: Int { bars.map(\.count).max() ?? 1 }
    private var hasData: Bool { bars.contains { $0.count > 0 } }

    // ハンドル位置: minText/maxText がバケットのテキストと一致すれば追従、
    // 空文字（= フィルタ無効）は端に表示
    private var leftIndex: Int {
        guard !minText.isEmpty else { return 0 }
        return bars.firstIndex(where: { $0.minText == minText }) ?? 0
    }
    private var rightIndex: Int {
        guard !maxText.isEmpty else { return bars.count - 1 }
        return bars.lastIndex(where: { $0.maxText == maxText }) ?? bars.count - 1
    }

    private func barIndex(for x: CGFloat, width: CGFloat) -> Int {
        max(0, min(bars.count - 1, Int(x / width * CGFloat(bars.count))))
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                if hasData {
                    Canvas { ctx, size in
                        let n = bars.count
                        guard n > 0, maxCount > 0 else { return }
                        let barW = size.width / CGFloat(n)
                        let lIdx = leftIndex
                        let rIdx = rightIndex
                        let lx = CGFloat(lIdx) * barW
                        let rx = CGFloat(rIdx + 1) * barW

                        let topPad: CGFloat = 4
                        let usableH = size.height - topPad
                        let pts: [CGPoint] = bars.enumerated().map { i, bar in
                            CGPoint(
                                x: (CGFloat(i) + 0.5) * barW,
                                y: topPad + usableH * (1 - CGFloat(bar.count) / CGFloat(maxCount))
                            )
                        }

                        // カーブと選択背景はクリップされたレイヤーで描く
                        ctx.drawLayer { layer in
                            let clipRect = CGRect(origin: .zero, size: size)
                            let clipPath = UnevenRoundedRectangle(
                                bottomLeadingRadius: 3, bottomTrailingRadius: 3
                            ).path(in: clipRect)
                            layer.clip(to: clipPath)

                            let areaPath = Self.smoothAreaPath(pts: pts, size: size)
                            let linePath = Self.smoothLinePath(pts: pts, size: size)
                            let selPath  = Path(CGRect(x: lx, y: 0, width: rx - lx, height: size.height))

                            // 選択範囲の背景
                            layer.fill(selPath, with: .color(.accentColor.opacity(0.05)))

                            // 範囲外: グレーのカーブ（全体に描く）
                            layer.fill(areaPath, with: .linearGradient(
                                Gradient(colors: [Color.secondary.opacity(0.2), Color.secondary.opacity(0.03)]),
                                startPoint: CGPoint(x: size.width / 2, y: 0),
                                endPoint: CGPoint(x: size.width / 2, y: size.height)
                            ))
                            layer.stroke(linePath, with: .color(Color.secondary.opacity(0.3)), lineWidth: 1.5)

                            // 範囲内: アクセントカラーのカーブ（選択矩形でクリップして重ね描き）
                            layer.drawLayer { sel in
                                sel.clip(to: selPath)
                                sel.fill(areaPath, with: .linearGradient(
                                    Gradient(colors: [Color.accentColor.opacity(0.6), Color.accentColor.opacity(0.04)]),
                                    startPoint: CGPoint(x: size.width / 2, y: 0),
                                    endPoint: CGPoint(x: size.width / 2, y: size.height)
                                ))
                                sel.stroke(linePath, with: .color(Color.accentColor.opacity(0.9)), lineWidth: 1.5)
                            }
                        }

                        // ハンドル: クリップ外で最前面に描く
                        // 端では円の中心を内側にクランプして切れないようにする
                        let tabSize: CGFloat = 7
                        let half = tabSize / 2
                        for dx in [max(half, lx), min(size.width - half, rx)] {
                            var line = Path()
                            line.move(to: CGPoint(x: dx, y: tabSize))
                            line.addLine(to: CGPoint(x: dx, y: size.height))
                            ctx.stroke(line, with: .color(.accentColor), lineWidth: 2)
                            ctx.fill(
                                Path(ellipseIn: CGRect(x: dx - half, y: 0,
                                                       width: tabSize, height: tabSize)),
                                with: .color(.accentColor)
                            )
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let x = value.location.x
                                let w = geo.size.width
                                let barW = w / CGFloat(bars.count)

                                if activeHandle == nil {
                                    let lIdx = leftIndex
                                    let rIdx = rightIndex
                                    let lx = CGFloat(lIdx) * barW
                                    let rx = CGFloat(rIdx + 1) * barW
                                    let handleZone = max(barW * 0.5, 22)

                                    if abs(x - lx) < handleZone {
                                        activeHandle = .left
                                    } else if abs(x - rx) < handleZone {
                                        activeHandle = .right
                                    } else if x > lx && x < rx {
                                        // 範囲内：ボックス全体をスライド
                                        activeHandle = .box(startLeft: lIdx, startRight: rIdx, startX: x)
                                    } else {
                                        // 範囲外：近い方のハンドルを動かす
                                        activeHandle = abs(x - lx) <= abs(x - rx) ? .left : .right
                                    }
                                }

                                switch activeHandle {
                                case .left:
                                    let idx = barIndex(for: x, width: w)
                                    minText = bars[min(idx, rightIndex)].minText
                                case .right:
                                    let idx = barIndex(for: x, width: w)
                                    maxText = bars[max(idx, leftIndex)].maxText
                                case .box(let startLeft, let startRight, let startX):
                                    let delta = Int(((x - startX) / barW).rounded())
                                    let width = startRight - startLeft
                                    let newLeft = max(0, min(bars.count - 1 - width, startLeft + delta))
                                    minText = bars[newLeft].minText
                                    maxText = bars[newLeft + width].maxText
                                case nil:
                                    break
                                }
                            }
                            .onEnded { _ in activeHandle = nil }
                    )
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.08))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 44)

            // ラベル行: 選択範囲外は tertiary で薄く
            HStack(spacing: 0) {
                ForEach(bars.indices, id: \.self) { i in
                    Text(bars[i].label)
                        .font(.system(size: 7))
                        .foregroundStyle(
                            !hasData || i < leftIndex || i > rightIndex
                            ? AnyShapeStyle(.tertiary)
                            : AnyShapeStyle(.secondary)
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 12)
        }
        .padding(.bottom, 4)
    }

    // MARK: - Catmull-Rom spline

    private static func extendedPoints(_ pts: [CGPoint], size: CGSize) -> [CGPoint] {
        guard !pts.isEmpty else { return [] }
        var ext = [CGPoint(x: 0, y: size.height)]
        ext.append(contentsOf: pts)
        ext.append(CGPoint(x: size.width, y: size.height))
        return ext
    }

    private static func controlPoints(_ ext: [CGPoint], at i: Int, height: CGFloat) -> (CGPoint, CGPoint) {
        let p0 = ext[max(0, i - 1)]
        let p1 = ext[i]
        let p2 = ext[i + 1]
        let p3 = ext[min(ext.count - 1, i + 2)]
        let clamp = { (y: CGFloat) in max(0, min(height, y)) }
        let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: clamp(p1.y + (p2.y - p0.y) / 6))
        let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: clamp(p2.y - (p3.y - p1.y) / 6))
        return (c1, c2)
    }

    private static func smoothAreaPath(pts: [CGPoint], size: CGSize) -> Path {
        let ext = extendedPoints(pts, size: size)
        guard ext.count >= 2 else { return Path() }
        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height))
        path.addLine(to: ext[0])
        for i in 0..<(ext.count - 1) {
            let (c1, c2) = controlPoints(ext, at: i, height: size.height)
            path.addCurve(to: ext[i + 1], control1: c1, control2: c2)
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        return path
    }

    private static func smoothLinePath(pts: [CGPoint], size: CGSize) -> Path {
        let ext = extendedPoints(pts, size: size)
        // ext[0] と ext[last] は底辺コーナーのアンカー点。
        // ストロークは実データ点（ext[1..n]）のみを通過させる。
        guard ext.count >= 3 else { return Path() }
        var path = Path()
        path.move(to: ext[1])
        for i in 1..<(ext.count - 2) {
            let (c1, c2) = controlPoints(ext, at: i, height: size.height)
            path.addCurve(to: ext[i + 1], control1: c1, control2: c2)
        }
        return path
    }
}
