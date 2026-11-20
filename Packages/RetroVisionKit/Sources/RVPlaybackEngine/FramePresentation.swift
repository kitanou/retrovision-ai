import CoreMedia
import CoreVideo
import Foundation
import Metal
import QuartzCore
import RVEnhancement
import RVMediaCore
import RVMLRuntime
import RVVideoPipeline

// MARK: - 提示の出口（05 §7 / OQ-26 の置換）
//
// engine は「提示時刻に達した frame」を `VideoFramePresenter` へ渡す。結果（`FrameDeliveryOutcome`）で
// 渡せたか・捨てられたかが engine に戻り、捨てた場合は `PlaybackOutcome.displayMissed` に数える
// （保存則: presented = delivered + displayMissed。PresentHandoffTests で固定）。
// 提示時刻の権威は engine（音声 clock）のままで、presenter は時刻を作らない。

public enum FrameDeliveryOutcome: Sendable {
    /// 提示面が frame を受理した（Metal では drawable へ描いて present 予約済み）。
    case delivered
    /// 提示面が受理できなかった（in-flight 上限・drawable 喪失・描画失敗）。再生は止めない（INV-1）。
    case dropped
}

public protocol VideoFramePresenter: Sendable {
    /// `plan` は engine が昇格済みの描画計画（frame 境界で差し替わる）。nil は計画未確定。
    func present(_ frame: DecodedVideoFrame, plan: RenderPlan?) async -> FrameDeliveryOutcome
    /// 先読み（設計 11 §6.1）: 復号された直後、提示より前に**復号順に同期で**呼ぶ。AI 段の推論を先に始める。
    func prepare(_ frame: DecodedVideoFrame, plan: RenderPlan?)
    /// シーク・item / session の切替・close: 先読みの入力と結果を捨てる（古い世代の結果は使わない）。
    func flush()
}

extension VideoFramePresenter {
    public func prepare(_ frame: DecodedVideoFrame, plan: RenderPlan?) {}
    public func flush() {}
}

/// 既存の `VideoPresentSink`（暫定の AVSampleBufferDisplayLayer 経路）を常に受理する presenter に包む。
/// Metal 経路が実画面で確認できるまでの切替可能なフォールバック。
struct LegacySinkPresenter: VideoFramePresenter {
    let sink: any VideoPresentSink
    func present(_ frame: DecodedVideoFrame, plan: RenderPlan?) async -> FrameDeliveryOutcome {
        await sink.receive(frame)
        return .delivered
    }
}

/// Metal 提示（RVVideoPipeline）を engine の presenter 契約に載せる。
/// CAMetalLayer は UI が供給する（RVVideoPipeline も engine も AppKit を知らない）。
public final class MetalFramePresenter: VideoFramePresenter, @unchecked Sendable {
    private let graph: MetalRenderGraph
    private let presenter: MetalPresenter
    private let lock = NSLock()
    /// 入力の組み立て（telecine の判断・前 frame の受け渡し）を復号順に 1 回だけ行う直列 queue。
    private let inputQueue = DispatchQueue(label: "rv.presenter.input")
    private var lastAspect: AspectRatio?
    /// 直前に組み立てた frame の pixel buffer（motion-adaptive の動き検出用）。
    private var previousBuffer: CVPixelBuffer?
    /// telecine の field matching の判断（確信してロックしている間だけ動く）。
    private var matcher = TelecineMatcher()
    private var onAspectResolved: (@Sendable (Double) -> Void)?

    /// Metal デバイスが無い環境では nil（呼び出し側は暫定経路へ戻す）。
    public convenience init?() {
        self.init(scheduling: .init())
    }

    public init?(scheduling: Scheduling, clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        guard let context = try? MetalRenderContext(),
              let graph = try? MetalRenderGraph(context: context) else { return nil }
        self.graph = graph
        presenter = MetalPresenter(graph: graph)
        presenter.timing = .immediate   // 提示時刻は engine（音声 clock）が決める
        self.scheduling = scheduling
        self.clock = clock
    }

