import Combine
import CoreGraphics
import ImageIO
import os
import SwiftUI
import UIKit

// iOS 専用のフルサイズデコード用リミッター（IOSurface 枯渇防止）
private let fullResLimiter = ConcurrencyLimiter(maxConcurrent: 1)

private struct FullResEntry: Sendable {
    let id: UInt64
    let image: UIImage
    /// 退避判定用の概算デコード済みコスト（W×H×4 bytes、scale=1 前提）
    let cost: Int
}

/// デコード済みサムネイルの保持用 plain class（@State の参照先だが SwiftUI は観測しない）。
private final class DecodedThumbStore {
    var id: UInt64?
    var data: Data?
    var image: UIImage?
}

struct DetailView: View {
    let groups: [ShotGroup]
    private let fallbackGroup: ShotGroup
    let entries: [UInt64: PhotoEntry]
    @Binding var ratings: [UInt64: XmpData]
    let db: BridgeCoreDatabase?
    let jpgWriteMode: JpgWriteMode
    let scanStore: ScanStore

    /// scanStore.thumbnails を直接参照することで @Observable の変更検知に乗る。
    /// let スナップショットだと DetailView オープン後のバッチ生成分が反映されない。
    private var thumbnails: [UInt64: Data] { scanStore.thumbnails }
    let onClose: () -> Void
    /// ページング・再解決で表示中のグループが変わったとき親（グリッド）へ通知する。
    /// グリッド側はセルの黒い穴と閉じアニメーションの着地先を追従させる。
    let onCurrentGroupChanged: ((ShotGroup) -> Void)?
    private let dismissDragOffset: Binding<CGSize>
    @Environment(\.isDetailClosing) private var isClosing

    /// ジェスチャー中に記録した開始点からの最大距離。
    /// 一度しきい値を超えたら指を戻しても opacity が上がらないようにする。
    @State private var dismissPeakDist: CGFloat = 0

    /// dist=0: 1.0、dist≥100pt: 0.0。ピーク値を使うため指を戻しても戻らない。
    private var dismissInfoOpacity: Double {
        let d = dismissDragOffset.wrappedValue
        let dist = sqrt(Double(d.width * d.width + d.height * d.height))
        let effective = max(dist, Double(dismissPeakDist))
        return max(0, 1.0 - effective / 100)
    }

    @State private var currentGroupIndex: Int
    @State private var currentIndex: Int
    @State private var dragOffset: CGFloat = 0
    /// ページング送りアニメーション中フラグ。0.22 秒の送りが完了する前に次のフリックを
    /// 受けると古い index で canNavigate が評価され範囲外へ走るため、完了まで弾く。
    @State private var isPaging = false
    @State private var isImageZoomed = false
    @State private var isFullscreen = false
    @State private var showRatingPopup = false
    @State private var showDeleteConfirm = false
    @State private var showEmbedWarning = false
    @State private var pendingWriteEntry: (id: UInt64, url: URL, xmp: XmpData, previousXmp: XmpData?, targetIDs: [UInt64])?
    @State private var ratingWriteTask: Task<Void, Never>?
    @State private var showInfoPanel = false

    // フルサイズキャッシュ（メモリ予算ベースの LRU。退避時は表示中の写真を保護する）
    @State private var fullResCache: [FullResEntry] = []
    @State private var isLoadingFullRes = false
    // 同一エントリの二重デコード防止
    @State private var inFlightFullRes: Set<UInt64> = []
    /// 兄弟メンバー・隣接グループの先読み Task。limiter は maxConcurrent 1 のため、
    /// ページング時にキャンセルしないと現在写真のデコードが古い先読みの後ろに並ぶ。
    @State private var auxLoadTasks: [Task<Void, Never>] = []
    /// デコード済みサムネイルのメモ。body 評価ごとに UIImage(data:) を作り直すと
    /// ZoomableImageView の `!==` 比較が外れて recalculateLayout（ズームリセット）が
    /// 走るため、同一データの間は同一インスタンスを返す。SwiftUI が観測しない
    /// plain class に書く（CellFrameStore と同じパターン）。
    @State private var decodedThumb = DecodedThumbStore()

    // RAW レンダリング
    @State private var rawRendered: UIImage? = nil
    @State private var isRendering = false
    @State private var showRendered = false
    // true のとき、次の RAW に移動しても自動レンダリングする（親 View で保持）
    @Binding var preferRendered: Bool

    private var isLimitedRawPreview: Bool {
        current?.url.pathExtension.lowercased() == "cr2"
    }

    init(groups: [ShotGroup],
         initialGroup: ShotGroup,
         entries: [UInt64: PhotoEntry],
         ratings: Binding<[UInt64: XmpData]>,
         db: BridgeCoreDatabase?,
         jpgWriteMode: JpgWriteMode = .embed,
         scanStore: ScanStore,
         preferRendered: Binding<Bool>,
         dismissDragOffset: Binding<CGSize> = .constant(.zero),
         onCurrentGroupChanged: ((ShotGroup) -> Void)? = nil,
         onClose: @escaping () -> Void) {
        self.onClose = onClose
        self.onCurrentGroupChanged = onCurrentGroupChanged
        self.dismissDragOffset = dismissDragOffset
        self.groups = groups
        self.fallbackGroup = initialGroup
        self.entries = entries
        self._ratings = ratings
        self.db = db
        self.jpgWriteMode = jpgWriteMode
        self.scanStore = scanStore
        self._preferRendered = preferRendered
        let groupIdx = groups.firstIndex(where: { $0.id == initialGroup.id }) ?? 0
        self._currentGroupIndex = State(initialValue: groupIdx)
        let g = groups.isEmpty ? initialGroup : groups[groupIdx]
        let repIdx = g.representativeID.flatMap { g.memberIDs.firstIndex(of: $0) } ?? 0
        self._currentIndex = State(initialValue: repIdx)
    }

    private var group: ShotGroup {
        guard !groups.isEmpty else { return fallbackGroup }
        return groups[max(0, min(currentGroupIndex, groups.count - 1))]
    }

    private var members: [PhotoEntry] {
        group.memberIDs.compactMap { entries[$0] }
    }

