# 10. 未決事項の意思決定ログ

設計書本文中で「既定値」として書いたものは、ここに対応する OQ を持つ。ゲートで決め、決まったものは本文に反映して閉じる。

| ID | 決定が必要な事項 | 当面の既定値 | 決めるために必要な実験・情報 | ゲート | 時期 |
|---|---|---|---|---|---|
| OQ-01 | libdvdread / libdvdnav の導入形態（ビルド設定、`DVDFileIO` / file-image 経由で `BlockReader` を差し込めるか） | libdvdread で ifo を読み、ISO は自力の ISO9660/UDF リーダで読む | libdvdread の block-reader hook で VIDEO_TS フォルダ・ISO・raw device の 3 種が通るかの実験 | G2 前 | Phase 0 |
| OQ-02 | FFmpeg の版・ビルド構成（どの codec / demuxer を含めるか、LGPL 構成に留めるか）と配布形態 | 固定 version の最小構成（MPEG-PS/TS、MPEG-2、AC-3、DTS、H.264、AAC、MP4/MKV）を static で持つ | 配布物に現れる記述義務の整理。build-flags の再現 CI | G1 前 | Phase 0 |
| OQ-03 | 保護 Disc（CSS）および将来の AACS の扱い。libdvdcss で足りるか、商用再生 SDK が必要か | 非保護 / ユーザーオーサリングのみ対応。CSS 盤は `.protectedNeedsLicense` | ライセンサー・SDK ベンダーへの問い合わせ（再生だけでなく**復号後のフレーム処理の権利**も含む） | G2（対応範囲）/ Phase 3 以降（契約） | Phase 2 で問い合わせ開始 |
| OQ-04 | ISO 内のファイル構造解決（UDF / 領域跨ぎ / ブリッジ Disc）の対応範囲 | ISO9660 の主形態のみ。UDF は要検証 | 市販盤の ISO サンプルで open できる割合を測る | G2 後 | Phase 2 |
| OQ-05 | プロセス分割（外部プロセス化）が要るか | しない（[00 §4](00-architecture.md)） | 保護 Disc のライセンス済み SDK が分離実行を要求するか | G2 | Phase 2〜3 |
| OQ-06 | demux パケットの所有（`Data` コピー vs FFmpeg buffer 参照の維持） | コピーして Swift 側で所有 | `StageID.demux` の実測（DVD では 1 frame あたりの packet 数が小さい） | G1 後 | Phase 1 |
| OQ-07 | Core ML への変換経路（coremltools の version、Python 環境、 MIL vs 静的変換、dynamic shape の可否）と、Metal feature provider API が使えるか | 固定寸法 + タイル分割。provider API は使わない（この SDK に見つからない） | 候補モデル 2〜3 本の変換実験と数値一致性検査 | G3 | Phase 3 |
| OQ-08 | デコード方式 A（FFmpeg videotoolbox hwdevice）と B（`VTDecompressionSession` 直接）の選択 | A。フィールド情報が失われる場合は 05 §5 で補完 | interlaced MPEG-2 でフィールド順序・キャデンスが保持できるか。deint 品質への影響 | G2 | Phase 2 |
| OQ-09 | 再生速度（0.5 倍速等）・音声 pitch の扱い | 1.0 のみ | 同期機構への影響（AudioClock の rate 実装コスト） | — | MVP 後 |
| OQ-10 | 表示同期の方針（`CAMetalLayer.displaySyncEnabled` + 未来 present 予約 vs `CVDisplayLink`） | 前者（05 §7） | 59.94 / 60.00 / 120 Hz で jitter 実測。25 fps 素材の periodic 補正の品質 | G2 | Phase 2 |
| OQ-11 | モデルの配布形態（バンドル同梱 / 初回ダウンロード）と更新 | バンドル同梱（1 本のみ）。追加モデルは手動追加 | バンドルサイズ、モデルの配布条件、`MLModelCollection` の使途 | G3 後 | Phase 4 |
| OQ-12 | アプリの最小デプロイメントターゲット | 製品下限は未決。コード上の下限は macOS 15（`Package.swift`。CI runner でのビルドを通すための暫定値）。新 API は runtime 検査でガードする | 使用する API の最小要求（[design/README](design/README.md) の確認済みリストを base に検証）と、CI runner の macOS 版 | G1 前 | Phase 0 |
| OQ-13 | 字幕レンダリングの範囲（DVD SPU / ASS / TextRender） | SPU + SRT/VTT。ASS は描画しない（04 §7） | ASS の需要（アニメ素材でのスタイル指定） | — | MVP 後 |
| OQ-14 | 2x SR が実時間に収まらない場合の製品方針（#7 を非リアルタイム機能に縮小するか、非 AI 品質を標準とするか） | 非 AI 経路を標準品質にし、#7 は非リアルタイムの復元機能へ縮小 | G3 の実測値と、意図した画質が得られるかの主観評価 | G3 | Phase 3 末 |
| OQ-15 | Blu-ray の対応範囲（非暗号化 BD のみ / 商用 AACS） | 対象外（Phase 6 の別ゲート） | 想定利用フォーマットの実態、SDK の見積り | BD ゲート | Phase 3 以降に調査 |

## 意思決定の運用

1. 決めたら**この表に「決定」と「日付」「根拠（実験 ID / レポート ID）」を書く**。本文の既定値は同じ commit で更新する。
2. ゲートで決められなかった項目は、次のゲートに持ち越さず、**当面の既定値を製品方針として固定**する（例: OQ-14 は G3 で必ず決める）。
3. ライセンス関連（OQ-02、OQ-03、OQ-15）は実験では決められない。問い合わせて回答が来るまで**対応しないと表明する**側の決定を先に置く。

## 現在、設計を進めるうえで先に埋めるべきもの

- OQ-01、OQ-02（Phase 0。これが決まらないと依存が固定できず、計測の再現性が担保できない）
- OQ-12（デプロイメントターゲット。API 選択に影響する）
- OQ-07 の前半（モデル変換環境。G3 の評価が始められない）