    // MARK: AI 段（設計 11 §6。tier が lightML 以上で plan に superResolution 段があるときだけ使う）
    //
    // 再生を止めない（INV-1）ための方針:
    //  - 推論は復号直後（`prepare`）に始め、提示（`present`）は**待たない**。結果が出来ていれば強調、無ければ非強調。
    //  - 結果は（世代, FrameID, PTS）で引き、planHash が提示時の plan と違えば使わない（AI オフ等が次の frame から効く — INV-3）。
    //  - シーク・session 切替・close で世代を進め、古い世代の結果は捨てる。
    //  - 強調 / 非強調が交互に出続けないよう、取りこぼし率が高ければ強調を一定時間止める（§6.2）。
    //  - 一時停止・コマ送り・静止画は、最後の frame を期限なしで強調して描き直す（`refineLastFrame`）。

    /// 先読みと切り替えの設定（設計 11 §6。数値は初期値で、実測で詰める）。
    public struct Scheduling: Sendable {
        /// 同時に走らせる推論の上限（06 §7）。
        public var maxJobs = 2
        /// 取りこぼし率を測る窓（秒）と、止める閾値・止める時間（秒）。
        public var missWindowSeconds = 1.0
        public var maxMissRate = 0.05
        public var suspendSeconds = 10.0
        /// 窓の中でこの数以上の frame を見てから判定する（数 frame で止めない）。
        public var minSamples = 10
        /// 推論の期限 = 開始から frame の表示長 × この数（提示より前に始めるので、表示長 1 つ分より長く取る）。
        public var deadlineFrames = 4.0
        public init() {}
    }

    public struct EnhancementStatistics: Sendable, Hashable {
        /// AI 段を通して提示した frame 数。
        public var enhanced = 0
        /// 推論の上限に達していて、先読みで推論を始められなかった frame 数。
        public var skippedBusy = 0
        /// AI 段が失敗して非強調で提示した frame 数（breaker・期限・shape・未 load・描画失敗）。
        public var fellBack = 0
        /// 推論は始めたが、提示の時点で終わっていなかった frame 数（待たずに非強調で提示）。
        public var notReady = 0
        /// 先読みされていなかった frame 数（`prepare` を通らずに提示された、または世代・plan が違う）。
        public var notPrepared = 0
        /// 取りこぼしが多く強調を止めていた間に提示した frame 数。
        public var suspended = 0
        /// 一時停止・コマ送り・静止画で、期限なしに強調して描き直した回数。
        public var refined = 0
        /// 強調を止めた回数（§6.2）。
        public var suspensions = 0
        public var lastError: String?
        /// 強調の対象だった frame の数（= enhanced + skippedBusy + fellBack + notReady + notPrepared + suspended）。
        public var eligible: Int { enhanced + skippedBusy + fellBack + notReady + notPrepared + suspended }
    }

    private struct FrameKey: Hashable { let generation: Int; let id: FrameID; let ptsValue: Int64; let ptsScale: Int32 }
    private func key(_ frame: DecodedVideoFrame) -> FrameKey {
        FrameKey(generation: generation, id: frame.id, ptsValue: frame.pts.value, ptsScale: frame.pts.timescale)
    }

    private enum JobState {
        case running(planHash: String)
        case done(MLEnhancementStage.EnhancedFrame, planHash: String)
        case failed(String)
        case skippedBusy
    }

    private var enhancer: MLEnhancementStage?
    private let scheduling: Scheduling
    private let clock: @Sendable () -> Double
    private var generation = 0
    private var inputs: [FrameKey: RenderFrameInput] = [:]
    private var jobs: [FrameKey: JobState] = [:]
    private var runningJobs = 0
    private var playbackRate = 1.0
    private var suspendedUntil: Double?
    /// 現世代で最初に強調して提示するまでは取りこぼしを数えない（起動・シーク直後の自己停止を防ぐ）。
    private var armed = false
    private var window: [(time: Double, hit: Bool)] = []
    private var enhancementStatistics = EnhancementStatistics()
    /// 最後に提示した frame（一時停止中の期限なし強調の材料）と、それを取り消すための番号。
    private var lastPresented: (input: RenderFrameInput, plan: RenderPlan, frame: DecodedVideoFrame)?
    private var presentSerial = 0