    private var current: PhotoEntry? { members[safe: currentIndex] }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if let entry = current {
                    if isFullscreen {
                        // フルスクリーン: 画像が全面、情報はスライドインパネル
                        imageViewport(entry: entry)
                            .overlay(alignment: .topTrailing) {
                                infoToggleButton
                                    .padding(.top, 60)
                                    .padding(.trailing, 12)
                            }
                        if showInfoPanel {
                            fullscreenInfoPanel(entry: entry)
                                .opacity(isClosing ? 0 : 1)
                                .animation(.easeOut(duration: 0.1), value: isClosing)
                        }
                    } else {
                        // カード/画面のジオメトリで判定（sheet の中央カードでも正しく効く）:
                        // 横長 → 画像 + 右サイドパネル / 縦長 → 画像を上部固定 + 縦カラム。
                        GeometryReader { g in
                            if g.size.width > g.size.height {
                                imageViewport(entry: entry)
                                    .background(Color.black
                                        .opacity(isClosing ? 0 : dismissInfoOpacity)
                                        .ignoresSafeArea())
                                    .safeAreaInset(edge: .trailing, spacing: 0) {
                                        landscapeInfoPanel(entry: entry)
                                            .opacity(isClosing ? 0 : dismissInfoOpacity)
                                            .animation(.easeOut(duration: 0.1), value: isClosing)
                                    }
                            } else {
                                VStack(spacing: 0) {
                                    // 黒背景は画像エリアのみ（コンテンツ層）に限定。
                                    // 情報エリアは透明にしてガラス要素を浮かせる。
                                    imageViewport(entry: entry)
                                        .frame(height: g.size.height * 0.58)
                                        .background(Color.black
                                            .opacity(isClosing ? 0 : dismissInfoOpacity)
                                            .ignoresSafeArea(edges: .top))
                                    portraitInfoColumn(entry: entry, screenHeight: g.size.height)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        .opacity(isClosing ? 0 : dismissInfoOpacity)
                                        .animation(.easeOut(duration: 0.1), value: isClosing)
                                }
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: dismissDragOffset.wrappedValue) { _, newOffset in
            let dist = sqrt(newOffset.width * newOffset.width + newOffset.height * newOffset.height)
            if dist > dismissPeakDist { dismissPeakDist = dist }
            // snap-back でオフセットが 0 に戻ったらピークをリセット
            if newOffset == .zero { dismissPeakDist = 0 }
        }
        .onChange(of: currentIndex) { isImageZoomed = false }
        // currentGroupIndex でなく group.id を見る: スキャン進行・フィルタ変動による
        // index 再解決（reResolveIndices）では同じグループの位置がズレただけなので、
        // メンバー選択をリセットしてはいけない。グループの「実体」が変わったときだけ
        // 代表メンバーへ戻し、親へ現在グループを通知する。
        .onChange(of: group.id) {
            dragOffset = 0
            currentIndex = group.representativeID.flatMap { group.memberIDs.firstIndex(of: $0) } ?? 0
            onCurrentGroupChanged?(group)
        }
        // スキャン進行中のグループ挿入・ソート変動・フィルタ脱落で groups 配列が
        // 変わると、保持している index が別のグループを指してしまう。
        // 表示中のグループを id で追跡して index を再解決する。
        .onChange(of: groups) { oldGroups, newGroups in
            reResolveIndices(from: oldGroups, to: newGroups)
        }
        .task(id: current?.id) {
            rawRendered = nil
            showRendered = false
            // 前の写真の兄弟・隣接先読みをキャンセルする。limiter は maxConcurrent 1 の
            // FIFO のため、残したままだと現在写真のデコードが古い先読みの後ろに並び、
            // 高速ページング時にぼけたサムネイル表示が長引く。
            //
            // ⚠️ キャンセルだけして先へ進んではいけない。これから表示する写真が
            // ちょうど先読み中だった場合、inFlightFullRes ガードで loadAndCache が
            // 即 return し、先読み側はキャンセルで破棄されて誰もロードしなくなる
            //（再ロード機構がないためサムネイルのまま固定される）。
            // 完了を待てば、先読みがデコードまで進んでいればキャッシュヒット、
            // 破棄されていれば inFlight が空くので自分でロードし直せる。
            // 待ち時間は最大でも実行中デコード 1 件分（キュー待ちは即座に破棄される）。
            let cancelledTasks = auxLoadTasks
            auxLoadTasks = []
            cancelledTasks.forEach { $0.cancel() }
            for t in cancelledTasks { await t.value }
            guard let entry = current else { return }
            // バッチ索引完了前でも EXIF を表示できるようオンデマンド取得
            await scanStore.fetchExifOnDemand(id: entry.id, url: entry.url)
            await loadAndCache(entry: entry)
            for sibling in members where sibling.id != entry.id {
                auxLoadTasks.append(Task(priority: .utility) { await loadAndCache(entry: sibling) })
            }
            prefetchNeighbors()
            // preferRendered が有効な RAW なら自動レンダリング
            guard preferRendered, entry.isRaw, !isLimitedRawPreview, let db else { return }
            isRendering = true
            defer { isRendering = false }
            let targetID = entry.id
            if let (cgImage, _) = await RAWRenderPipeline.shared.render(
                url: entry.url, target: .viewer, db: db
            ) {
                guard !Task.isCancelled, current?.id == targetID else { return }
                rawRendered = UIImage(cgImage: cgImage)
                showRendered = true
            }
        }
        .onDisappear {
            showInfoPanel = false
            // 閉じた後に先読みデコードが limiter を占有し続けないようキャンセル
            auxLoadTasks.forEach { $0.cancel() }
            auxLoadTasks = []
        }
        // 非常弁: メモリ警告で表示中以外のフル解像度キャッシュを即時破棄する。
        // 予算評価はキャッシュ追加時にしか走らないため、追加の合間に
        // スキャン等で残量が急減したケースはここで受ける。
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            fullResCache.removeAll { $0.id != current?.id }
            // 表示していないレンダリング済み RAW も解放する（再表示時は再レンダリング）
            if !showRendered { rawRendered = nil }
        }
        .onChange(of: isFullscreen) {
            if !isFullscreen { showInfoPanel = false }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        // isClosing で toolbar visibility をフリップしない。
        // フリップすると UIKit のナビバー再レイアウトが走り、その state 更新で
        // SwiftUI が NavigationStack ホスティングビューに systemBackground を
        // 再アサートして 1〜2 フレームの白/黒フラッシュになる（背景再アサート検知ログで確認済み）。
        // 閉じアニメーション中のバーは CoverClip（画像領域のみのクリップ）が隠すため
        // visibility を変える必要がない。
        .toolbar(isFullscreen ? .hidden : .visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .glassNavigationBar()
        .toolbar {
            // スワイプ dismiss 中・閉じアニメーション中はツールバーボタンも
            // 情報パネルと同じ式でフェードする。背後のグリッドのツールバーと
            // 重なって見づらくなるため。バーの visibility はフリップしない
            //（上記コメントのとおり UIKit 再レイアウトでフラッシュする）。
            //
            // iOS 26 の Liquid Glass バーでは、ボタンのガラスカプセルはシステムが
            // 項目の「共有背景」として描くため、コンテンツへの .opacity では
            // グリフしか消えない。sharedBackgroundVisibility(.hidden) で共有背景を
            // 外し、自前の glassEffect 円をコンテンツ側に持たせてグリフごと
            // フェードできるようにする（fadingToolbarButton）。
            if #available(iOS 26, *) {
                ToolbarItem(placement: .navigationBarLeading) {
                    fadingToolbarButton { closeButtonCore }
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .navigationBarTrailing) {
                    fadingToolbarButton { shareButtonCore }
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .navigationBarTrailing) {
                    fadingToolbarButton { menuButtonCore }
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                // iOS 18–25 はシステムのカプセルが無いため、コンテンツの
                // フェードだけで足りる。
                ToolbarItem(placement: .navigationBarLeading) {
                    fadingToolbarButton { closeButtonCore }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    fadingToolbarButton { shareButtonCore }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    fadingToolbarButton { menuButtonCore }
                }
            }
        }
        .confirmationDialog(
            String(localized: "delete.ios.confirm.title", defaultValue: "Move to Trash?"),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete"), role: .destructive) {
                deleteCurrentGroup()
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "delete.ios.confirm.message", defaultValue: "This cannot be undone."))
        }
        .alert(
            String(localized: "alert.jpg_embed_first.title",
                   defaultValue: "Write Metadata into JPEG?"),
            isPresented: $showEmbedWarning
        ) {
            Button(String(localized: "Yes"), role: .destructive) {
                UserDefaults.standard.set(true, forKey: JpgMetadataDefaults.hasShownJpgEmbedWarningKey)
                if let pending = pendingWriteEntry, let db {
                    pendingWriteEntry = nil
                    let newXmp = pending.xmp
                    let targetIDs = pending.targetIDs
                    Task {
                        _ = await BridgeCore.writeXmp(url: pending.url, xmp: newXmp,
                                                      db: db, jpgWriteMode: .embed,
                                                      captionPresent: false)
                        for targetID in targetIDs where targetID != pending.id {
                            guard let te = scanStore.entries[targetID] else { continue }
                            var tXmp = ratings[targetID] ?? XmpData()
                            tXmp.rating = newXmp.rating
                            tXmp.label = newXmp.label
                            ratings[targetID] = tXmp
                            _ = await BridgeCore.writeXmp(url: te.url, xmp: tXmp, db: db,
                                                          jpgWriteMode: .embed,
                                                          captionPresent: false)
                        }
                    }
                }
            }
            Button(String(localized: "No"), role: .cancel) {
                cancelPendingWrite()
            }
        } message: {
            Text(String(localized: "alert.jpg_embed_first.message",
                        defaultValue: "Rating will be written directly into the JPEG file. The original file will be modified. You can switch to Sidecar mode in Settings."))
        }
        .statusBarHidden(isFullscreen)
        // UIHostingController の UIKit 層の backgroundColor を透明にする。
        // SwiftUI の .background(.clear) だけでは UIKit 層が残るため UIViewRepresentable で直接上書きする。
        .background(ClearHostingBackground())
    }

    // MARK: - Toolbar buttons（スワイプ dismiss 連動フェード）

    private var closeButtonCore: some View {
        Button { onClose() } label: {
            Image(systemName: "xmark")
        }
    }

    private var shareButtonCore: some View {
        Button {
            shareCurrent()
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .disabled(current == nil)
    }

    private var menuButtonCore: some View {
        Menu {
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label(String(localized: "Delete"), systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .disabled(current == nil)
    }

    /// ツールバーボタンを情報パネル（グループ・星評価/ラベル）と同じ式でフェードさせる。
    /// - スワイプ中: dismissInfoOpacity（ドラッグ距離 0→100pt で 1→0、ピーク保持）
    /// - 閉じアニメーション中: isClosing で easeOut フェード
    /// iOS 26 はシステムの共有ガラス背景を外している（sharedBackgroundVisibility(.hidden)）
    /// ため、自前の glassEffect 円（adaptiveGlass）を持たせてグリフと一体でフェードする。
    @ViewBuilder
    private func fadingToolbarButton(@ViewBuilder _ content: () -> some View) -> some View {
        if #available(iOS 26, *) {
            content()
                .frame(width: 38, height: 38)
                .contentShape(Circle())
                .adaptiveGlass(cornerRadius: 19)
                .opacity(isClosing ? 0 : dismissInfoOpacity)
                .animation(.easeOut(duration: 0.1), value: isClosing)
        } else {
            content()
                .opacity(isClosing ? 0 : dismissInfoOpacity)
                .animation(.easeOut(duration: 0.1), value: isClosing)
        }
    }

    /// フル解像度未ロード中に body 評価のたび UIImage(data:) を作り直すと、
    /// ZoomableImageView.updateUIView の `!==` 比較が外れて setZoomScale(1.0) が走り、
    /// スキャン中（@Observable 更新が頻発する間）はピンチズームが勝手に戻ってしまう。
    /// 同じ id・同じデータの間は同一インスタンスを返してこれを防ぐ。
    private func decodedThumbImage(for entry: PhotoEntry) -> UIImage? {
        let data = thumbnails[entry.id]
        if decodedThumb.id == entry.id, decodedThumb.data == data {
            return decodedThumb.image
        }
        let img = data.flatMap { UIImage(data: $0) }
        decodedThumb.id = entry.id
        decodedThumb.data = data
        decodedThumb.image = img
        return img
    }

    private func imageForGroup(at index: Int) -> UIImage? {
        guard groups.indices.contains(index) else { return nil }
        let g = groups[index]
        guard let repID = g.representativeID ?? g.memberIDs.first,
              let entry = entries[repID] else { return nil }
        return fullResCache.first(where: { $0.id == entry.id })?.image
            ?? thumbnails[entry.id].flatMap { UIImage(data: $0) }
    }

    @ViewBuilder
    private func photoImage(
        entry: PhotoEntry,
        navDragOffset: Binding<CGFloat>,
        screenWidth: CGFloat,
        canNavigatePrev: Bool,
        canNavigateNext: Bool,
        onNavigate: @escaping (Int) -> Void,
        onDismiss: @escaping () -> Void
    ) -> some View {
        let cached = showRendered ? rawRendered : fullResCache.first(where: { $0.id == entry.id })?.image
        let thumb  = decodedThumbImage(for: entry)
        let display = cached ?? thumb

        ZStack(alignment: .bottomLeading) {
            if let img = display {
                ZoomableImageView(
                    uiImage: img,
                    isZoomed: $isImageZoomed,
                    navDragOffset: navDragOffset,
                    dismissDragOffset: dismissDragOffset,
                    screenWidth: screenWidth,
                    canNavigatePrev: canNavigatePrev,
                    canNavigateNext: canNavigateNext,
                    onNavigate: onNavigate,
                    onDismiss: onDismiss,
                    horizontalPanOnly: UIDevice.current.userInterfaceIdiom == .pad
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) { isFullscreen.toggle() }
                }
                .id(entry.id)
                .blur(radius: (cached == nil && isLoadingFullRes) ? 8 : 0)
                .opacity((cached == nil && isLoadingFullRes) ? 0.6 : 1.0)
                .animation(.easeOut(duration: 0.2), value: cached == nil)
            } else if entry.isRaw && scanStore.isPreviewUnavailable(entry.id) {
                UnavailablePreviewView()
            } else {
                ProgressView()
            }

            if entry.isRaw && !isFullscreen {
                rawStateBadge(entry: entry)
                    .padding(.leading, 12)
                    .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private func rawStateBadge(entry: PhotoEntry) -> some View {
        if isLimitedRawPreview {
            // 非対応フォーマット
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.yellow.opacity(0.85))
                Text(String(localized: "raw.limited.preview.ios.notice",
                            defaultValue: "Embedded thumbnail only — RAW rendering is not supported"))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
        } else if isRendering {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(String(localized: "render.loading", defaultValue: "Rendering…"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
        } else {
            // 埋め込み / レンダリング済 切り替えバッジ
            Button {
                if rawRendered != nil {
                    showRendered.toggle()
                    preferRendered = showRendered  // 埋め込みに戻したら自動レンダリングを解除
                } else {
                    triggerRender(entry: entry)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showRendered ? "wand.and.stars.inverse" : "wand.and.stars")
                        .font(.system(size: 9, weight: .semibold))
                    Text(showRendered
                         ? String(localized: "render.badge.rendered", defaultValue: "Rendered")
                         : String(localized: "render.badge.embedded", defaultValue: "Embedded"))
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
        }
    }

    private var memberStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(members.enumerated()), id: \.element.id) { idx, member in
                    Button { currentIndex = idx } label: {
                        VStack(spacing: 2) {
                            if let data = thumbnails[member.id],
                               let uiImage = UIImage(data: data) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 44, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                            } else {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color.white.opacity(0.1))
                                    .frame(width: 44, height: 44)
                            }
                            Text(member.fileExtension)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        .padding(3)
                        .adaptiveGlass(cornerRadius: 8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(idx == currentIndex ? Color.accentColor : Color.clear, lineWidth: 2)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .adaptiveGlass(cornerRadius: 0)
        .colorScheme(.dark)
    }

    @ViewBuilder
    private func floatingRatingButton(entry: PhotoEntry) -> some View {
        let rating = ratings[entry.id]?.rating ?? 0
        let labelColor = ratings[entry.id]?.label?.color

        Button { showRatingPopup = true } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: rating > 0 ? "star.fill" : "star")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(rating > 0 ? Color.yellow : Color.white)
                    .frame(width: 56, height: 56)
                if let c = labelColor {
                    Circle()
                        .fill(c)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
                        .offset(x: 2, y: 2)
                }
            }
            .adaptiveGlass(cornerRadius: 28)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Rating and Label"))
        .popover(isPresented: $showRatingPopup) {
            let previousXmp = ratings[entry.id]
            let binding = Binding<XmpData>(
                get: { ratings[entry.id] ?? XmpData() },
                set: { ratings[entry.id] = $0 }
            )
            RatingBarView(entry: entry, xmp: binding) { newXmp in
                commitRating(entry: entry, newXmp: newXmp, previousXmp: previousXmp)
            }
            .padding(8)
            .presentationCompactAdaptation(.popover)
        }
    }

    private func triggerRender(entry: PhotoEntry) {
        guard let db else { return }
        preferRendered = true
        let targetID = entry.id
        Task {
            isRendering = true
            defer { isRendering = false }
            if let (cgImage, _) = await RAWRenderPipeline.shared.render(
                url: entry.url, target: .viewer, db: db
            ) {
                guard current?.id == targetID else { return }
                rawRendered = UIImage(cgImage: cgImage)
                showRendered = true
            }
        }
    }

    private func cancelPendingWrite() {
        guard let pending = pendingWriteEntry else { return }
        pendingWriteEntry = nil
        if let previousXmp = pending.previousXmp {
            ratings[pending.id] = previousXmp
        } else {
            ratings.removeValue(forKey: pending.id)
        }
    }

    // MARK: - Full-resolution loading

    /// フル解像度キャッシュのバイト予算。スナップショットを持たず追加のたびに評価する。
    /// スキャン等で残量が減っていれば次の追加時に予算が縮み、キャッシュ側が先に譲る。
    /// - physicalMemory / 8: デバイス RAM 規模に応じた静的上限
    /// - os_proc_available_memory() / 2: jetsam までの実残量の半分（ヘッドルーム確保）
    /// - 下限 256MB: API が 0 を返す環境（simulator 等）での thrash 防止
    private static func fullResBudgetBytes() -> Int {
        let physCap = ProcessInfo.processInfo.physicalMemory / 8
        let avail = UInt64(max(0, os_proc_available_memory())) / 2
        return max(Int(min(physCap, avail)), 256 * 1024 * 1024)
    }

    /// キャッシュミス時のみロードし、メモリ予算内で LRU 保持する。
    /// 退避時は表示中の写真（current）を保護して最古の非表示エントリから落とす。
    /// 無条件 FIFO だと、4メンバー以上のグループでは兄弟ロード＋隣接プリフェッチが
    /// 表示中の写真自身を追い出し、サムネイル表示に戻ったまま固定される
    /// （再ロード機構がないため）。枚数固定だと画素数次第で合計サイズが数倍ぶれるので
    /// バイト予算で判定する（24MP ≈ 96MB、61MP ≈ 241MB）。
    @MainActor
    private func loadAndCache(entry: PhotoEntry) async {
        if let idx = fullResCache.firstIndex(where: { $0.id == entry.id }) {
            // 参照されたエントリを末尾へ移動（LRU）し、退避されにくくする
            let hit = fullResCache.remove(at: idx)
            fullResCache.append(hit)
            return
        }
        if Task.isCancelled { return }
        if inFlightFullRes.contains(entry.id) { return }
        inFlightFullRes.insert(entry.id)
        defer { inFlightFullRes.remove(entry.id) }
        isLoadingFullRes = true
        defer { isLoadingFullRes = false }
        if let img = await decodeFullRes(entry: entry) {
            let cost = Int(img.size.width) * Int(img.size.height) * 4
            let budget = Self.fullResBudgetBytes()
            var total = fullResCache.reduce(0) { $0 + $1.cost }
            let protectedID = current?.id
            // current だけは予算超過でも退避しない（表示品質の最低保証）
            while total + cost > budget,
                  let evictIdx = fullResCache.firstIndex(where: { $0.id != protectedID }) {
                total -= fullResCache[evictIdx].cost
                fullResCache.remove(at: evictIdx)
            }
            fullResCache.append(FullResEntry(id: entry.id, image: img, cost: cost))
        } else if entry.isRaw, thumbnails[entry.id] == nil {
            // フル解像度もサムネも得られない RAW はプレビュー不可として記録（プレースホルダ表示）。
            scanStore.notePreviewUnavailable(id: entry.id, generation: scanStore.scanGeneration)
        }
    }

    /// 前後グループの代表画像をバックグラウンドで先読み。
    /// Task は @MainActor context を継承するため、loadAndCache は Main Actor 上で実行される。
    /// 生成した Task は auxLoadTasks に登録し、写真が変わったらキャンセルする。
    private func prefetchNeighbors() {
        for delta in [-1, 1] {
            let idx = currentGroupIndex + delta
            guard groups.indices.contains(idx) else { continue }
            let g = groups[idx]
            guard let repID = g.representativeID ?? g.memberIDs.first,
                  let entry = entries[repID],
                  !fullResCache.contains(where: { $0.id == entry.id }) else { continue }
            auxLoadTasks.append(Task(priority: .background) {
                await loadAndCache(entry: entry)
            })
        }
    }

    /// RAW は埋め込み JPEG を抽出（limiter 外）→デコード（limiter 内）。
    /// 非 RAW は URL から直接デコード（limiter 内）。
    /// macOS LargeImageDecoder と同じ構成で IOSurface 枯渇を防ぐ。
    private func decodeFullRes(entry: PhotoEntry) async -> UIImage? {
        let url = entry.url
        if entry.isRaw {
            guard let data = await BridgeCore.extractRawJpeg(url: url, quality: .full) else { return nil }
            return try? await fullResLimiter.run { () async -> UIImage? in
                // limiter 待機中にキャンセルされた場合は CancellationError が投げられるが、
                // スロット取得直後にキャンセルされたケースはここで弾く（無駄なデコード防止）
                if Task.isCancelled { return nil }
                return await Task.detached(priority: .userInitiated) {
                    let opts = [kCGImageSourceShouldCache: false] as CFDictionary
                    guard let src = CGImageSourceCreateWithData(data as CFData, opts),
                          let cgImg = CGImageSourceCreateImageAtIndex(src, 0, opts) else { return nil }
                    let orient = ThumbnailService.readRawOrientation(url: url)
                    let uiOrient = ThumbnailService.uiImageOrientation(from: orient)
                    return UIImage(cgImage: cgImg, scale: 1.0, orientation: uiOrient)
                }.value
            }
        }
        return try? await fullResLimiter.run { () async -> UIImage? in
            if Task.isCancelled { return nil }
            return await Task.detached(priority: .userInitiated) {
                guard let data = try? Data(contentsOf: url) else { return nil }
                return UIImage(data: data)
            }.value
        }
    }

    // MARK: - Image Stack

    @ViewBuilder
    private func imageViewport(entry: PhotoEntry) -> some View {
        GeometryReader { imageGeo in
            imageZStack(entry: entry, size: imageGeo.size)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Preference は offset 適用前に報告し capturedImageFrame を自然座標に保つ。
        .overlay(GeometryReader { r in
            Color.clear.preference(
                key: DetailImageViewportFrameKey.self,
                value: r.frame(in: .global))
        })
        // GeometryReader の外で offset を適用することで SwiftUI のアニメーション
        // コンテキストが正しく伝播し、スワイプ→セルへのアニメーションが連続する。
        .offset(x: dismissDragOffset.wrappedValue.width,
                y: dismissDragOffset.wrappedValue.height)
    }

    @ViewBuilder
    private func imageZStack(entry: PhotoEntry, size: CGSize) -> some View {
        ZStack {
            if dragOffset > 2, let prevImg = imageForGroup(at: currentGroupIndex - 1) {
                Image(uiImage: prevImg)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size.width, height: size.height)
                    .offset(x: dragOffset - size.width)
            }

            photoImage(
                entry: entry,
                navDragOffset: $dragOffset,
                screenWidth: size.width,
                canNavigatePrev: currentGroupIndex > 0,
                canNavigateNext: currentGroupIndex < groups.count - 1,
                onNavigate: { delta in
                    // 送りアニメーション中の再フリックは弾く。受けると canNavigate が
                    // 古い index で評価され、末尾で index が範囲外（クランプで表示は
                    // 保たれるが次の戻りスワイプが空振りする）になる。
                    guard !isPaging, groups.indices.contains(currentGroupIndex + delta) else { return }
                    isPaging = true
                    let targetOffset = delta < 0 ? size.width : -size.width
                    withAnimation(.easeOut(duration: 0.22)) { dragOffset = targetOffset }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                        // アニメーション中に groups が変わった可能性があるため適用時に再クランプ
                        currentGroupIndex = max(0, min(currentGroupIndex + delta, max(0, groups.count - 1)))
                        dragOffset = 0
                        isPaging = false
                    }
                },
                onDismiss: { onClose() }
            )
            .offset(x: dragOffset)

            if dragOffset < -2, let nextImg = imageForGroup(at: currentGroupIndex + 1) {
                Image(uiImage: nextImg)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size.width, height: size.height)
                    .offset(x: dragOffset + size.width)
            }
        }
        .clipped()
        .contentShape(Rectangle())
    }

    // MARK: - Landscape Info Panel

    // MARK: - Portrait info column (image bounded above)

    /// 縦向き用。グループ・星評価・ラベル・EXIF を個別ガラスカードとして浮かせる。
    /// 背景は透明なのでズームディスミス中に背後のグリッドが見える。
    @ViewBuilder
    private func portraitInfoColumn(entry: PhotoEntry, screenHeight: CGFloat) -> some View {
        let previousXmp = ratings[entry.id]
        let binding = Binding<XmpData>(
            get: { ratings[entry.id] ?? XmpData() },
            set: { ratings[entry.id] = $0 }
        )
        let ratingDisabled = scanStore.isScanning && !scanStore.isExifReady

        VStack(spacing: 10) {
            // グループ（常に表示: メンバーが1枚でも情報レイヤーの高さを固定する）
            memberStrip
                .clipShape(RoundedRectangle(cornerRadius: 12))
            // 星評価 + カラーラベルを横並び
            HStack(spacing: 8) {
                RatingStarsControl(xmp: binding) { newXmp in
                    commitRating(entry: entry, newXmp: newXmp, previousXmp: previousXmp)
                }
                .frame(maxWidth: .infinity)
                ColorLabelControl(xmp: binding) { newXmp in
                    commitRating(entry: entry, newXmp: newXmp, previousXmp: previousXmp)
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(ratingDisabled)
            .opacity(ratingDisabled ? 0.35 : 1.0)
            // EXIF InfoCard（横幅フル使用・ヒストグラム高さは画面サイズ比例）
            PhotoInfoCard(
                entry: entry,
                exif: scanStore.exifs[entry.id],
                xmp: ratings[entry.id],
                thumbnailData: thumbnails[entry.id],
                isLoading: ratingDisabled,
                histogramHeight: max(44, screenHeight * 0.07)
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .colorScheme(.dark)
    }

    @ViewBuilder
    private func landscapeInfoPanel(entry: PhotoEntry) -> some View {
        let previousXmp = ratings[entry.id]
        let binding = Binding<XmpData>(
            get: { ratings[entry.id] ?? XmpData() },
            set: { ratings[entry.id] = $0 }
        )
        VStack(spacing: 0) {
            if members.count > 1 { memberStrip }

            VStack(spacing: 0) {
                RatingBarView(entry: entry, xmp: binding) { newXmp in
                    commitRating(entry: entry, newXmp: newXmp, previousXmp: previousXmp)
                }
                .disabled(scanStore.isScanning && !scanStore.isExifReady)
                .opacity(scanStore.isScanning && !scanStore.isExifReady ? 0.35 : 1.0)

                Color.white.opacity(0.12).frame(height: 0.5)
                    .padding(.horizontal, 12)

                PhotoInfoCard(
                    entry: entry,
                    exif: scanStore.exifs[entry.id],
                    xmp: ratings[entry.id],
                    thumbnailData: thumbnails[entry.id],
                    isLoading: scanStore.isScanning && !scanStore.isExifReady,
                    twoColumnExif: true
                )
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 20)
            }
        }
        .containerRelativeFrame(.horizontal) { length, _ in
            min(300, max(220, length * 0.38))
        }
        .background(Color.black)
        .clipped()
        .colorScheme(.dark)
    }

    // MARK: - Fullscreen Info Panel

    private var infoToggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) { showInfoPanel.toggle() }
        } label: {
            Image(systemName: showInfoPanel ? "chevron.right" : "info.circle")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 36, height: 36)
                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func fullscreenInfoPanel(entry: PhotoEntry) -> some View {
        let previousXmp = ratings[entry.id]
        let binding = Binding<XmpData>(
            get: { ratings[entry.id] ?? XmpData() },
            set: { ratings[entry.id] = $0 }
        )
        HStack(spacing: 0) {
            // パネル外タップでパネルを閉じる（ZoomableImageView へ透過させない）
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.25)) { showInfoPanel = false }
                }
            ScrollView {
                VStack(spacing: 0) {
                    RatingBarView(entry: entry, xmp: binding) { newXmp in
                        commitRating(entry: entry, newXmp: newXmp, previousXmp: previousXmp)
                    }
                    .disabled(scanStore.isScanning && !scanStore.isExifReady)
                    .opacity(scanStore.isScanning && !scanStore.isExifReady ? 0.35 : 1.0)

                    Color.white.opacity(0.15).frame(height: 0.5)
                        .padding(.horizontal, 16)

                    PhotoInfoCard(
                        entry: entry,
                        exif: scanStore.exifs[entry.id],
                        xmp: ratings[entry.id],
                        thumbnailData: thumbnails[entry.id],
                        isLoading: scanStore.isScanning && !scanStore.isExifReady
                    )
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 20)
                }
            }
            .frame(width: 290)
            .background(Color.black.opacity(0.6))
            .colorScheme(.dark)
        }
        .frame(maxHeight: .infinity)
        .transition(.move(edge: .trailing))
    }

