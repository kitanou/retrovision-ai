import CoreVideo
import Foundation
import Metal
import QuartzCore
import RVMediaCore

// MARK: - 提示（05 §7。正式経路。OQ-26 の暫定ハンドオフはここで置き換わる）
//
// 契約:
// - 未来の vsync に present 予約する。`MTLDrawable.present(at:)` の時刻は CA host clock
//   （CACurrentMediaTime と同一の秒単位。mach absolute time 基準 — RVMediaCore の
//   HostTime とは換算係数だけ違う同一タイムベース）。内部計算は秒で通し、記録だけ
//   ms に換算する（混同事故を防ぐため単位は型コメントで固定）。
// - 予約できない（layer 無し・drawable 取得失敗）は `drawableLost` → その frame を捨てて
//   次を出す。再生（音声・提示時刻の意味）は止めない（INV-1）。
// - in-flight 最大 3（00 §5）。上限を越えたら encode せず drop（reason に載せる）。
// - addPresentedHandler で実提示時刻（drawed.presentedTime。CFTimeInterval の秒。
//   未提示・スキップ時は 0）を取り、予約との差（jitter）を残す。
//   endToEnd（PTS→presented。05 §8 の定義）は media clock の対応付けが必要なので
//   engine 側の合成で埋める（PresentRecord.endToEndMS は nil で届く）。

public struct PresentRecord: Sendable {
    public var frameID: FrameID
    public var pts: MediaTime
    /// 予約した vsync の CA host 時刻（ms。seconds 由来の小数はそのまま保つ）。
    public var scheduledHostMS: Double
    /// addPresentedHandler の presentedTime（ms）。
    public var presentedHostMS: Double
    /// presented − scheduled（負は早出し。05 §8 の jitter 定義）。
    public var jitterMS: Double
    /// engine 側が clock 変換で合成する（presentedHost − host(for: pts)）。
    public var endToEndMS: Double?

    public init(frameID: FrameID, pts: MediaTime, scheduledHostMS: Double,
                presentedHostMS: Double, jitterMS: Double, endToEndMS: Double? = nil) {
        self.frameID = frameID
        self.pts = pts
        self.scheduledHostMS = scheduledHostMS
        self.presentedHostMS = presentedHostMS
        self.jitterMS = jitterMS
        self.endToEndMS = endToEndMS
    }
}

public enum PresentOutcome: Sendable {
    case scheduled
    case dropped(reason: PresentDropReason)
}

public enum PresentDropReason: String, Sendable { case inFlightLimit, drawableLost }

/// RVVideoPipeline は AppKit/SwiftUI を知らないため、CAMetalLayer は UI 側から供給される
/// （present-surface 境界。view 再作成でも presenter は生き続ける — 提示の連続性）。
public final class MetalPresenter: @unchecked Sendable {
    public static let maxInFlight = 3   // 00 §5

    /// 予約時刻の決め方。
    /// - `.anchoredGrid`: 自前の anchor（CA host ↔ PTS）に沿って vsync グリッドへ予約する（05 §7 の設計形）。
    /// - `.immediate`: 呼ばれた時点の次の vsync で表示する。engine が音声 clock で既に
    ///   「提示時刻」を決めて渡してくる構成（PlaybackSession.presentDue）では、こちらを使う —
    ///   二つ目の時間軸（presenter の anchor）が audio clock と競合するのを避ける。
    ///   seek で PTS が飛んでも予約が未来へずれない。
    public enum Timing: Sendable { case anchoredGrid, immediate }
    public var timing: Timing {
        get { lock.withLock { _timing } }
        set { lock.withLock { _timing = newValue } }
    }
    private var _timing: Timing = .anchoredGrid
    /// 最後に描いた入力（窓リサイズ・一時停止中の再描画用。pixel buffer を保持する）。
    private var lastDraw: (draw: @Sendable (any MTLTexture) throws -> Void, retain: AnyObject,
                           pts: MediaTime, frameID: FrameID)?
    /// 映像の上に重ねる画（字幕・DVD メニューのハイライト）。毎 frame、映像を描いた直後に重ねる。
    private var overlayTexture: (any MTLTexture)?
    private var overlayAspect: AspectResolution?

    private let graph: MetalRenderGraph
    private let lock = NSLock()
    private weak var layer: CAMetalLayer?
    private var inFlight = 0
    /// 提示計画（source fps ↔ display refresh の整数比。05 §5.3）。nil でも動く
    /// （その場合は arrival 時点の次の vsync 予約）。
    private var schedule: PresentSchedule?
    /// grid/理想時刻の原点（CA host 秒 + PTS）。configureSchedule で作り直す
    /// （engine の clock 再 anchor と同じ契機 — seek 後は here から組み替える）。
    private var anchorHostS: Double?
    private var anchorPTS: MediaTime?

    public init(graph: MetalRenderGraph) { self.graph = graph }

    /// UI の view が CAMetalLayer を供給する。nil で提示停止（close と同じ处理）。
    public func attachLayer(_ layer: CAMetalLayer?) {
        lock.withLock { self.layer = layer }
    }