    /// 推論の期限（ms）。nil なら frame の表示長 × `Scheduling.deadlineFrames`。
    public var enhancementBudgetMS: Double? {
        get { lock.withLock { _enhancementBudgetMS } }
        set { lock.withLock { _enhancementBudgetMS = newValue } }
    }
    private var _enhancementBudgetMS: Double?

    public var statistics: EnhancementStatistics { lock.withLock { enhancementStatistics } }

    /// AI 段を設定する。render graph は presenter のものを共有する（同じ command queue・texture cache）。
    public func setEnhancement(runtime: any ModelRuntimeProtocol, model: ModelID, tiling: MLEnhancementStage.Tiling) {
        lock.withLock {
            enhancer = MLEnhancementStage(graph: graph, runtime: runtime, model: model, tiling: tiling)
            enhancementStatistics = EnhancementStatistics()
            resetSchedulingLocked()
        }
    }

    public func clearEnhancement() { lock.withLock { enhancer = nil; resetSchedulingLocked() } }

    /// 再生速度（≠ 1 では強調を止める — 周期が変わり予算が崩れるため。設計 11 §6.3）。
    public func setPlaybackRate(_ rate: Double) { lock.withLock { playbackRate = rate } }

    public func flush() {
        inputQueue.sync {
            lock.withLock {
                generation += 1
                previousBuffer = nil
                matcher.reset()
                resetSchedulingLocked()
            }
        }
    }

    private func resetSchedulingLocked() {
        inputs.removeAll()
        jobs.removeAll()
        window.removeAll()
        armed = false
        presentSerial += 1   // 走っている refine を無効にする
    }

    public func attachLayer(_ layer: CAMetalLayer?) {
        presenter.attachLayer(layer)
        if layer == nil {
            presenter.clearLast()
            flush()
            lock.withLock { lastPresented = nil }
        }
    }

    /// 表示比率（targetDAR）が決まる・変わるたびに通知する（UI が view の枠を決める）。
    public func setAspectHandler(_ handler: (@Sendable (Double) -> Void)?) {
        lock.withLock {
            onAspectResolved = handler
            lastAspect = nil
        }
    }

    /// 窓リサイズ・一時停止中の再描画（最後の frame を現在の drawable 寸法で描き直す）。
    public func redraw() { presenter.redrawLast() }

    // MARK: 入力の組み立て（復号順に 1 回）

    /// telecine の判断と前 frame の受け渡しを進めて、この frame の入力を作る。`inputQueue` の上で呼ぶこと。
    private func buildInput(_ frame: DecodedVideoFrame, aspect: AspectResolution) -> RenderFrameInput {
        let interlaced = frame.format.interlace.fieldCount >= 2
        let score = interlaced ? CombMetric.toothScore(frame.pixelBuffer) : 0
        let (previous, fieldMatch) = lock.withLock { () -> (CVPixelBuffer?, RenderFrameInput.FieldMatchRequest) in
            var request = RenderFrameInput.FieldMatchRequest.none
            var continuous = true
            if interlaced {
                let r = matcher.match(score: score, pts: frame.pts.seconds, duration: frame.duration.seconds)
                request = r.request
                continuous = r.previousIsContinuous
            }
            // PTS が連続でなければ前 frame は無関係（seek・menu のループ・落とし frame）: 渡さない。
            let p = continuous ? previousBuffer : nil
            previousBuffer = frame.pixelBuffer
            return (p, request)
        }
        return RenderFrameInput(pixelBuffer: frame.pixelBuffer, color: frame.format.color,
                                interlace: frame.format.interlace, aspect: aspect,
                                frameID: frame.id, previousPixelBuffer: previous, fieldMatch: fieldMatch)
    }

    /// この plan で強調の対象になるか（tier・SR 段・モデルの一致）。
    private func eligibleStage(for plan: RenderPlan) -> MLEnhancementStage? {
        guard let stage = lock.withLock({ enhancer }), plan.tier >= .lightML,
              let request = plan.stage(of: .superResolution)?.parameters as? SuperResolutionParameters,
              request.model == stage.model else { return nil }
        return stage
    }