    // MARK: - Rating Commit

    private func commitRating(entry: PhotoEntry, newXmp: XmpData, previousXmp: XmpData?) {
        guard let db else { return }
        let url = entry.url
        let isJpg = ["jpg", "jpeg"].contains(url.pathExtension.lowercased())
        let targetIDs = scanStore.groupTargets(for: entry.id, xmps: ratings)
        if jpgWriteMode == .embed && isJpg && !JpgMetadataDefaults.hasShownJpgEmbedWarning() {
            pendingWriteEntry = (id: entry.id, url: url, xmp: newXmp,
                                previousXmp: previousXmp, targetIDs: targetIDs)
            showEmbedWarning = true
        } else {
            ratingWriteTask?.cancel()
            ratingWriteTask = Task {
                guard !Task.isCancelled else { return }
                _ = await BridgeCore.writeXmp(url: url, xmp: newXmp, db: db,
                                              jpgWriteMode: jpgWriteMode,
                                              captionPresent: false)
                guard !Task.isCancelled else { return }
                for targetID in targetIDs where targetID != entry.id {
                    // 連続レート変更で旧 Task がキャンセルされた後も仲間ファイルへ
                    // 旧値を書き続けないよう、各イテレーションで確認する
                    guard !Task.isCancelled else { return }
                    guard let te = scanStore.entries[targetID] else { continue }
                    var tXmp = ratings[targetID] ?? XmpData()
                    tXmp.rating = newXmp.rating
                    tXmp.label = newXmp.label
                    ratings[targetID] = tXmp
                    _ = await BridgeCore.writeXmp(url: te.url, xmp: tXmp, db: db,
                                                  jpgWriteMode: jpgWriteMode,
                                                  captionPresent: false)
                }
            }
        }
    }

