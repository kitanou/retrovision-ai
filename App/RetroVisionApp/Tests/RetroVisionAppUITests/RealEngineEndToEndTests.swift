import AVKit
import Foundation
import RVMediaCore
import RVPlaybackEngine
import XCTest
@testable import RetroVisionAppUI

// MARK: - 実 engine を通した UI 回路の e2e（#2 の受け入れ基準「controls operate through a
// defined player-engine protocol」を、fake でなく本物の EngineCore 側で確認する）。
//
// 方針（09 §2）: fixture が無い場合は失敗（silent skip で環境差を隠さない）。
// 見るもの:
//   1. open（load）→ .ready（#12 の prepare が load の中に収まる契約の UI 側回帰）。
//   2. play → 位置が実時間で進む。
//   3. 提示サーフェスへのハンドオフが走り、NTSC 720x480 の表示比率が 4:3 に解決される
//      （#17 §2 の letterbox 決定。PAR を無視した 3:2 になっていないこと）。
//   4. skip（seek 相対）で位置が前に飛ぶ（#13 の再生中 seek の UI 経路）。
//   5. close → .empty に戻る。

@MainActor
final class RealEngineEndToEndTests: XCTestCase {
    private func fixtureURL(_ name: String) throws -> URL {
        // Tests/RetroVisionAppUITests/ ← RetroVisionApp ← App ← リポジトリルート
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // RetroVisionAppUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // RetroVisionApp
            .deletingLastPathComponent()   // App
            .deletingLastPathComponent()   // リポジトリルート
            .appendingPathComponent("fixtures/generated")
            .appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("fixture が存在しない: \(url.path)（sh Scripts/gen-fixtures.sh で生成する）")
            throw MissingFixture()
        }
        return url
    }

    private struct MissingFixture: Error {}

    private func waitUntilTrue(_ condition: @MainActor @escaping () -> Bool, timeoutMS: Int = 10_000) async -> Bool {
        let polls = timeoutMS / 20
        for _ in 0..<polls {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    func testOpenPlaySeekCloseRoundTripThroughTheRealEngine() async throws {
        let url = try fixtureURL("ntsc480i-22-01.mpg")
        let engine = DefaultPlayerEngine()
        let vm = PlayerViewModel(engine: engine)
        // layer は view が保持する想定（テストではテストが終わるまで持つ。weak のままにしない）。
        let layer = AVSampleBufferDisplayLayer()
        vm.attachSurface(layer: layer)

        // 1. 開く → .ready（load の中に warmup が収まる設計のまま UI は待たされない）。
        vm.open(url: url)
        let ready = await waitUntilTrue { vm.phase == .ready }
        XCTAssertTrue(ready, "開いてから .ready に到達しない（load 経路の破綻）: \(vm.phase)")
        XCTAssertEqual(vm.durationSeconds, 6.0, accuracy: 0.1, "fixture の尺が transport 表示に載る")

        // 2. 再生 → 位置が進む。
        vm.playPause()
        let advanced = await waitUntilTrue({ vm.positionSeconds > 0.5 }, timeoutMS: 5_000)
        XCTAssertTrue(advanced, "再生しても位置が進まない（実時間ペーシングの UI 側破綻）")

        // 3. サーフェス経由で比率が解決される（最初の提示帧から）。
        let aspectSet = await waitUntilTrue({ (vm.displayAspectValue ?? 0) > 0 }, timeoutMS: 10_000)
        XCTAssertTrue(aspectSet, "提示帧から表示比率が解決されない（#17 §2 の letterbox 決定が動いていない）")
        XCTAssertEqual(vm.displayAspectValue ?? 0, 4.0 / 3.0, accuracy: 0.01,
                       "NTSC 720x480 の表示は 4:3（PAR を無視した 3:2 に倒れていない）")

        // 4. 相対 seek（#13 の seek 経路を UI 操作から通す）。
        let beforeSeek = vm.positionSeconds
        vm.skip(by: 2.0)
        let jumped = await waitUntilTrue({ vm.positionSeconds >= beforeSeek + 1.5 }, timeoutMS: 8_000)
        XCTAssertTrue(jumped, "seek で位置が前に進まない（UI → engine seek 経路の破綻）")

        // 5. 閉じる → 空状態。
        vm.closeItem()
        let emptied = await waitUntilTrue { vm.phase == .empty }
        XCTAssertTrue(emptied, "close で .empty に戻らない")

        // 統計の受け口（engine 側は測れていること。UI は #9 の診断パネルでまだ表示しない）。
        await engine.close()
        withExtendedLifetime(layer) {}
    }
}