    /// source の frame rate と表示 refresh が決まった時点で計画を立てる。
    /// 計画が変わる時点（= engine が clock を再 anchor する時点）で呼ぶ。
    public func configureSchedule(sourceFrameRate: FrameRate, refresh: DisplayRefresh) {
        lock.withLock {
            self.schedule = PresentSchedule(sourceFrameRate: sourceFrameRate, refresh: refresh)
            self.anchorHostS = nil
            self.anchorPTS = nil
        }
    }

    /// 1 frame を drawable に描いて present 予約する。dropped を返した場合は
    /// engine 側の drop 計数に載せる（保存則: delivered = scheduled + dropped — 05 §7）。
    public func present(_ input: RenderFrameInput, plan: RenderPlan, pts: MediaTime) throws
        -> PresentOutcome {
        let retained = input.pixelBuffer   // GPU が読み終える（提示完了）まで復号 buffer を生かす
        return try submit(pts: pts, frameID: input.frameID ?? FrameID(0), retain: retained) { [graph] texture in
            _ = try graph.render(input, plan: plan, to: texture)
        }
    }

    /// AI 段を通した RGB buffer を、目標比率で letterbox して drawable へ描いて present 予約する。
    public func presentEnhanced(_ rgb: RGBFrameBuffer, aspect: AspectResolution, pts: MediaTime,
                                frameID: FrameID) throws -> PresentOutcome {
        try submit(pts: pts, frameID: frameID, retain: rgb) { [graph] texture in
            try graph.presentRGB(rgb, aspect: aspect, to: texture)
        }
    }

    /// SR の 16 bit テンソル出力を最終拡大して提示する（設計 11 §5.6）。
    public func presentEnhancedTensor(_ tensor: TensorTexture, aspect: AspectResolution, pts: MediaTime,
                                      frameID: FrameID) throws -> PresentOutcome {
        try submit(pts: pts, frameID: frameID, retain: tensor) { [graph] texture in
            try graph.presentTensor(tensor, aspect: aspect, to: texture)
        }
    }

    /// drawable の確保・描画・present 予約・presented 記録の共通部分。`draw` が drawable の texture へ描く。
    private func submit(pts: MediaTime, frameID: FrameID, retain: AnyObject,
                        draw: @escaping @Sendable (any MTLTexture) throws -> Void) throws -> PresentOutcome {
        let layer = lock.withLock { self.layer }
        guard let layer else { return .dropped(reason: .drawableLost) }
        let inFlightNow = lock.withLock { () -> Int in
            let n = inFlight
            if n < Self.maxInFlight { inFlight = n + 1 }
            return n
        }
        guard inFlightNow < Self.maxInFlight else {
            return .dropped(reason: .inFlightLimit)
        }
        guard let drawable = layer.nextDrawable() else {
            lock.withLock { inFlight = max(0, inFlight - 1) }
            return .dropped(reason: .drawableLost)
        }

        do {
            try draw(drawable.texture)
            // 映像と同じ geometry でオーバーレイを重ねる（無ければ何もしない）。
            let overlay = lock.withLock { (overlayTexture, overlayAspect) }
            if let texture = overlay.0, let aspect = overlay.1 {
                try graph.drawOverlay(texture, aspect: aspect, onto: drawable.texture)
            }
        } catch {
            lock.withLock { inFlight = max(0, inFlight - 1) }   // drawable は deinit でプールへ戻る
            throw error
        }

        let nowS = CACurrentMediaTime()
        let immediate = lock.withLock { _timing == .immediate }
        let (presentAtS, scheduledS) = immediate ? (nowS, nowS) : scheduledTime(pts: pts, nowS: nowS)
        lock.withLock { lastDraw = (draw, retain, pts, frameID) }
        drawable.addPresentedHandler { [weak self] drew in
            _ = retain
            let presentedS = drew.presentedTime     // 秒。未提示・スキップは 0
            if presentedS > 0 {
                let record = PresentRecord(frameID: frameID, pts: pts,
                                           scheduledHostMS: scheduledS * 1_000,
                                           presentedHostMS: presentedS * 1_000,
                                           jitterMS: (presentedS - scheduledS) * 1_000)
                self?.onPresented?(record)
            }
            self?.decrement()
        }
        if immediate { drawable.present() } else { drawable.present(at: presentAtS) }
        return .scheduled
    }

    /// 最後に描いた frame を現在の drawable 寸法で描き直す（窓リサイズ・一時停止中の再描画）。
    /// AI 段を通した frame も同じ描き方で再描画する。描いた frame が無い、layer が無い、
    /// in-flight 上限のときは nil。
    @discardableResult
    public func redrawLast() -> PresentOutcome? {
        guard let last = lock.withLock({ lastDraw }) else { return nil }
        return try? submit(pts: last.pts, frameID: last.frameID, retain: last.retain, draw: last.draw)
    }

    /// オーバーレイの画を設定する（nil で消す）。変わったら最後の frame を描き直す（一時停止・静止画のメニューでも
    /// 選択の変化がすぐ画面に出る）。`aspect` は映像と同じ geometry を使うために、映像の描画計画から渡す。
    public func setOverlay(_ image: OverlayImage?, aspect: AspectResolution?) {
        let texture = image.flatMap { graph.makeOverlayTexture($0) }
        lock.withLock {
            overlayTexture = texture
            if let aspect { overlayAspect = aspect }
        }
        redrawLast()
    }

