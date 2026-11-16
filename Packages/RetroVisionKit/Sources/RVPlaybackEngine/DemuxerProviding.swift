import Foundation
import RVMediaCore
import RVMediaSources
import RVDecode

// MARK: - 再生線の demuxer 取り出し口（03 §2・§4 のスロット、#3 で一般化）
//
// OpenedSource は RVMediaSources の型で、RVMediaSources は RVDecode を import しない
// （00 §2）。そのため demuxer の生成・保持は source の型側に置きます。これまで
// EngineCore は「FileMediaSource だけ」を見る特例配線を持っていましたが、#3 で
// VIDEO_TS source が増えたため、item を引数に取る共通のスロットへ一般化します
// （単一項目の FileMediaSource は itemId を無視する退化ケース）。
//
// 契約: 返す demuxer は open() の probe と **同一实例**であること（track id の対応が
// 壊れるため。FileMediaSource の注記と同じ理由で、これは実測で決まった制約です）。

public protocol DemuxerProviding: Sendable {
    /// 指定 item（タイトル）を読む demuxer を返す。item が無い場合は nil でなく
    /// 最初の item の demuxer を返してよい（engine が既に通った item を選ぶ）。
    func makeDemuxer(itemId: ItemID) async -> any Demuxer
}

extension FileMediaSource: DemuxerProviding {
    /// 単一項目 source の退化ケース（item は選ばない。同一实例の約束は cachedDemuxer で守る）。
    public func makeDemuxer(itemId: ItemID) async -> any Demuxer {
        makeDemuxer()
    }
}
