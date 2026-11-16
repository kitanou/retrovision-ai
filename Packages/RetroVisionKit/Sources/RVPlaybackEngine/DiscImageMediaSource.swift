import Foundation
import RVMediaCore
import RVMediaSources
import RVDecode

// MARK: - ディスクイメージ（.iso 等）の MediaSource（03 §3、§6。#3）
//
// 実測で決まった方針（2026-11-16。docs/design/10 の決定ログ）:
//   - AVFoundation は ISO9660/UDF を直接 demux できない（AVError -11828 実測）。
//   - ISO を内部で read して AVFoundation に渡す无名ブジェクト経路は、合成 ISO の
//     ブロック supply で loadTracks が解決せずハングした（30 s 超で断念。#3 の
//     comment に記録。無名経路は別ゲートの実験として OQ のまま）。
//   - よって v1 は **システムのマウント経路**を使う: `diskutil image attach` →
//     出たボリュームの VIDEO_TS を VideoTsMediaSource で読む → close 相当で
//     `diskutil image eject`。CLI 選択の実測: hdiutil は非推奨警告が出るため
//     diskutil を使う（hdiutil imageinfo/mount は動くが将来警告に依存したくない）。
//   - マウント解除の時期: engine の close では source 側へ close 口がない（02 §2 の
//     現状契約）。deinit で best-effort 解除 + 明示 close() を用意する。
//     解除漏れは UI からの取り出しで回収できる（実運用の eject と同じ）。

public actor DiscImageMediaSource: MediaSource, DemuxerProviding {
    public let isoURL: URL
    private var internalSource: VideoTsMediaSource?
    private var mountedDevice: String?   // /dev/diskN（eject 用）

    public init(isoURL: URL) { self.isoURL = isoURL }

    nonisolated public var descriptor: SourceDescriptor {
        SourceDescriptor(id: SourceID(Self.stableID(for: isoURL.standardizedFileURL.path)),
                         kind: .discImage,
                         displayName: isoURL.deletingPathExtension().lastPathComponent,
                         location: .fileURL(isoURL))
    }

    public func open() async throws -> OpenedSource {
        // 冪等（タイトル切り替えの再 load で再 attach しない。実測: 既に attached の
        // ISO を diskutil image attach すると「〜 1」付きの別マウントが増える）。
        // 内部の VideoTsMediaSource 側の open cache が構造を返す。
        if let internalSource { return try await internalSource.open() }
        let (device, mountPoint) = try await Self.attach(isoURL)
        self.mountedDevice = device
        let source = VideoTsMediaSource(rootURL: mountPoint)
        self.internalSource = source
        do {
            return try await source.open()
        } catch {
            // 構造が無かった/開けなかった場合はマウントを残さない（取り残しの実測回避）。
            // 内部 source も降ろす（残すと次の open が冪等経路で外れたボリュームを向く）。
            await Self.detach(device)
            self.mountedDevice = nil
            self.internalSource = nil
            throw error
        }
    }

    /// Engine 向けの配線口（open() 済みの内部 VideoTsMediaSource へ委派。同一实例の
    /// 約束は内部 source の cache が守る）。open() 前は構造未知なので空の列を持つ
    /// だけ（engine は open 成功後にしか呼ばない — DemuxerProviding.swift の契約）。
    public func makeDemuxer(itemId: ItemID) async -> any Demuxer {
        if let internalSource {
            return await internalSource.makeDemuxer(itemId: itemId)
        }
        return AVFoundationDemuxer(url: isoURL)
    }

    /// マウント解除（明示。deinit の best-effort とは別に、テストと UI の停止経路から呼ぶ）。
    /// 解除前に内部 source の demuxer cache を降ろす（AVFoundation がボリューム上の
    /// 開いた取扱いを持つと eject が失敗する — 実測で降ろしてから eject の順に固定）。
    public func close() async {
        if let internalSource {
            await internalSource.close()   // 修復写しの削除を含む（Demuxer.close 伝搬）
        }
        if let device = mountedDevice {
            await Self.detach(device)
            mountedDevice = nil
        }
    }

    deinit {
        // actor の deinit から async は呼べないため、発火だけの eject（best-effort）。
        if let device = mountedDevice {
            Task.detached(priority: .utility) { await DiscImageMediaSource.detach(device) }
        }
    }

    // MARK: マウント機構（diskutil。実測: hdiutil は deprecated 警告、diskutil は clean）

    struct CLIResult: Sendable { let status: Int32; let stdout: String; let stderr: String }

    static func run(_ launchPath: String, _ arguments: [String]) async throws -> CLIResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = arguments
            let outPipe = Pipe(), errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            try process.run()
            process.waitUntilExit()
            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return CLIResult(status: process.terminationStatus, stdout: out, stderr: err)
        }.value
    }

    /// ISO をアタッチして (diskutil eject に渡せる識別子, マウント点) を返す。
    /// `diskutil image --plist attach` の plist から取る（テキスト整形に依存しない）。
    /// 実測（2026-11-16）: system-entities[].mount-point にマウント点と同 entity の
    /// device-node。解除は `diskutil eject <node or mount>`（`diskutil image` に
    /// eject/detach サブコマンドは無く、usage エラーになる — 実測で確定）。
    static func attach(_ isoURL: URL) async throws -> (String, URL) {
        let result = try await run("/usr/sbin/diskutil", ["image", "--plist", "attach", isoURL.path])
        guard result.status == 0 else {
            throw PlaybackError(kind: .source(.unsupportedStructure),
                                causeDescription: "diskutil image attach 失敗（exit \(result.status)）: \(result.stderr)",
                                recovery: .needsUserAction(.insertDisc),
                                userMessage: "ISO をマウントできませんでした。イメージが壊れている可能性があります。")
        }
        let plist = try? PropertyListSerialization.propertyList(
            from: Data(result.stdout.utf8), format: nil) as? [String: Any]
        let entities = plist?["system-entities"] as? [[String: Any]] ?? []
        for entity in entities {
            guard let mountString = entity["mount-point"] as? String, !mountString.isEmpty else { continue }
            // 実測のキー名: dev-entry（値は "disk11" のようにノード名のみ。/dev/ 無し）。
            let device = (entity["dev-entry"] as? String) ?? mountString
            return (device, URL(fileURLWithPath: mountString))
        }
        throw PlaybackError(kind: .source(.unsupportedStructure),
                            causeDescription: "diskutil plist 出力に mount-point がありません: \(result.stdout.prefix(400))",
                            recovery: .needsUserAction(.insertDisc),
                            userMessage: "ISO をマウントできませんでした（マウント点が分かりません）。")
    }

    static func detach(_ target: String) async {
        let first = try? await run("/usr/sbin/diskutil", ["eject", target])
        if (first?.status ?? -1) != 0 {
            // 実測（2026-11-16）: AVFoundation の開いた取扱いが抜けていると素の eject は
            // "at least one volume could not be unmounted" で失敗する。force は常に出る
            // （取り出し忘れの回収は force に頼る — UI の eject 同意は optical 実装まで棚上げ）。
            _ = try? await run("/usr/sbin/diskutil", ["eject", "force", target])
        }
    }

    private static func stableID(for path: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}
