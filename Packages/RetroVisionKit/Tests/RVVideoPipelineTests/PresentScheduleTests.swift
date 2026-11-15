import Foundation
import XCTest
@testable import RVVideoPipeline
import RVMediaCore

final class PresentScheduleTests: XCTestCase {
    /// 29.97 → 59.94 は 2,2 で完全一致。jitter を生まないこと（05 §5.3）。
    func testNTSCOn5994IsExactlyTwoVsPerFrame() {
        let plan = PresentSchedule(sourceFrameRate: .ntsc, refresh: .hz59_94)
        XCTAssertEqual(plan.holdDistribution(first: 600)[2], 600)
        XCTAssertEqual(plan.holdSpread(first: 600), 0)
        XCTAssertTrue(plan.isPeriodicallyConsistent(first: 600))
    }

    /// 29.97 → 60.00 では 2 を基調に、ずれが積み上がった分だけ 3 本保持を散らす（05 §5.3）。
    func testNTSCOn60SpreadsTheExtraVsync() {
        let plan = PresentSchedule(sourceFrameRate: .ntsc, refresh: .hz60)
        let dist = plan.holdDistribution(first: 1_000)
        XCTAssertEqual(dist[2] ?? 0, 998, "0.2% 分だけ 3 本保持になる")
        XCTAssertEqual(dist[3] ?? 0, 2)
        XCTAssertTrue(plan.isPeriodicallyConsistent(first: 1_000))
        // 3 本保持が連続して並ばないこと（同じ位置で引っかからない）。
        var previousWasLong = false
        for i in 0..<1_000 {
            let hold = plan.holdCount(forFrame: Int64(i))
            XCTAssertFalse(previousWasLong && hold == 3, "長い保持が連続している: \(i)")
            previousWasLong = (hold == 3)
        }
    }

    func testPALOn60MixesTwoAndThree() {
        let plan = PresentSchedule(sourceFrameRate: .pal, refresh: .hz60)
        let dist = plan.holdDistribution(first: 250)
        XCTAssertEqual((dist[2] ?? 0) + (dist[3] ?? 0), 250)
        XCTAssertTrue(plan.isPeriodicallyConsistent(first: 250))
    }

    func testFilm24On60IsTwoThreePulldown() {
        let plan = PresentSchedule(sourceFrameRate: .film24, refresh: .hz60)
        let dist = plan.holdDistribution(first: 240)
        XCTAssertEqual(dist[2] ?? 0, 120)
        XCTAssertEqual(dist[3] ?? 0, 120)
    }

    /// 29.97 → 119.88 は 4,4 で完全一致。
    func testNTSCOn119_88IsFourVsPerFrame() {
        let refresh = DisplayRefresh(numerator: 120_000, denominator: 1_001)
        let plan = PresentSchedule(sourceFrameRate: .ntsc, refresh: refresh)
        XCTAssertEqual(plan.holdDistribution(first: 300)[4], 300)
        XCTAssertEqual(plan.holdSpread(first: 300), 0)
    }

    /// 提示は常に予定時刻以降（早出ししない）。
    func testNeverPresentsEarly() {
        let plan = PresentSchedule(sourceFrameRate: .pal, refresh: .hz60)
        let fps = FrameRate.pal
        for n: Int64 in [0, 1, 7, 30, 99] {
            let v = plan.vsyncIndex(forFrame: n)
            let frameSeconds = Double(n) * 0.04
            let vsyncSeconds = Double(v) / 60.0
            XCTAssertGreaterThanOrEqual(vsyncSeconds + 1e-9, frameSeconds, "frame \(n)")
        }
        _ = fps
    }
}

final class PlanTests: XCTestCase {
    private let aspect = AspectResolver.resolve(codedSize: PixelSize(width: 720, height: 480),
                                               signals: AspectSignals(dvdAspectFlag: .allowed4x3,
                                                                     sampleAspectFromStandard: .bt601NTSCSample),
                                               policy: .followSource)

    private func output() -> OutputContract {
        OutputContract(displayPixels: PixelSize(width: 720, height: 480), aspect: aspect)
    }

    /// 同じ設定なら同じ planHash（08 §7.2 の再現性）。
    func testPlanHashIsStableForSameSettings() {
        let a = RenderPlan.metalBaseline(id: PlanID(1), output: output())
        let b = RenderPlan.metalBaseline(id: PlanID(2), output: output())
        XCTAssertEqual(a.planHash, b.planHash)
    }

    func testAddingAStageChangesTheHash() {
        let base = RenderPlan.metalBaseline(id: PlanID(1), output: output())
        var stages = base.stages
        stages.append(StageRequest(stage: .superResolution, parameters: TestStageParams(tag: "sr")))
        let modified = RenderPlan(id: PlanID(2), tier: .fullML, stages: stages, output: output())
        XCTAssertNotEqual(base.planHash, modified.planHash)
    }

    /// INV-2: AI なしの plan が常に作れる。
    func testOffAndMetalBaselineExist() {
        let off = RenderPlan.offPlan(id: PlanID(1), output: output())
        XCTAssertEqual(off.tier, .off)
        XCTAssertFalse(off.stages.contains { $0.stage == .superResolution })
        let metal = RenderPlan.metalBaseline(id: PlanID(2), output: output())
        XCTAssertTrue(metal.stages.contains { $0.stage == .deinterlace })
    }

    func testBudgetFeasibilityAgainstFrameRate() {
        XCTAssertTrue(FrameBudget.initialDraft.isFeasible(for: .ntsc))
        var wide = FrameBudget.initialDraft
        wide.inferenceMS = 30
        XCTAssertFalse(wide.isFeasible(for: .ntsc))
    }
}

/// テスト用の段パラメータ。RVEnhancement に依存しないための局所的な実装（09 §3）。
struct TestStageParams: StageParameters {
    let tag: String
    var canonicalForm: String { "tag=\(tag)" }
}
