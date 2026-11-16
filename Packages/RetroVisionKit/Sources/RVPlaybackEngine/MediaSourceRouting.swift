import AVFoundation
import Foundation
import RVMediaCore
import RVMediaSources
import UniformTypeIdentifiers

// MARK: - 開いた URL を source 型へ割り当てる（#3。App の「一つの入口」対応）
//
// 実測で確まった形:
//   - ディレクトリ → VideoTsMediaSource（VIDEO_TS を内側にも持つボリュームルート、
//     VIDEO_TS 直下、どちらの選び方でも開ける — findVideoTSDirectory の両対応）。
//     DVD-Video でないフォルダは .unsupportedStructure の構造化エラー（#3 受入基準）。
//   - ディスクイメージ系 UTI（.iso/.dmg/.cdr…）→ DiscImageMediaSource（diskutil mount 経路。
//     FileMediaSource の disk-image 事前ゲート（-11828 実測）は安全網として残す —
//     ルーティングを外れた入口（drag & drop 等）からの直接開きを同じメッセージで止める）。
//   - その他ファイル → FileMediaSource（既存の挙動そのまま）。

public enum MediaSourceRouting {
    public static func makeSource(for url: URL) -> any MediaSource {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return VideoTsMediaSource(rootURL: url)
        }
        if isDiskImageURL(url) {
            return DiscImageMediaSource(isoURL: url)
        }
        return FileMediaSource(url: url)
    }

    /// FileMediaSource の判定と同じ基準（UTI が .diskImage に適合）。公開してよい形に
    /// 寄せる: 拡張子から決定的に判定する（中身を読まない — 事前ゲートの位置を保つ）。
    public static func isDiskImageURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .diskImage)
    }
}
