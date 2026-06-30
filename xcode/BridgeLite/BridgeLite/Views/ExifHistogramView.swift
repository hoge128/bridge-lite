import AppKit
import SwiftUI

// 値ベース＋コミットクロージャ設計（性能）:
// min/max を @Binding でなくプレーン String で受け、確定時のみ onCommit を呼ぶ。
// これにより本 View は @Observable / Binding を一切読まないため、`.equatable()` を併用すると
// 入力（bars / minText / maxText / isLoading）が不変なら body 再評価を完全にスキップできる。
//
// ドラッグ性能（3 層構成）:
//  1. HistogramCurve — 曲線本体。コミット済み選択でのみ再描画（.equatable()）。ドラッグ中は静的。
//  2. HistogramInteractive — ドラッグの @State・ジェスチャ・更新中シマー・選択バー（ハンドル）。
//     equatable で包まれない通常ビューなので @State 更新が確実に再描画され、ハンドルがマウスに即追従する。
//  3. HistogramLabelRow — 軸ラベル。コミット済み index でのみ再描画（.equatable()）。
struct ExifHistogramView: View, Equatable {
    let bars: [ExifBucket]
    var isLoading: Bool = false
    let minText: String
    let maxText: String
    /// 範囲確定時（ドラッグ終了）に一度だけ呼ばれる。(min, max) のバケットテキスト。
    var onCommit: (_ min: String, _ max: String) -> Void = { _, _ in }

    nonisolated static func == (l: ExifHistogramView, r: ExifHistogramView) -> Bool {
        l.bars == r.bars && l.minText == r.minText && l.maxText == r.maxText && l.isLoading == r.isLoading
    }

    private var hasData: Bool { bars.contains { $0.count > 0 } }

    // ハンドル位置: minText/maxText がバケットのテキストと一致すれば追従、空文字（= 無効）は端。
    private var leftIndex: Int {
        guard !minText.isEmpty else { return 0 }
        return bars.firstIndex(where: { $0.minText == minText }) ?? 0
    }
    private var rightIndex: Int {
        guard !maxText.isEmpty else { return bars.count - 1 }
        return bars.lastIndex(where: { $0.maxText == maxText }) ?? bars.count - 1
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if hasData {
                    ZStack {
                        // 曲線（静的・ドラッグ中は再描画しない）
                        HistogramCurve(bars: bars, leftIndex: leftIndex, rightIndex: rightIndex)
                            .equatable()
                        // ドラッグ操作・ハンドル・更新中シマー（最前面・即追従）
                        HistogramInteractive(bars: bars, leftIndex: leftIndex,
                                             rightIndex: rightIndex, onCommit: onCommit)
                    }
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.08))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .shimmer(when: isLoading)
                }
            }
            .frame(height: 60)

            HistogramLabelRow(bars: bars, leftIndex: leftIndex, rightIndex: rightIndex)
                .equatable()
        }
        .padding(.bottom, 4)
    }
}

// MARK: - 操作層（ドラッグ @State・ジェスチャ・ハンドル・更新中シマー）
// equatable で包まない通常ビュー。@State 更新が確実に body を再評価し、ハンドルが即追従する。

private struct HistogramInteractive: View {
    let bars: [ExifBucket]
    let leftIndex: Int
    let rightIndex: Int
    let onCommit: (_ min: String, _ max: String) -> Void

    @State private var activeHandle: ActiveHandle? = nil
    @State private var dragLeft: Int? = nil
    @State private var dragRight: Int? = nil
    @State private var hovering = false
    @State private var lastHoverX: CGFloat? = nil
    @State private var pushedKind: CursorKind? = nil   // ドラッグ中に push 済みのカーソル種別

    private enum ActiveHandle {
        case left
        case right
        case box(startLeft: Int, startRight: Int, startX: CGFloat)
    }

    // カーソル種別（フィルムストリップのリサイズ帯と同方式。動けない方向の△が無い形を出し分け）。
    private enum CursorKind: Equatable {
        case arrow
        case resizeLR        // 左右どちらにも動ける
        case resizeLeftOnly  // 左のみ（右端で止まり）
        case resizeRightOnly // 右のみ（左端で止まり）
        case openHand        // 領域ごと移動可能（ホバー）
        case closedHand      // 領域ごと移動中（掴む）

        var nsCursor: NSCursor {
            switch self {
            case .arrow:          return .arrow
            case .resizeLR:       return .resizeLeftRight
            case .resizeLeftOnly: return .resizeLeft
            case .resizeRightOnly: return .resizeRight
            case .openHand:       return .openHand
            case .closedHand:     return .closedHand
            }
        }
    }