    /// groups 配列の変化（スキャン進行・フィルタ変動・削除）に対して、表示中のグループを
    /// id で追跡して currentGroupIndex / currentIndex を再解決する。index のままだと
    /// 挿入・脱落のたびに表示中の写真が別の写真へズレる（特にレーティングフィルタ ON 中に
    /// 現在写真を低評価にすると即座に発症していた）。
    private func reResolveIndices(from oldGroups: [ShotGroup], to newGroups: [ShotGroup]) {
        guard !oldGroups.isEmpty, !newGroups.isEmpty else { return }
        let oldIdx = max(0, min(currentGroupIndex, oldGroups.count - 1))
        let oldGroup = oldGroups[oldIdx]
        if let newIdx = newGroups.firstIndex(where: { $0.id == oldGroup.id }) {
            // 同じグループが残っている: グループ位置とメンバー選択を id で維持する
            let oldMembers = oldGroup.memberIDs.compactMap { entries[$0] }
            let oldMemberID = oldMembers[safe: currentIndex]?.id
            if newIdx != currentGroupIndex { currentGroupIndex = newIdx }
            let newMembers = newGroups[newIdx].memberIDs.compactMap { entries[$0] }
            if let mid = oldMemberID, let mIdx = newMembers.firstIndex(where: { $0.id == mid }) {
                if mIdx != currentIndex { currentIndex = mIdx }
            } else if currentIndex >= newMembers.count {
                currentIndex = max(0, newMembers.count - 1)
            }
        } else {
            // 表示中のグループが消えた（削除・フィルタ脱落）: 近い位置へクランプする。
            // group.id が変わるため onChange(of: group.id) が代表メンバーへリセットし、
            // 親へも通知される。
            currentGroupIndex = max(0, min(currentGroupIndex, newGroups.count - 1))
        }
    }

