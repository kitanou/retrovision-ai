import AVKit
import CoreMedia
import CoreVideo
import Foundation
import RVMediaCore
import RVMediaSources
import RVPlaybackEngine
import XCTest
@testable import RetroVisionAppUI

// MARK: - PlayerViewModel の有効・無効と操作（#17 の契約を fake で固定する）
//
// FakePlayerEngine（同期スタブ）だけで全 phase を流す。実デコードは不要（02 §6）。

@MainActor
final class PlayerViewModelTests: XCTestCase {
    private func waitPhase(_ vm: PlayerViewModel, _ target: EnginePhase,
                           file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if vm.phase == target { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(vm.phase, target, "phase が届かない", file: file, line: line)
    }

    // MARK: 有効・無効の表（#17 の表 + preparing の逸脱。PlayerViewModel の注記に理由）

    func testControlEnablementIsDerivedFromPhase() async {
        let fake = FakePlayerEngine()
        let vm = PlayerViewModel(engine: fake)

        struct Expectation {
            let phase: EnginePhase
            let transport, seek, step, track: Bool
        }
        let cases: [Expectation] = [
            .init(phase: .empty, transport: false, seek: false, step: false, track: false),
            .init(phase: .preparing, transport: true, seek: false, step: false, track: false),
            .init(phase: .ready, transport: true, seek: true, step: true, track: true),
            .init(phase: .playing, transport: true, seek: true, step: false, track: true),
            .init(phase: .seeking(target: CMTime(seconds: 3, preferredTimescale: 1)),
                  transport: false, seek: false, step: false, track: false),
            .init(phase: .paused, transport: true, seek: true, step: true, track: true),
            .init(phase: .stalled(reason: .demuxStarved), transport: true, seek: true, step: false, track: true),
            .init(phase: .ended, transport: true, seek: true, step: true, track: true),
            .init(phase: .failed(PlaybackError(kind: .internalFailure("x"),
                                               recovery: .giveUp(reason: "x"),
                                               userMessage: "x"))
                  , transport: false, seek: false, step: false, track: false),
        ]
        for c in cases {
            fake.emit(.phaseChanged(c.phase))
            await waitPhase(vm, c.phase)
            XCTAssertEqual(vm.transportEnabled, c.transport, "transport: \(c.phase)")
            XCTAssertEqual(vm.seekEnabled, c.seek, "seek: \(c.phase)")
            XCTAssertEqual(vm.stepEnabled, c.step, "step: \(c.phase)")
            XCTAssertEqual(vm.trackSelectionEnabled, c.track, "track: \(c.phase)")
        }
    }

    // MARK: 開く（load → preparing → ready。#17 §1 の流れ）

    func testOpenReachesReadyViaFakeLoad() async {
        let fake = FakePlayerEngine()
        let vm = PlayerViewModel(engine: fake)
        vm.open(url: URL(fileURLWithPath: "/tmp/does-not-matter.mpg"))
        await waitPhase(vm, .ready)
        let duration = vm.durationSeconds
        XCTAssertEqual(duration, 60, accuracy: 0.001, "structure の duration が transport 表示に載る")
        XCTAssertTrue(fake.calls.contains("load"))
    }

    // MARK: タイトルメニュー（#3 追加分。multi-item 構造のときだけ列挙し、切り替えは engine に投げる）

    func testMultiTitleOpenExposesTitlesAndSelectGoesToEngine() async {
        let fake = FakePlayerEngine()
        fake.presetStructure = MediaStructure(itemKind: .dvdTitles, items: [
            MediaItem(id: ItemID(1), titleNumber: 1, duration: CMTime(value: 60, timescale: 1)),
            MediaItem(id: ItemID(2), titleNumber: 2, duration: CMTime(value: 30, timescale: 1)),
        ])
        let vm = PlayerViewModel(engine: fake)
        vm.open(url: URL(fileURLWithPath: "/tmp/does-not-matter.iso"))
        await waitPhase(vm, .ready)
        for _ in 0..<200 where vm.availableTitles.count != 2 {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(vm.availableTitles.count, 2, "multi-item 構造がタイトルメニューに載らない")
        XCTAssertTrue(vm.hasTitleChoice)
        XCTAssertTrue(vm.titleSelectionEnabled)

        vm.selectTitle(ItemID(2))
        for _ in 0..<200 where !fake.calls.contains("select:item") {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(fake.calls.contains("select:item"), "select(item:) が発火しない")

        // 選択表示の更新は events 経由（selectionChanged を流さない fake では古い選択のまま —
        // 表示が engine 由来の外から勝手に進まないことの裏返し）。
        XCTAssertNotEqual(vm.selected?.item, ItemID(2))
        fake.emit(.selectionChanged(PlaybackSelection(item: ItemID(2))))
        for _ in 0..<200 where vm.selected?.item != ItemID(2) {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(vm.selected?.item, ItemID(2), "selectionChanged で選択表示が更新される")
    }

    // MARK: first-play 政策（menu 増分。03 §5 の DVD 実機の挙動: 挿入 = 再生開始）
    //
    // menu（titleNumber 0 / ItemID(0)）が構造の先頭に在るとき:
    //   * open は selection nil（構造駆動）→ engine が先頭 = menu で解決する（selectionChanged で届く）。
    //   * menu は自动再生される（実機の first-play）。menu の無い盘では user gate のまま（#17）。
    //   * menu が ended になったら最初の本体タイトルへ auto-select + play で自動進行する。
    private func menuPreset() -> MediaStructure {
        MediaStructure(itemKind: .dvdTitles, items: [
            MediaItem(id: ItemID(0), titleNumber: 0, duration: CMTime(value: 4, timescale: 1)),
            MediaItem(id: ItemID(1), titleNumber: 1, duration: CMTime(value: 60, timescale: 1)),
            MediaItem(id: ItemID(2), titleNumber: 2, duration: CMTime(value: 30, timescale: 1)),
        ])
    }

    func testFirstPlayWithMenuAutoSelectsAndPlaysIt() async {
        let fake = FakePlayerEngine()
        fake.presetStructure = menuPreset()
        let vm = PlayerViewModel(engine: fake)
        vm.open(url: URL(fileURLWithPath: "/tmp/does-not-matter.iso"))
        await waitPhase(vm, .playing)
        XCTAssertEqual(vm.selected?.item, ItemID(0),
                       "menu が構造駆動の既定選択になっていない（first-play 実挙動）")
        XCTAssertTrue(fake.calls.contains("play"), "menu が自动再生されない（03 §5 の実挙動合わせ）")
    }

    func testMenuEndedAutoAdvancesToFirstTitle() async {
        let fake = FakePlayerEngine()
        fake.presetStructure = menuPreset()
        let vm = PlayerViewModel(engine: fake)
        vm.open(url: URL(fileURLWithPath: "/tmp/does-not-matter.iso"))
        await waitPhase(vm, .playing)

        fake.emit(.phaseChanged(.ended))   // menu 再生終了
        for _ in 0..<200 where !fake.calls.contains("select:item") {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        let selects = fake.calls.filter { $0 == "select:item" }
        XCTAssertEqual(selects.count, 1,
                       "menu ended で最初の本体タイトルへの select が 1 回発火しない（自動進行）")
        XCTAssertTrue(fake.calls.contains("play"), "自動進行で再生を続けない（first-play 実挙動）")

        // 実 engine は select(item:) で selectionChanged を送る。それが届いた後の
        // 本体タイトル の ended では自動進行を重ねない（menu 限定の政策）。
        fake.emit(.selectionChanged(PlaybackSelection(item: ItemID(1))))
        for _ in 0..<200 where vm.selected?.item != ItemID(1) {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        fake.emit(.phaseChanged(.ended))
        try? await Task.sleep(nanoseconds: 30_000_000)
        let selects2 = fake.calls.filter { $0 == "select:item" }.count
        XCTAssertEqual(selects2, 1, "本体タイトルの ended で自動進行が再発火した（menu 限定のはず）")
    }

    func testDVDWithoutMenuDoesNotAutoplay() async {
        let fake = FakePlayerEngine()
        fake.presetStructure = MediaStructure(itemKind: .dvdTitles, items: [
            MediaItem(id: ItemID(1), titleNumber: 1, duration: CMTime(value: 60, timescale: 1)),
            MediaItem(id: ItemID(2), titleNumber: 2, duration: CMTime(value: 30, timescale: 1)),
        ])
        let vm = PlayerViewModel(engine: fake)
        vm.open(url: URL(fileURLWithPath: "/tmp/does-not-matter.iso"))
        await waitPhase(vm, .ready)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(vm.selected?.item, ItemID(1), "menu の無い盘は先頭タイトルが既定選択（従来形）")
        XCTAssertFalse(fake.calls.contains("play"),
                       "menu の無い素材で自动再生する（#17 の user gate は menu 以外従来まま）")
    }

    func testSingleItemSourceHidesTitleMenu() async {
        let fake = FakePlayerEngine()
        let vm = PlayerViewModel(engine: fake)
        vm.open(url: URL(fileURLWithPath: "/tmp/does-not-matter.mpg"))
        await waitPhase(vm, .ready)
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(vm.hasTitleChoice, "単一項目 source でタイトルメニューが出る（03 §5）")
    }

    // MARK: スクラブ（ドラッグ中は engine を触らない。離した時に .exact を 1 回）

    func testScrubCommitsExactlyOnceWithExactTolerance() async {
        let fake = FakePlayerEngine()
        let vm = PlayerViewModel(engine: fake)
        fake.emit(.phaseChanged(.ready))
        await waitPhase(vm, .ready)

        vm.beginScrub()
        vm.previewScrub(20)
        // ドラッグ中に engine の位置更新が来ても、つまみはユーザー操作に固定（#17 §2）。
        fake.emit(.positionUpdated(position: CMTime(seconds: 5, preferredTimescale: 1),
                                   duration: nil, clockDriftMS: 0))
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(vm.positionSeconds, 20, accuracy: 0.001, "ドラッグ中はいかなる位置も受け取らない")
        XCTAssertFalse(fake.calls.contains("seek"), "ドラッグ中は seek しない")

        vm.commitScrub()
        for _ in 0..<200 where !fake.calls.contains("seek") {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(fake.calls.contains("seek"), "離した時に seek する")
        XCTAssertEqual(fake.lastSeekTolerance, .exact, "確定操作は .exact（#17 の対応表）")

        // seek 完了後（fake は .playing にして位置を返す）は通常どおり位置が追随する。
        fake.emit(.positionUpdated(position: CMTime(seconds: 25, preferredTimescale: 1),
                                   duration: nil, clockDriftMS: 0))
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(vm.positionSeconds, 25, accuracy: 0.001, "ドラッグ解除後は位置更新を受け取る")
    }

    // MARK: mediaRemoved は空状態へ（#17 §9。位置の保存は Phase 2）

    func testMediaRemovedReturnsToEmpty() async {
        let fake = FakePlayerEngine()
        let vm = PlayerViewModel(engine: fake)
        fake.emit(.phaseChanged(.playing))
        await waitPhase(vm, .playing)
        fake.emit(.mediaRemoved)
        await waitPhase(vm, .empty)
        XCTAssertTrue(fake.calls.contains("close"))
    }

    // MARK: 音量（#17 §2 のスライダー → engine の setVolume。phase を変えない）

    func testVolumeChangesReachEngineWithoutPhaseChange() async {
        let fake = FakePlayerEngine()
        let vm = PlayerViewModel(engine: fake)
        fake.emit(.phaseChanged(.ready))
        await waitPhase(vm, .ready)
        vm.volume = 0.5
        for _ in 0..<200 where fake.lastVolume == nil {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(fake.lastVolume ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertFalse(fake.calls.contains("play") || fake.calls.contains("pause"),
                       "音量変更は phase を変えない（INV-3 と同じ非侵襲性）")
    }

    // MARK: サーフェス配線（view → sink → engine の attachVideoSink）

    func testAttachSurfaceWiresSinkIntoEngine() async {
        let fake = FakePlayerEngine()
        let vm = PlayerViewModel(engine: fake)
        vm.attachSurface(layer: AVSampleBufferDisplayLayer())
        for _ in 0..<200 where fake.attachedSink == nil {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        let attached = fake.attachedSink != nil
        XCTAssertTrue(attached, "view の layer が engine の sink 口につながっていない")
    }
}

// MARK: - 暫定サーフェスの比率解決（#17 §2「AspectResolution で letterbox/pillarbox」の核）
//
// 720x480 + BT.601 NTSC サンプル比 + MPEG display extension 4:3 → 表示は 4:3 でなければならない
// （像素をそのまま出すと 3:2 になる。PAR を無視しないことの回帰）。

private final class AspectBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func append(_ value: Double) { lock.withLock { values.append(value) } }
    var all: [Double] { lock.withLock { values } }
}

@MainActor
final class SurfaceAspectTests: XCTestCase {
    func testNTSCSampleAspectResolvesToFourThreeAndEnqueues() async throws {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 720, 480,
                                         kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                         nil, &pixelBuffer)
        XCTAssertEqual(status, noErr)
        guard let pixelBuffer else { return XCTFail("pixel buffer が作れない") }

        var format = VideoFormatDescription(codedSize: PixelSize(width: 720, height: 480))
        format.sampleAspect = .bt601NTSCSample
        format.aspectSignals = AspectSignals(mpegAspectInformation: .dar4x3,
                                            sampleAspectFromStandard: .bt601NTSCSample)
        let frame = DecodedVideoFrame.make(
            id: FrameID(1), pixelBuffer: pixelBuffer, format: format,
            pts: CMTime(seconds: 0, preferredTimescale: 1),
            duration: CMTime(seconds: 1.0 / 29.97, preferredTimescale: 30_000),
            isKey: true)

        let box = AspectBox()
        let sink = SurfaceSink(layer: AVSampleBufferDisplayLayer()) { dar in
            box.append(dar)
        }
        await sink.receive(frame)

        let got = box.all
        XCTAssertEqual(got.count, 1, "比率の解決は format 単位で 1 回")
        XCTAssertEqual(got.first ?? 0, 4.0 / 3.0, accuracy: 0.0001,
                       "NTSC 720x480（PAR 10:11）の表示は 4:3")
    }
}