    /// 映像の geometry（取り込み域・目標比率）が変わったときに、オーバーレイの geometry も合わせる。
    public func updateOverlayAspect(_ aspect: AspectResolution) {
        lock.withLock { overlayAspect = aspect }
    }

    /// 保持している最後の frame を手放す（close・item 切替。復号 buffer を生かし続けない）。
    public func clearLast() { lock.withLock { lastDraw = nil } }

    /// 提示完了記録の受け口（engine が設定する。nil のままでも提示は続く）。
    public var onPresented: (@Sendable (PresentRecord) -> Void)? {
        get { lock.withLock { _onPresented } }
        set { lock.withLock { _onPresented = newValue } }
    }
    private var _onPresented: (@Sendable (PresentRecord) -> Void)?

    private func decrement() {
        lock.withLock { inFlight = max(0, inFlight - 1) }
    }

    // MARK: - 予約時刻の設計（05 §7）
    //
    // 理想提示時刻 = anchorHost + (PTS − anchorPTS)（media clock を CA host に平行移動）。
    // それ以上のグリッド（refresh.period の整数倍。anchor が原点）で、まだ来ていない
    // 最小の点に予約する。グリッド点が既に過去なら now 指定（= 実質即時。表示器は次の
    // vsync にスキャンアウトする）。早期出しは A/V 同期の予測を壊さない範囲（理想より
    // 前へは行かない）で決定的。anchor 未設定の初回这里是、現在を anchor にする。
    // seek で PTS が飛んでも、平行移動の原点が古いままでも、理想時刻の計算は続く
    // （engine が seek 後に configureSchedule を呼んで組み替える — 04 §6 と同じ契機）。
    private func scheduledTime(pts: MediaTime, nowS: Double) -> (presentAt: Double, scheduled: Double) {
        let (schedule, anchorHostS, anchorPTS) = lock.withLock {
            (self.schedule, self.anchorHostS, self.anchorPTS)
        }
        let periodS = (schedule?.refresh ?? .hz60).periodSeconds
        guard let anchorHostS, let anchorPTS else {
            lock.withLock {
                self.anchorHostS = nowS
                self.anchorPTS = pts
            }
            let presentAt = nowS + 0.001   // 初回: 即時（表示器側で次の vsync に揃う）
            return (presentAt, presentAt)
        }
        let idealS = anchorHostS + (pts.seconds - anchorPTS.seconds)
        let grid = anchorHostS + periodS * ((idealS - anchorHostS) / periodS).rounded(.up)
        let presentAt = Swift.max(grid, nowS)
        return (presentAt, presentAt)   // jitter は「予約した時刻」に対する実測。past 巻き取り時は now が予約時刻
    }

    /// drawable 間隔から実 refresh を推定（05 §5.3 の「実測される display refresh」）。
    /// 統計の取り方（#5 の検査で決めた方式）: 提示差分のうち最短間隔 m0 を基準に、
    /// m0×1.8 未満（= 同一 refresh の周期。保持帧 33ms や skip はここから落ちる）だけを
    /// 集めて平均を取り、その周期を既知標準（60/59.94/50/120/240）に丸める。
    /// 中央値だと ±0.4 ms の揺らぎで偶数サンプルのとき隣のクラスタに跳ねる（実測で失敗）。
    /// 既知との差が遠い場合は有理数近似でそのまま返す（08 §3 の plan 再判定シグナルになる）。
    public static func estimateRefresh(records: [PresentRecord]) -> DisplayRefresh? {
        let presented = records.map(\.presentedHostMS)
        guard presented.count >= 3 else { return nil }
        let diffs = (1..<presented.count).map { presented[$0] - presented[$0 - 1] }
            .filter { $0 > 1.0 }   // 0 ms 台（同じ vsync・スキップ）は除く
        guard diffs.count >= 2 else { return nil }
        let shortest = diffs.min()!
        let cycle = diffs.filter { $0 < shortest * 1.8 }
        guard cycle.count >= 2 else { return nil }
        let periodMS = cycle.reduce(0, +) / Double(cycle.count)
        guard periodMS > 0.5 else { return nil }
        let hz = 1_000.0 / periodMS
        // 既知標準には「最も近いもの」へ丸める（first-match だと 59.94 が 60 に吸われる —
        // 59.94 と 60 の差 0.06 Hz < tolerance。順序依存にしない — #5 検査で実測）。
        let known: [DisplayRefresh] = [.hz59_94, .hz60, .hz50, .hz120,
                                       DisplayRefresh(numerator: 240, denominator: 1)]
        if let best = known.min(by: { abs(hz - $0.hertzValue) < abs(hz - $1.hertzValue) }),
           abs(hz - best.hertzValue) < 0.5 {
            return best
        }
        return DisplayRefresh(numerator: Int64((hz * 1_000).rounded()), denominator: 1_000)
    }
}