    private func deleteCurrentGroup() {
        scanStore.deleteGroup(group)
        onClose()
    }

    private func shareCurrent() {
        guard let entry = current else { return }
        let preview = thumbnails[entry.id].flatMap { UIImage(data: $0) }
        presentShareSheet(urls: [entry.url], previewImage: preview, title: entry.filename)
    }

}

// MARK: - UIKit transparent background helper

/// UIHostingController の UIKit 層の backgroundColor を透明にする UIViewRepresentable。
/// DispatchQueue.main.async は遷移速度によって階層構築前に発火するため、
/// UIView サブクラスで didMoveToWindow / layoutSubviews をオーバーライドし
/// 確実なタイミングで繰り返し親の背景をクリアする。
private struct ClearHostingBackground: UIViewRepresentable {
    func makeUIView(context: Context) -> HostingClearView { HostingClearView() }
    func updateUIView(_ uiView: HostingClearView, context: Context) {}
}

private final class HostingClearView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError() }

    /// ウィンドウに接続された確実なタイミングで親をクリア。
    override func didMoveToWindow() {
        super.didMoveToWindow()
        clearHostingParents()
    }

    /// アニメーションフレームごとに呼ばれるので遷移速度に依存しない。
    override func layoutSubviews() {
        super.layoutSubviews()
        clearHostingParents()
    }

    private func clearHostingParents() {
        var parent = superview
        while let p = parent {
            if p.backgroundColor != .clear {
                let cls = NSStringFromClass(type(of: p))
                // UIHostingController 系の view に加え、
                // UINavigationController の view も透明化する。
                // デフォルトの .systemBackground（白）がレターボックス領域から
                // 透けて見えるのを防ぐため。
                // 注意: SwiftUI は state 更新のたびに背景色を再アサートするため、
                // この透明化は teardown 時には間に合わない。閉じアニメーションの
                // フラッシュ対策は「除去コミットに animation transaction を置かない」
                // こと（knowledge/ipad-dismiss-flash-investigation.md）。
                if cls.contains("Hosting") || cls.contains("NavigationController") {
                    p.backgroundColor = .clear
                }
            }
            parent = p.superview
        }
    }
}