    // MARK: 先読み

    public func prepare(_ frame: DecodedVideoFrame, plan: RenderPlan?) {
        guard let plan else { return }
        inputQueue.async { [self] in
            let input = buildInput(frame, aspect: plan.output.aspect)
            let k = lock.withLock { key(frame) }
            lock.withLock { inputs[k] = input }
            guard let stage = eligibleStage(for: plan) else { return }
            let start: Bool = lock.withLock {
                guard playbackRate == 1, !isSuspendedLocked(), k.generation == generation else { return false }
                if runningJobs >= scheduling.maxJobs { jobs[k] = .skippedBusy; return false }
                runningJobs += 1
                jobs[k] = .running(planHash: plan.planHash)
                return true
            }
            guard start else { return }
            let budget = lock.withLock { _enhancementBudgetMS } ?? max(frame.duration.seconds * 1_000 * scheduling.deadlineFrames, 1)
            Task { [self] in
                let result: JobState
                do {
                    let enhanced = try await stage.enhanceFrame(input, plan: plan, frameID: frame.id,
                                                                deadline: HostTime.now().advancing(ms: budget))
                    result = .done(enhanced, planHash: plan.planHash)
                } catch {
                    result = .failed(String(describing: error))
                }
                lock.withLock {
                    runningJobs = max(0, runningJobs - 1)
                    guard k.generation == generation, jobs[k] != nil else { return }   // 古い世代・提示済みは捨てる
                    jobs[k] = result
                }
            }
        }
    }

    private func isSuspendedLocked() -> Bool {
        guard let until = suspendedUntil else { return false }
        if clock() >= until { suspendedUntil = nil; return false }
        return true
    }

    // MARK: 提示

    public func present(_ frame: DecodedVideoFrame, plan: RenderPlan?) async -> FrameDeliveryOutcome {
        guard let plan else { return .dropped }
        notifyAspect(plan.output.aspect.targetDAR)
        // 先読みの入力があれば使い、無ければここで組み立てる（同じ直列 queue の上なので順序は保たれる）。
        var input: RenderFrameInput = inputQueue.sync {
            let k = lock.withLock { key(frame) }
            if let cached = lock.withLock({ inputs.removeValue(forKey: k) }) { return cached }
            return buildInput(frame, aspect: plan.output.aspect)
        }
        input.aspect = plan.output.aspect   // 提示時の plan の比率（先読み時から plan が替わっていても正しく描く）
        let eligible = eligibleStage(for: plan) != nil
        let (enhanced, serial): (MLEnhancementStage.EnhancedFrame?, Int) = lock.withLock {
            presentSerial += 1
            lastPresented = (input, plan, frame)
            let k = key(frame)
            let state = jobs.removeValue(forKey: k)
            evictLocked(upTo: frame.pts)
            guard eligible else { return (nil, presentSerial) }
            var hit: MLEnhancementStage.EnhancedFrame?
            switch state {
            case .done(let result, let hash) where hash == plan.planHash:
                hit = result
            case .done, .none:
                if isSuspendedLocked() { enhancementStatistics.suspended += 1 } else { enhancementStatistics.notPrepared += 1 }
            case .running:
                enhancementStatistics.notReady += 1
            case .failed(let message):
                enhancementStatistics.fellBack += 1
                enhancementStatistics.lastError = message
            case .skippedBusy:
                enhancementStatistics.skippedBusy += 1
            }
            recordLocked(hit: hit != nil)
            return (hit, presentSerial)
        }
        _ = serial
        if let enhanced {
            do {
                let outcome = try presentEnhanced(enhanced, plan: plan, frame: frame)
                lock.withLock { enhancementStatistics.enhanced += 1 }
                switch outcome {
                case .scheduled: return .delivered
                case .dropped: return .dropped
                }
            } catch {
                lock.withLock {
                    enhancementStatistics.fellBack += 1
                    enhancementStatistics.lastError = String(describing: error)
                }
            }
        }
        do {
            switch try presenter.present(input, plan: plan, pts: frame.pts) {
            case .scheduled: return .delivered
            case .dropped: return .dropped
            }
        } catch {
            return .dropped   // 描画失敗は frame を捨てて次へ（再生・音声は止めない）
        }
    }

