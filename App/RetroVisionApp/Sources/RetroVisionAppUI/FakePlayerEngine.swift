import AVKit
import CoreMedia
import Foundation
import RVMediaCore
import RVMediaSources
import RVPlaybackEngine

// MARK: - FakePlayerEngine（02 §6: 同期スタブ。UI の単体テスト・プレビュー用）
//
// PlayerEngine の実装を持たない側（UI）に置く。PlayerViewModel はこの fake だけで
// 全 phase の表示と有効・無効の表を検証できる（#17 受け入れ基準: 「FakePlayerEngine 上で
// 全 phase の表示を確認できる」）。実デコードは使わない。

@MainActor
public final class FakePlayerEngine: PlayerEngine, VideoSurfaceBinding {
    public private(set) var calls: [String] = []
    public private(set) var attachedSink: (any VideoPresentSink)?
    public private(set) var lastSeekTolerance: SeekTolerance?
    public private(set) var lastVolume: Double?

    private let stream: AsyncStream<PlayerEvent>
    private let continuation: AsyncStream<PlayerEvent>.Continuation
    private var structureRef: MediaStructure?

    public init() {
        let (stream, continuation) = AsyncStream.makeStream(of: PlayerEvent.self,
                                                            bufferingPolicy: .bufferingNewest(64))
        self.stream = stream
        self.continuation = continuation
    }

    /// テスト・プレビューから状態を流し込む口（実 engine の events と同じ形で行う）。
    public func emit(_ event: PlayerEvent) {
        continuation.yield(event)
    }

    public func finishEvents() {
        continuation.finish()
    }

    // MARK: PlayerEngine

    public func load(_ source: any MediaSource, selection: PlaybackSelection?) async throws -> MediaStructure {
        calls.append("load")
        let structure = presetStructure ?? MediaStructure(itemKind: .singleItem,
                                                         items: [MediaItem(id: selection?.item ?? ItemID(1),
                                                                          duration: CMTime(seconds: 60, preferredTimescale: 1))])
        // 実 engine（EngineCore.load）と同じ意味論: selection nil は open 後、構造の先頭
        // item で解決される（メニュー増分。UI は selectionChanged からのみ派生状態を得る）。
        let selection = selection
            ?? structure.items.first.map { PlaybackSelection(item: $0.id) }
            ?? PlaybackSelection(item: ItemID(1))
        let isReload = nilWasSet
        nilWasSet = true
        structureRef = structure
        // 実 engine（EngineCore.load）と同じ順序で流す — VM の派生状態は events からのみ
        // 更新されるので、実装側の単一経路（tracksChanged → selectionChanged → 再 load 時の
        // positionUpdated(.zero)）を fake も踏む（02 §6 の意味論）。
        emit(.phaseChanged(.preparing))
        emit(.structureChanged(structure))
        emit(.tracksChanged(structure.items.first(where: { $0.id == selection.item })?.trackTable
                             ?? structure.items.first?.trackTable ?? []))
        emit(.selectionChanged(selection))
        if isReload {
            emit(.positionUpdated(position: .zero,
                                  duration: structure.items.first(where: { $0.id == selection.item })?.duration
                                    ?? structure.items.first?.duration, clockDriftMS: 0))
        }
        emit(.phaseChanged(.ready))
        return structure
    }
    private var nilWasSet = false
    /// テスト・プレビューで multi-title 構造など既知の構造を流したいときの差し込み口
    /// （タイトルメニューの検査用。未設定なら従来どおり singleItem）。
    public var presetStructure: MediaStructure?

    public func close() async {
        calls.append("close")
        structureRef = nil
        emit(.phaseChanged(.empty))
    }

    public func play() async { calls.append("play"); emit(.phaseChanged(.playing)) }
    public func pause() async { calls.append("pause"); emit(.phaseChanged(.paused)) }
    public func seek(to time: MediaTime, tolerance: SeekTolerance) async {
        calls.append("seek")
        lastSeekTolerance = tolerance
        emit(.phaseChanged(.seeking(target: time)))
        emit(.positionUpdated(position: time, duration: structureRef?.items.first?.duration, clockDriftMS: 0))
        emit(.phaseChanged(.playing))
    }
    public func step(_ direction: StepDirection) async { calls.append("step:\(direction)") }
    public func setRate(_ rate: Double) async { calls.append("setRate:\(rate)") }
    public func setVolume(_ gain: Double) async { calls.append("setVolume"); lastVolume = gain }
    public func select(_ track: TrackID, for kind: TrackKind) async { calls.append("select:track") }
    public func select(item: ItemID) async { calls.append("select:item") }
    public func apply(_ settings: PlayerSettings) async { calls.append("apply") }

    public var stateSnapshot: PlayerStateSnapshot { .init() }
    public func events() -> AsyncStream<PlayerEvent> { stream }
    public var structure: MediaStructure? { structureRef }

    // MARK: VideoSurfaceBinding（本物の DefaultPlayerEngine と同じ配線口）

    public func attachVideoSink(_ sink: (any VideoPresentSink)?) async {
        calls.append("attachVideoSink")
        attachedSink = sink
    }
}