// MARK: - Info Card

private struct PhotoInfoCard: View {
    let entry: PhotoEntry
    let exif: ExifData?
    let xmp: XmpData?
    let thumbnailData: Data?
    var isLoading: Bool = false
    /// ヒストグラムの表示高さ。縦レイアウトでは呼び出し元が画面高さから算出して渡す。
    var histogramHeight: CGFloat = 48
    /// true のとき EXIF 項目を 2 列 × 4 行グリッドで表示する（横レイアウト用）。
    var twoColumnExif: Bool = false

    @State private var histogram: RGBHistogram = .empty

    private static let exifFont: Font = .system(size: 14, weight: .medium, design: .monospaced)

    // EXIF datetime は "yyyy:MM:dd HH:mm:ss" 固定フォーマット
    private static let exifDateParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private static let displayDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd  HH:mm:ss"
        return f
    }()

    private var fText: String? { exif?.fnumber }
    private var ssText: String? {
        guard let s = exif?.exposureTime else { return nil }
        return s.components(separatedBy: " ").first ?? s
    }
    private var isoText: String? { exif?.iso.map { "ISO \($0)" } }
    private var focalText: String? {
        guard let mm = exif?.effectiveFocalMm else { return nil }
        let v = mm == mm.rounded() ? "\(Int(mm))" : String(format: "%.1f", mm)
        return "\(v) mm"
    }
    private var evText: String? { exif?.exposureBias }
    private var datetimeText: String? {
        guard let raw = exif?.datetime,
              let date = Self.exifDateParser.date(from: raw) else { return exif?.datetime }
        return Self.displayDateFormatter.string(from: date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.filename)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 0) {
                HStack {
                    if isLoading && exif == nil {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.15))
                            .frame(width: 130, height: 14)
                            .shimmer()
                    } else {
                        Text(exif?.cameraName ?? "—")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(entry.fileExtension.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Color.white.opacity(0.18),
                            in: RoundedRectangle(cornerRadius: 4)
                        )
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)

                // レンズ名行は常に同じ高さを確保してレイアウトを安定させる。
                // lens が nil のときは不可視テキストで行高を維持する。
                HStack {
                    if isLoading && exif == nil {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.12))
                            .frame(width: 190, height: 11)
                            .shimmer()
                    } else {
                        Text(exif?.lensName ?? " ")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(exif?.lensName != nil ? 0.75 : 0))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 10)

                // Histogram (JPG/SOOC は RGB、RAW は灰色プレースホルダー)
                Color.white.opacity(0.12).frame(height: 0.5)
                histogramView
                    .frame(height: histogramHeight)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)

                Color.white.opacity(0.12).frame(height: 0.5)

                if twoColumnExif {
                    // 2列 × 4行グリッド（横レイアウト用）
                    // 上半分: 露出パラメータ / 下半分: ファイル情報
                    HStack(spacing: 0) { exifCell(isoText); vSep; exifCell(fText) }
                        .padding(.vertical, 10)
                    Color.white.opacity(0.12).frame(height: 0.5)
                    HStack(spacing: 0) { exifCell(ssText); vSep; exifCell(evText) }
                        .padding(.vertical, 10)
                    Color.white.opacity(0.12).frame(height: 0.5)
                    HStack(spacing: 0) { exifCell(focalText); vSep; exifCell(datetimeText) }
                        .padding(.vertical, 10)
                    Color.white.opacity(0.12).frame(height: 0.5)
                    HStack(spacing: 0) {
                        exifCell(entry.fileSize > 0 ? entry.formattedFileSize : nil)
                        vSep
                        exifCell(exif?.resolutionString)
                    }
                    .padding(.vertical, 10)
                } else {
                    // 5列 + 3列の 2行レイアウト（縦レイアウト用）
                    HStack(spacing: 0) {
                        exifCell(isoText)
                        vSep
                        exifCell(focalText)
                        vSep
                        exifCell(evText)
                        vSep
                        exifCell(fText)
                        vSep
                        exifCell(ssText)
                    }
                    .padding(.vertical, 10)
                    Color.white.opacity(0.12).frame(height: 0.5)
                    HStack(spacing: 0) {
                        exifCell(datetimeText)
                        vSep
                        exifCell(entry.fileSize > 0 ? entry.formattedFileSize : nil)
                        vSep
                        exifCell(exif?.resolutionString)
                    }
                    .padding(.vertical, 10)
                }
            }
            .adaptiveGlass(cornerRadius: 12)
            .colorScheme(.dark)
        }
        .task(id: entry.id) {
            guard !entry.isRaw, let data = thumbnailData,
                  let uiImage = UIImage(data: data),
                  let cgImage = uiImage.cgImage else {
                histogram = .empty
                return
            }
            histogram = await computeRGBHistogram(image: cgImage, bins: 64)
        }
    }

    @ViewBuilder
    private var histogramView: some View {
        if !entry.isRaw && !histogram.isEmpty {
            RGBHistogramView(histogram: histogram)
        } else if isLoading {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.1))
                .shimmer()
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.06))
        }
    }

    private var vSep: some View {
        Color.white.opacity(0.15).frame(width: 0.5, height: 14)
    }

    private func exifCell(_ value: String?) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            if let value {
                Text(value)
                    .font(Self.exifFont)
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } else if isLoading {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 44, height: 11)
                    .shimmer()
            } else {
                Text("—")
                    .font(Self.exifFont)
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - RGB Histogram

private struct RGBHistogram {
    let r: [Int]
    let g: [Int]
    let b: [Int]
    var isEmpty: Bool { r.isEmpty }
    static let empty = RGBHistogram(r: [], g: [], b: [])
}

private struct RGBHistogramView: View {
    let histogram: RGBHistogram

    private var maxVal: Int {
        let all = histogram.r + histogram.g + histogram.b
        return max(all.max() ?? 1, 1)
    }

    var body: some View {
        Canvas { ctx, size in
            guard !histogram.isEmpty else { return }
            let mv = CGFloat(maxVal)
            let n = histogram.r.count
            guard n > 0 else { return }

            func points(_ counts: [Int]) -> [CGPoint] {
                let barW = size.width / CGFloat(n)
                return counts.enumerated().map { i, c in
                    CGPoint(x: (CGFloat(i) + 0.5) * barW,
                            y: size.height - size.height * CGFloat(c) / mv)
                }
            }

            ctx.fill(areaPath(points(histogram.b), size: size), with: .color(.blue.opacity(0.85)))
            ctx.blendMode = .screen
            ctx.fill(areaPath(points(histogram.g), size: size), with: .color(.green.opacity(0.85)))
            ctx.fill(areaPath(points(histogram.r), size: size), with: .color(.red.opacity(0.85)))
        }
        .background(.black.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func areaPath(_ pts: [CGPoint], size: CGSize) -> Path {
        var ext = [CGPoint(x: 0, y: size.height)]
        ext.append(contentsOf: pts)
        ext.append(CGPoint(x: size.width, y: size.height))
        guard ext.count >= 2 else { return Path() }
        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height))
        path.addLine(to: ext[0])
        for i in 0..<(ext.count - 1) {
            let (c1, c2) = catmullRomCP(ext, i: i, height: size.height)
            path.addCurve(to: ext[i + 1], control1: c1, control2: c2)
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        return path
    }

    private func catmullRomCP(_ pts: [CGPoint], i: Int, height: CGFloat) -> (CGPoint, CGPoint) {
        let p0 = pts[max(0, i - 1)]
        let p1 = pts[i]
        let p2 = pts[i + 1]
        let p3 = pts[min(pts.count - 1, i + 2)]
        let clamp = { (y: CGFloat) in max(0, min(height, y)) }
        let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: clamp(p1.y + (p2.y - p0.y) / 6))
        let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: clamp(p2.y - (p3.y - p1.y) / 6))
        return (c1, c2)
    }
}