    private var effLeftIndex: Int { dragLeft ?? leftIndex }
    private var effRightIndex: Int { dragRight ?? rightIndex }
    private var boxMovable: Bool { effLeftIndex > 0 || effRightIndex < bars.count - 1 }

    private func barIndex(for x: CGFloat, width: CGFloat) -> Int {
        max(0, min(bars.count - 1, Int(x / width * CGFloat(bars.count))))
    }

    // 左ハンドルが動ける方向（左 = 範囲を広げる / 右 = 縮める）。
    private func leftHandleKind() -> CursorKind {
        let canLeft = effLeftIndex > 0
        let canRight = effLeftIndex < effRightIndex
        if canLeft && canRight { return .resizeLR }
        if canRight { return .resizeRightOnly }
        if canLeft { return .resizeLeftOnly }
        return .resizeLR
    }
    private func rightHandleKind() -> CursorKind {
        let canLeft = effRightIndex > effLeftIndex
        let canRight = effRightIndex < bars.count - 1
        if canLeft && canRight { return .resizeLR }
        if canRight { return .resizeRightOnly }
        if canLeft { return .resizeLeftOnly }
        return .resizeLR
    }

    /// ホバー位置 x から出すカーソル。選択バーの矩形（ハンドル±ゾーン／ボックス内）にいる時だけ
    /// 専用カーソル、それ以外は arrow（要件: 矩形領域にあるときだけ形を変える）。
    private func hoverKind(x: CGFloat, width: CGFloat) -> CursorKind {
        guard width > 0, bars.count > 0 else { return .arrow }
        let barW = width / CGFloat(bars.count)
        let lx = CGFloat(effLeftIndex) * barW
        let rx = CGFloat(effRightIndex + 1) * barW
        let hz = max(barW * 0.5, 28)
        if abs(x - lx) < hz { return leftHandleKind() }
        if abs(x - rx) < hz { return rightHandleKind() }
        if x > lx && x < rx { return boxMovable ? .openHand : .arrow }
        return .arrow
    }

    /// ドラッグ中に出すカーソル。ハンドルは方向制約付き、ボックス移動は掴む手。
    private func dragKind() -> CursorKind {
        switch activeHandle {
        case .left:  return leftHandleKind()
        case .right: return rightHandleKind()
        case .box:   return .closedHand
        case nil:    return .arrow
        }
    }

    private func applyDragCursor() {
        let kind = dragKind()
        if pushedKind != kind {
            if pushedKind != nil { NSCursor.pop() }
            kind.nsCursor.push()
            pushedKind = kind
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 更新中シマー（ドラッグ中のみ）。曲線は離すまで更新しないので「更新中」を示す。
                if activeHandle != nil {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.08))
                        .shimmer()
                        .allowsHitTesting(false)
                }