    private func presentEnhanced(_ enhanced: MLEnhancementStage.EnhancedFrame, plan: RenderPlan,
                                 frame: DecodedVideoFrame) throws -> PresentOutcome {
        switch enhanced {
        case .rgb(let rgb):
            return try presenter.presentEnhanced(rgb, aspect: plan.output.aspect, pts: frame.pts, frameID: frame.id)
        case .tensor(let tensor):
            return try presenter.presentEnhancedTensor(tensor, aspect: plan.output.aspect, pts: frame.pts, frameID: frame.id)
        }
    }

    /// 提示済みの PTS 以前の入力・結果を捨てる（session の in-flight 上限で提示されなかった frame の結果を溜めない）。
    private func evictLocked(upTo pts: MediaTime) {
        let limit = pts.seconds
        for (k, _) in jobs where k.generation != generation
            || CMTimeMake(value: k.ptsValue, timescale: k.ptsScale).seconds <= limit {
            if case .running = jobs[k] { continue }   // 走っている推論は完了時に捨てる（runningJobs の計数のため残す）
            jobs.removeValue(forKey: k)
        }
        for (k, _) in inputs where k.generation != generation
            || CMTimeMake(value: k.ptsValue, timescale: k.ptsScale).seconds <= limit {
            inputs.removeValue(forKey: k)
        }
    }

    /// 取りこぼし率の窓（§6.2）。最初に強調して提示するまでは数えない。
    private func recordLocked(hit: Bool) {
        if hit { armed = true }
        guard armed else { return }
        let now = clock()
        window.append((now, hit))
        window.removeAll { now - $0.time > scheduling.missWindowSeconds }
        let misses = window.filter { !$0.hit }.count
        if window.count >= scheduling.minSamples,
           Double(misses) / Double(window.count) > scheduling.maxMissRate {
            suspendedUntil = now + scheduling.suspendSeconds
            enhancementStatistics.suspensions += 1
            window.removeAll()
            armed = false
        }
    }

    /// 先読みの組み立てと推論が全部終わるまで待つ（テスト・診断用。最大 `timeout` 秒）。
    func waitUntilIdle(timeout: Double = 5) async {
        inputQueue.sync {}
        let limit = Date().addingTimeInterval(timeout)
        while lock.withLock({ runningJobs }) > 0, Date() < limit {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    // MARK: 一時停止・コマ送り・静止画（設計 11 §6.3）

    /// 最後に提示した frame を、期限なしで強調して描き直す。次の `present` が来たら結果は使わない（古い画を出さない）。
    /// 強調の対象でない（AI オフ・tier 不足）ときや失敗したときは何もしない。描き直したら true。
    @discardableResult
    public func refineLastFrame() async -> Bool {
        guard let (last, serial, gen) = lock.withLock({ () -> ((RenderFrameInput, RenderPlan, DecodedVideoFrame), Int, Int)? in
            guard let l = lastPresented else { return nil }
            return ((l.input, l.plan, l.frame), presentSerial, generation)
        }), let stage = eligibleStage(for: last.1) else { return false }
        let (input, plan, frame) = last
        guard let enhanced = try? await stage.enhanceFrame(input, plan: plan, frameID: frame.id,
                                                          deadline: HostTime.now().advancing(ms: 60_000)) else { return false }
        let stillCurrent = lock.withLock { serial == presentSerial && gen == generation }
        guard stillCurrent, (try? presentEnhanced(enhanced, plan: plan, frame: frame)) != nil else { return false }
        lock.withLock { enhancementStatistics.refined += 1 }
        return true
    }

    private func notifyAspect(_ dar: AspectRatio) {
        let handler: (@Sendable (Double) -> Void)? = lock.withLock {
            guard lastAspect != dar else { return nil }
            lastAspect = dar
            return onAspectResolved
        }
        handler?(dar.value)
    }
}