private func computeRGBHistogram(image: CGImage, bins: Int) async -> RGBHistogram {
    return await Task.detached(priority: .utility) {
        let maxSide = 1024
        let srcW = image.width, srcH = image.height
        let scale = CGFloat(maxSide) / CGFloat(max(srcW, srcH))
        let w = max(1, Int(CGFloat(srcW) * scale))
        let h = max(1, Int(CGFloat(srcH) * scale))
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = CGImageAlphaInfo.noneSkipFirst.rawValue
                               | CGBitmapInfo.byteOrder32Little.rawValue
        var raw = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &raw, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: cs, bitmapInfo: bitmapInfo
        ) else { return .empty }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var r = [Int](repeating: 0, count: bins)
        var g = [Int](repeating: 0, count: bins)
        var b = [Int](repeating: 0, count: bins)
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            b[min(Int(raw[i])     * bins / 256, bins - 1)] += 1
            g[min(Int(raw[i + 1]) * bins / 256, bins - 1)] += 1
            r[min(Int(raw[i + 2]) * bins / 256, bins - 1)] += 1
        }
        return RGBHistogram(r: r, g: g, b: b)
    }.value
}

// MARK: - Zoomable Image

// UIScrollView をラップして Photos アプリ相当のズーム・パン操作を実現する。
// isScrollEnabled をズーム状態に連動させることで、zoom=1x 時に親の
// DragGesture（スワイプナビ）が UIScrollView の pan に妨げられない。
private final class ImageScrollView: UIScrollView {
    private var prevBoundsSize: CGSize = .zero
    var onLayoutChange: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        let sz = bounds.size
        guard sz != prevBoundsSize, sz.width > 0, sz.height > 0 else { return }
        prevBoundsSize = sz
        onLayoutChange?()
    }
}