                // 適用範囲のライブ表示（青）。ドラッグ中は eff* に追従してリアルタイムに動く。
                if activeHandle != nil, bars.count > 0 {
                    let barW = geo.size.width / CGFloat(bars.count)
                    let lx = CGFloat(effLeftIndex) * barW
                    let rx = CGFloat(effRightIndex + 1) * barW
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.18))
                        .frame(width: max(0, rx - lx), height: geo.size.height)
                        .position(x: (lx + rx) / 2, y: geo.size.height / 2)
                        .allowsHitTesting(false)
                }

                // 選択バー（ハンドル＋縦線）。ライブ位置・軽量・即追従。
                HistogramHandles(leftIndex: effLeftIndex, rightIndex: effRightIndex, barCount: bars.count)
                    .allowsHitTesting(false)

                // ドラッグ捕捉＋カーソル制御（最前面の透明レイヤー）
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let x = value.location.x
                                let w = geo.size.width
                                let barW = w / CGFloat(bars.count)

                                if activeHandle == nil {
                                    let lIdx = effLeftIndex
                                    let rIdx = effRightIndex
                                    let lx = CGFloat(lIdx) * barW
                                    let rx = CGFloat(rIdx + 1) * barW
                                    let handleZone = max(barW * 0.5, 28)

                                    dragLeft = lIdx
                                    dragRight = rIdx
                                    if abs(x - lx) < handleZone {
                                        activeHandle = .left
                                    } else if abs(x - rx) < handleZone {
                                        activeHandle = .right
                                    } else if x > lx && x < rx {
                                        activeHandle = .box(startLeft: lIdx, startRight: rIdx, startX: x)
                                    } else {
                                        activeHandle = abs(x - lx) <= abs(x - rx) ? .left : .right
                                    }
                                }

                                switch activeHandle {
                                case .left:
                                    dragLeft = min(barIndex(for: x, width: w), dragRight ?? rightIndex)
                                case .right:
                                    dragRight = max(barIndex(for: x, width: w), dragLeft ?? leftIndex)
                                case .box(let startLeft, let startRight, let startX):
                                    let delta = Int(((x - startX) / barW).rounded())
                                    let width = startRight - startLeft
                                    let newLeft = max(0, min(bars.count - 1 - width, startLeft + delta))
                                    dragLeft = newLeft
                                    dragRight = newLeft + width
                                case nil:
                                    break
                                }

                                // 端に達して動ける方向が変わったらカーソルを差し替える。
                                applyDragCursor()
                            }
                            .onEnded { _ in
                                // 範囲が実際に変わった時だけ確定（タップのみの誤適用を避ける）。
                                let finalLeft = dragLeft ?? leftIndex
                                let finalRight = dragRight ?? rightIndex
                                if finalLeft != leftIndex || finalRight != rightIndex {
                                    onCommit(bars[finalLeft].minText, bars[finalRight].maxText)
                                }
                                activeHandle = nil
                                dragLeft = nil
                                dragRight = nil
                                if pushedKind != nil { NSCursor.pop(); pushedKind = nil }
                                // pop 直後は hover の再 enter が来ないので、現在位置から再設定。
                                if hovering, let hx = lastHoverX {
                                    hoverKind(x: hx, width: geo.size.width).nsCursor.set()
                                } else {
                                    NSCursor.arrow.set()
                                }
                            }
                    )
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        switch phase {
                        case .active(let loc):
                            hovering = true
                            lastHoverX = loc.x
                            guard pushedKind == nil else { return }   // ドラッグ中は上書きしない
                            hoverKind(x: loc.x, width: geo.size.width).nsCursor.set()
                        case .ended:
                            hovering = false
                            lastHoverX = nil
                            guard pushedKind == nil else { return }
                            NSCursor.arrow.set()
                        }
                    }
            }
        }
    }
}

// MARK: - ピン型ハンドルの形状（ファイルスコープで曲線層/ハンドル層が共有）

private enum HistogramPin {
    static let w: CGFloat = 14
    static let rectH: CGFloat = 9
    static let triH: CGFloat = 6
    static var totalH: CGFloat { rectH + triH }
    static let cornerR: CGFloat = 3

    static func path(cx: CGFloat) -> Path {
        let halfW = w / 2
        let r = cornerR
        var p = Path()
        p.move(to: CGPoint(x: cx - halfW + r, y: 0))
        p.addLine(to: CGPoint(x: cx + halfW - r, y: 0))
        p.addArc(center: CGPoint(x: cx + halfW - r, y: r),
                 radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: cx + halfW, y: rectH))
        p.addLine(to: CGPoint(x: cx, y: totalH))
        p.addLine(to: CGPoint(x: cx - halfW, y: rectH))
        p.addLine(to: CGPoint(x: cx - halfW, y: r))
        p.addArc(center: CGPoint(x: cx - halfW + r, y: r),
                 radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

// MARK: - 曲線層（静的・コミット済み選択でのみ再描画）

private struct HistogramCurve: View, Equatable {
    let bars: [ExifBucket]
    let leftIndex: Int
    let rightIndex: Int

    private var maxCount: Int { bars.map(\.count).max() ?? 1 }

    nonisolated static func == (l: HistogramCurve, r: HistogramCurve) -> Bool {
        l.leftIndex == r.leftIndex && l.rightIndex == r.rightIndex && l.bars == r.bars
    }

    var body: some View {
        Canvas { ctx, size in
            let n = bars.count
            guard n > 0, maxCount > 0 else { return }
            let barW = size.width / CGFloat(n)
            let lx = CGFloat(leftIndex) * barW
            let rx = CGFloat(rightIndex + 1) * barW

            let topPad = HistogramPin.totalH + 4
            let usableH = size.height - topPad
            let pts: [CGPoint] = bars.enumerated().map { i, bar in
                CGPoint(
                    x: (CGFloat(i) + 0.5) * barW,
                    y: topPad + usableH * (1 - CGFloat(bar.count) / CGFloat(maxCount))
                )
            }

            ctx.drawLayer { layer in
                let clipRect = CGRect(origin: .zero, size: size)
                let clipPath = UnevenRoundedRectangle(
                    bottomLeadingRadius: 3, bottomTrailingRadius: 3
                ).path(in: clipRect)
                layer.clip(to: clipPath)

                let areaPath = histSmoothAreaPath(pts: pts, size: size)
                let linePath = histSmoothLinePath(pts: pts, size: size)
                let selPath  = Path(CGRect(x: lx, y: 0, width: rx - lx, height: size.height))

                layer.fill(selPath, with: .color(.accentColor.opacity(0.05)))

                layer.fill(areaPath, with: .linearGradient(
                    Gradient(colors: [Color.secondary.opacity(0.2), Color.secondary.opacity(0.03)]),
                    startPoint: CGPoint(x: size.width / 2, y: 0),
                    endPoint: CGPoint(x: size.width / 2, y: size.height)
                ))
                layer.stroke(linePath, with: .color(Color.secondary.opacity(0.3)), lineWidth: 1.5)

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
        }
    }
}

// MARK: - 選択バー（ハンドル）層（ライブ位置・軽量）

private struct HistogramHandles: View {
    let leftIndex: Int
    let rightIndex: Int
    let barCount: Int

    var body: some View {
        Canvas { ctx, size in
            guard barCount > 0 else { return }
            let barW = size.width / CGFloat(barCount)
            let lx = CGFloat(leftIndex) * barW
            let rx = CGFloat(rightIndex + 1) * barW
            let halfW = HistogramPin.w / 2
            for dx in [max(halfW, lx), min(size.width - halfW, rx)] {
                var line = Path()
                line.move(to: CGPoint(x: dx, y: HistogramPin.totalH))
                line.addLine(to: CGPoint(x: dx, y: size.height))
                ctx.stroke(line, with: .color(.accentColor), lineWidth: 2)
                ctx.fill(HistogramPin.path(cx: dx), with: .color(.accentColor))
            }
        }
    }
}

// MARK: - 軸ラベル行（コミット済み index のみ依存・.equatable()）

private struct HistogramLabelRow: View, Equatable {
    let bars: [ExifBucket]
    let leftIndex: Int
    let rightIndex: Int

    private var hasData: Bool { bars.contains { $0.count > 0 } }

    nonisolated static func == (l: HistogramLabelRow, r: HistogramLabelRow) -> Bool {
        l.leftIndex == r.leftIndex && l.rightIndex == r.rightIndex && l.bars == r.bars
    }

    var body: some View {
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
}

// MARK: - Catmull-Rom spline（ファイルスコープ）

private func histExtendedPoints(_ pts: [CGPoint], size: CGSize) -> [CGPoint] {
    guard !pts.isEmpty else { return [] }
    var ext = [CGPoint(x: 0, y: size.height)]
    ext.append(contentsOf: pts)
    ext.append(CGPoint(x: size.width, y: size.height))
    return ext
}

private func histControlPoints(_ ext: [CGPoint], at i: Int, height: CGFloat) -> (CGPoint, CGPoint) {
    let p0 = ext[max(0, i - 1)]
    let p1 = ext[i]
    let p2 = ext[i + 1]
    let p3 = ext[min(ext.count - 1, i + 2)]
    let clamp = { (y: CGFloat) in max(0, min(height, y)) }
    let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: clamp(p1.y + (p2.y - p0.y) / 6))
    let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: clamp(p2.y - (p3.y - p1.y) / 6))
    return (c1, c2)
}

private func histSmoothAreaPath(pts: [CGPoint], size: CGSize) -> Path {
    let ext = histExtendedPoints(pts, size: size)
    guard ext.count >= 2 else { return Path() }
    var path = Path()
    path.move(to: CGPoint(x: 0, y: size.height))
    path.addLine(to: ext[0])
    for i in 0..<(ext.count - 1) {
        let (c1, c2) = histControlPoints(ext, at: i, height: size.height)
        path.addCurve(to: ext[i + 1], control1: c1, control2: c2)
    }
    path.addLine(to: CGPoint(x: size.width, y: size.height))
    path.closeSubpath()
    return path
}

private func histSmoothLinePath(pts: [CGPoint], size: CGSize) -> Path {
    let ext = histExtendedPoints(pts, size: size)
    guard ext.count >= 3 else { return Path() }
    var path = Path()
    path.move(to: ext[1])
    for i in 1..<(ext.count - 2) {
        let (c1, c2) = histControlPoints(ext, at: i, height: size.height)
        path.addCurve(to: ext[i + 1], control1: c1, control2: c2)
    }
    return path
}