private struct ZoomableImageView: UIViewRepresentable {
    let uiImage: UIImage
    @Binding var isZoomed: Bool
    @Binding var navDragOffset: CGFloat
    var dismissDragOffset: Binding<CGSize> = .constant(.zero)
    var screenWidth: CGFloat
    var canNavigatePrev: Bool
    var canNavigateNext: Bool
    var onNavigate: ((Int) -> Void)?
    var onDismiss: (() -> Void)?
    /// iPad では縦スワイプで dismiss ジェスチャーを開始し、その後上下左右に追従する。
    var horizontalPanOnly: Bool = false
    var onSingleTap: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isZoomed: $isZoomed,
            navDragOffset: $navDragOffset,
            dismissDragOffset: dismissDragOffset,
            screenWidth: screenWidth,
            canNavigatePrev: canNavigatePrev,
            canNavigateNext: canNavigateNext,
            onNavigate: onNavigate,
            onDismiss: onDismiss,
            horizontalPanOnly: horizontalPanOnly,
            onSingleTap: onSingleTap
        )
    }

    func makeUIView(context: Context) -> ImageScrollView {
        let sv = ImageScrollView()
        sv.delegate = context.coordinator
        sv.minimumZoomScale = 1.0
        sv.maximumZoomScale = 8.0
        sv.showsVerticalScrollIndicator = false
        sv.showsHorizontalScrollIndicator = false
        sv.contentInsetAdjustmentBehavior = .never
        sv.backgroundColor = .clear
        sv.bouncesZoom = true
        sv.isScrollEnabled = false

        let iv = UIImageView(image: uiImage)
        iv.contentMode = .scaleAspectFit
        iv.isUserInteractionEnabled = false
        sv.addSubview(iv)
        context.coordinator.imageView = iv

        sv.onLayoutChange = { [weak sv] in
            guard let sv else { return }
            context.coordinator.recalculateLayout(sv)
        }

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        sv.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSingleTap(_:))
        )
        // require(toFail:) は ~500ms の遅延を生むため使わず、handleSingleTap 内で手動検出する
        sv.addGestureRecognizer(singleTap)

        let navPan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleNavPan(_:))
        )
        navPan.delegate = context.coordinator
        sv.addGestureRecognizer(navPan)
        context.coordinator.navPanGesture = navPan

        return sv
    }

    static func dismantleUIView(_ uiView: ImageScrollView, coordinator: Coordinator) {
        coordinator.pendingSingleTap?.cancel()
        coordinator.pendingSingleTap = nil
    }

    func updateUIView(_ sv: ImageScrollView, context: Context) {
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.screenWidth = screenWidth
        context.coordinator.canNavigatePrev = canNavigatePrev
        context.coordinator.canNavigateNext = canNavigateNext
        context.coordinator.onNavigate = onNavigate
        context.coordinator.onDismiss = onDismiss
        context.coordinator.horizontalPanOnly = horizontalPanOnly
        context.coordinator.navDragOffset = $navDragOffset
        context.coordinator.dismissDragOffset = dismissDragOffset
        guard context.coordinator.imageView?.image !== uiImage else { return }
        context.coordinator.imageView?.image = uiImage
        context.coordinator.recalculateLayout(sv)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var isZoomed: Binding<Bool>
        var navDragOffset: Binding<CGFloat> = .constant(0)
        var dismissDragOffset: Binding<CGSize> = .constant(.zero)
        var screenWidth: CGFloat = 390
        var canNavigatePrev: Bool = false
        var canNavigateNext: Bool = false
        var onNavigate: ((Int) -> Void)?
        var onDismiss: (() -> Void)?
        var horizontalPanOnly: Bool = false
        var onSingleTap: (() -> Void)?
        weak var imageView: UIImageView?
        private var lastSingleTapTime: Date? = nil
        fileprivate var pendingSingleTap: DispatchWorkItem? = nil
        weak var navPanGesture: UIPanGestureRecognizer?
        private var navDragAxis: NavAxis = .undecided
        private enum NavAxis { case undecided, horizontal, vertical }
        /// true の間は上下左右すべての移動を dismiss ジェスチャーとして追従する。
        private var isDismissGestureActive = false
        /// 開始点からの距離が 100pt を超えた瞬間に立てるフラグ。
        /// 指を元の位置に戻しても dismiss 確定を維持するために使う。
        private var hasExceededSwipeThreshold = false

        init(
            isZoomed: Binding<Bool>,
            navDragOffset: Binding<CGFloat>,
            dismissDragOffset: Binding<CGSize>,
            screenWidth: CGFloat,
            canNavigatePrev: Bool,
            canNavigateNext: Bool,
            onNavigate: ((Int) -> Void)?,
            onDismiss: (() -> Void)?,
            horizontalPanOnly: Bool,
            onSingleTap: (() -> Void)?
        ) {
            self.isZoomed = isZoomed
            self.navDragOffset = navDragOffset
            self.dismissDragOffset = dismissDragOffset
            self.screenWidth = screenWidth
            self.canNavigatePrev = canNavigatePrev
            self.canNavigateNext = canNavigateNext
            self.onNavigate = onNavigate
            self.onDismiss = onDismiss
            self.horizontalPanOnly = horizontalPanOnly
            self.onSingleTap = onSingleTap
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            scrollView.isScrollEnabled = true
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            updateCenterInsets(scrollView)
            let zoomed = scrollView.zoomScale > 1.01
            if isZoomed.wrappedValue != zoomed { isZoomed.wrappedValue = zoomed }
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            if scale <= 1.01 { scrollView.isScrollEnabled = false }
        }

        private func updateCenterInsets(_ scrollView: UIScrollView) {
            guard let iv = imageView else { return }
            let sv = scrollView.bounds.size
            let top  = max(0, (sv.height - iv.frame.height) / 2)
            let left = max(0, (sv.width  - iv.frame.width)  / 2)
            scrollView.contentInset = UIEdgeInsets(top: top, left: left, bottom: top, right: left)
        }

        func recalculateLayout(_ scrollView: UIScrollView) {
            guard let iv = imageView, let img = iv.image else { return }
            let svSize = scrollView.bounds.size
            guard svSize.width > 0, svSize.height > 0 else { return }
            let s = min(svSize.width / img.size.width, svSize.height / img.size.height)
            let fitted = CGSize(width: floor(img.size.width * s), height: floor(img.size.height * s))
            scrollView.setZoomScale(1.0, animated: false)
            iv.frame = CGRect(origin: .zero, size: fitted)
            scrollView.contentSize = fitted
            scrollView.isScrollEnabled = false
            updateCenterInsets(scrollView)
        }

        @objc func handleDoubleTap(_ g: UITapGestureRecognizer) {
            // シングルタップの遅延実行をキャンセル（ダブルタップ優先）
            pendingSingleTap?.cancel()
            pendingSingleTap = nil
            lastSingleTapTime = nil

            guard let sv = g.view as? UIScrollView else { return }
            if sv.zoomScale > 1.01 {
                sv.setZoomScale(1.0, animated: true)
            } else {
                guard let iv = imageView else { return }
                sv.isScrollEnabled = true
                let pt = g.location(in: iv)
                let w = iv.bounds.width  / 3
                let h = iv.bounds.height / 3
                sv.zoom(to: CGRect(x: pt.x - w/2, y: pt.y - h/2, width: w, height: h), animated: true)
            }
        }

        @objc func handleSingleTap(_ g: UITapGestureRecognizer) {
            let now = Date()
            let prev = lastSingleTapTime
            lastSingleTapTime = now

            // 2打目が来た場合は保留中のシングルタップをキャンセルして終了
            if let prev, now.timeIntervalSince(prev) < 0.35 {
                pendingSingleTap?.cancel()
                pendingSingleTap = nil
                lastSingleTapTime = nil
                return
            }

            // 0.25s 後に実行（その間に2打目が来たら上の分岐でキャンセルされる）
            let work = DispatchWorkItem { [weak self] in
                self?.pendingSingleTap = nil
                self?.onSingleTap?()
            }
            pendingSingleTap = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }

        @objc func handleNavPan(_ g: UIPanGestureRecognizer) {
            guard let sv = g.view as? UIScrollView, !sv.isScrollEnabled else {
                if g.state == .began || g.state == .changed {
                    g.setTranslation(.zero, in: g.view)
                }
                // 横パン中にピンチが始まると isScrollEnabled が立ってここへ落ちる。
                // navDragOffset を途中値のまま放置すると、画像が横にズレて隣の写真が
                // 見える状態でズームが継続するため必ず 0 へ戻す。
                if navDragOffset.wrappedValue != 0 {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        navDragOffset.wrappedValue = 0
                    }
                }
                return
            }
            let t = g.translation(in: g.view)
            let vel = g.velocity(in: g.view)
            switch g.state {
            case .began:
                navDragAxis = .undecided
                isDismissGestureActive = false
                hasExceededSwipeThreshold = false
                pendingSingleTap?.cancel()
                pendingSingleTap = nil
            case .changed:
                if isDismissGestureActive && horizontalPanOnly {
                    // dismiss ジェスチャー活性後: 上下左右すべてに指追従
                    dismissDragOffset.wrappedValue = CGSize(width: t.x, height: t.y)
                    // 開始点からの距離が 100pt を超えたらフラグを立てる（一度立ったら下がらない）
                    if !hasExceededSwipeThreshold {
                        let dist = sqrt(t.x * t.x + t.y * t.y)
                        if dist > 100 { hasExceededSwipeThreshold = true }
                    }
                    return
                }
                if navDragAxis == .undecided {
                    if abs(t.x) > abs(t.y) && abs(t.x) > 8 {
                        navDragAxis = .horizontal
                    } else if abs(t.y) > abs(t.x) && abs(t.y) > 8 {
                        navDragAxis = .vertical
                    }
                }
                if navDragAxis == .horizontal {
                    let clampedOffset: CGFloat
                    if t.x > 0 && !canNavigatePrev {
                        clampedOffset = t.x * 0.2
                    } else if t.x < 0 && !canNavigateNext {
                        clampedOffset = t.x * 0.2
                    } else {
                        clampedOffset = t.x
                    }
                    navDragOffset.wrappedValue = clampedOffset
                } else if navDragAxis == .vertical && horizontalPanOnly {
                    // iPad 縦スワイプ開始 → dismiss ジェスチャーを活性化して追従開始
                    isDismissGestureActive = true
                    dismissDragOffset.wrappedValue = CGSize(width: t.x, height: t.y)
                }
            case .ended, .cancelled:
                defer { navDragAxis = .undecided }
                if isDismissGestureActive && horizontalPanOnly {
                    isDismissGestureActive = false
                    let speed = sqrt(vel.x * vel.x + vel.y * vel.y)
                    // しきい値フラグ立済み → 指の位置に関わらず dismiss 確定
                    // フラグ未達でも高速フリックなら dismiss
                    let shouldDismiss = hasExceededSwipeThreshold
                        || (g.state == .ended && speed > 700)
                    hasExceededSwipeThreshold = false
                    if shouldDismiss {
                        onDismiss?()
                    } else {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                            dismissDragOffset.wrappedValue = .zero
                        }
                    }
                    navDragOffset.wrappedValue = 0
                    return
                }
                if navDragAxis == .vertical {
                    // iPhone: standard sheet dismiss threshold
                    if t.y > 60 || vel.y > 400 { onDismiss?() }
                    navDragOffset.wrappedValue = 0
                    return
                }
                if navDragAxis == .horizontal {
                    let threshold = screenWidth * 0.35
                    let goNext = (t.x < -threshold || vel.x < -600) && canNavigateNext
                    let goPrev = (t.x >  threshold || vel.x >  600) && canNavigatePrev
                    if goNext {
                        onNavigate?(1)
                    } else if goPrev {
                        onNavigate?(-1)
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            navDragOffset.wrappedValue = 0
                        }
                    }
                } else {
                    navDragOffset.wrappedValue = 0
                }
            default:
                break
            }
        }

        func gestureRecognizer(_ g1: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith g2: UIGestureRecognizer) -> Bool {
            if g1 === navPanGesture || g2 === navPanGesture {
                if g2 is UIPinchGestureRecognizer || g1 is UIPinchGestureRecognizer { return true }
                if g2 is UITapGestureRecognizer  || g1 is UITapGestureRecognizer  { return true }
                if horizontalPanOnly { return true }
                return false
            }
            return true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard horizontalPanOnly, gestureRecognizer === navPanGesture,
                  let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            // Allow horizontal navigation OR downward swipe-to-dismiss.
            return abs(velocity.x) > abs(velocity.y) || velocity.y > 50
        }
    }
}

// MARK: - Helpers

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

