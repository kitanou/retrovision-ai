# 10. 未決事項の意思決定ログ

設計書本文中で「既定値」として書いたものは、ここに対応する OQ を持つ。ゲートで決め、決まったものは本文に反映して閉じる。

| ID | 決定が必要な事項 | 当面の既定値 | 決めるために必要な実験・情報 | ゲート | 時期 |
|---|---|---|---|---|---|
| OQ-01 | libdvdread / libdvdnav の導入形態（ビルド設定、`DVDFileIO` / file-image 経由で `BlockReader` を差し込めるか） | **縮小済み（2026-11-16、EXP-001）**。ファイル source の demux/decode は AVFoundation + VideoToolbox 直（FFmpeg 不使用で全 fixture 通過、F1）。残る判断は DVD 制御（IFO 読み・NAV、`DVDFileIO` の block-reader hook）だけ。Phase 4 の WMV1 ゲートで追加検討 | libdvdread の block-reader hook で VIDEO_TS フォルダ・ISO・raw device の 3 種が通るかの実験 | G2 前 | Phase 2 |
| OQ-02 | FFmpeg の版・ビルド構成（どの codec / demuxer を含めるか、LGPL 構成に留めるか）と配布形態 | **縮小済み（2026-11-16）**。Phase 1 の配布物に FFmpeg は含めない（未リンク、inventory 実測記録参照）。導入は DVD 制御 or WMV1 / DTS の復号（Phase 4 ゲート。DTS は AVFoundation がトラックとして列挙しないことを実測済み＝EXP-002 A6、dca fixture 登録済み）。Homebrew ffmpeg 9.0.2 は GPL-3.0 系であることも実測済み | 導入 decided 後に、配布物に現れる記述義務の整理と build-flags の再現 CI | WMV1 / DTS / DVD 制御の決定時点 | Phase 4 前 |
| OQ-03 | 保護 Disc（CSS）および将来の AACS の扱い。libdvdcss で足りるか、商用再生 SDK が必要か | 非保護 / ユーザーオーサリングのみ対応。CSS 盤は `.protectedNeedsLicense` | ライセンサー・SDK ベンダーへの問い合わせ（再生だけでなく**復号後のフレーム処理の権利**も含む） | G2（対応範囲）/ Phase 3 以降（契約） | Phase 2 で問い合わせ開始 |
| OQ-04 | ISO 内のファイル構造解決（UDF / 領域跨ぎ / ブリッジ Disc）の対応範囲 | ISO9660 の主形態のみ。UDF は要検証 | 市販盤の ISO サンプルで open できる割合を測る | G2 後 | Phase 2 |
| OQ-05 | プロセス分割（外部プロセス化）が要るか | しない（[00 §4](00-architecture.md)） | 保護 Disc のライセンス済み SDK が分離実行を要求するか | G2 | Phase 2〜3 |
| OQ-06 | demux パケットの所有（`Data` コピー vs 参照の維持） | **確定済み（2026-11-16、EXP-001 F2）**。`CompressedSample` が `CMSampleBuffer` 参照をそのまま運び、ES コピーは発生しない。`Data` 所有設計は不要 | `StageID.demux` の追加計測は必要ない（参照設計で通過済み）。DVD 経路で libdvdnav が生 Data を出す場合の橋渡しのみ Phase 2 で確認 | — | 完了 |
| OQ-07 | Core ML への変換経路（coremltools の version、Python 環境、 MIL vs 静的変換、dynamic shape の可否）と、Metal feature provider API が使えるか | 固定寸法 + タイル分割。provider API は使わない（この SDK に見つからない） | 候補モデル 2〜3 本の変換実験と数値一致性検査 | G3 | Phase 3 |
| OQ-08 | デコード方式 A（FFmpeg videotoolbox hwdevice）と B（`VTDecompressionSession` 直接）の選択 | **確定済み（2026-11-16、EXP-001）**。B 採用。A は比較以前に前提（FFmpeg demux）が消滅。field 順序は PCE から供給し、失われる素材（H.264 interlaced, F11）は 05 §5 の detector で補完。G2 の比較ゲートは解消 | 残りは検出品質の実測のみ（09 の検出器テスト） | — | 完了 |
| OQ-09 | 再生速度（0.5 倍速等）・音声 pitch の扱い | 1.0 のみ | 同期機構への影響（AudioClock の rate 実装コスト） | — | MVP 後 |
| OQ-10 | 表示同期の方針（`CAMetalLayer.displaySyncEnabled` + 未来 present 予約 vs `CVDisplayLink`） | 前者（05 §7） | 59.94 / 60.00 / 120 Hz で jitter 実測。25 fps 素材の periodic 補正の品質 | G2 | Phase 2 |
| OQ-11 | モデルの配布形態（バンドル同梱 / 初回ダウンロード）と更新 | バンドル同梱（1 本のみ）。追加モデルは手動追加 | バンドルサイズ、モデルの配布条件、`MLModelCollection` の使途 | G3 後 | Phase 4 |
| OQ-12 | アプリの最小デプロイメントターゲット | 製品下限は未決。コード上の下限は macOS 15（`Package.swift`。CI runner でのビルドを通すための暫定値）。新 API は runtime 検査でガードする | 使用する API の最小要求（[design/README](design/README.md) の確認済みリストを base に検証）と、CI runner の macOS 版 | G1 前 | Phase 0 |
| OQ-13 | 字幕レンダリングの範囲（DVD SPU / ASS / TextRender） | SPU + SRT/VTT。ASS は描画しない（04 §7） | ASS の需要（アニメ素材でのスタイル指定） | — | MVP 後 |
| OQ-14 | 2x SR が実時間に収まらない場合の製品方針（#7 を非リアルタイム機能に縮小するか、非 AI 品質を標準とするか） | 非 AI 経路を標準品質にし、#7 は非リアルタイムの復元機能へ縮小 | G3 の実測値と、意図した画質が得られるかの主観評価 | G3 | Phase 3 末 |
| OQ-15 | Blu-ray の対応範囲（非暗号化 BD のみ / 商用 AACS） | 対象外（Phase 6 の別ゲート） | 想定利用フォーマットの実態、SDK の見積り | BD ゲート | Phase 3 以降に調査 |

## OQ-16〜OQ-26（Phase 1/2 の実測から抽出した新しい未決、2026-11-16）

Phase 1 の実装・測定（[EXP-001](../experiments/EXP-001-dependency-and-videotoolbox.md)）によって、設計当時は想定しなかった穴が観測された。実在する穴だけを登録する。

| ID | 決定が必要な事項 | 当面の既定値 | 決めるために必要な実験・情報 | ゲート | 時期 |
|---|---|---|---|---|---|
| OQ-16 | 実素材フィクスチャの入手元と再配布権（manifest の `pending` 7 件: 実 DVD の VOB、保護盤、市販 H.264 素材等） | 開発は generated 合成素材。検証素材は所有盤から自己抽出し、repo には同梱しない | 素材提供元（自作盤で足りるか）と抽出・非公開利用の可否 | G2 | Phase 2 で着手 |
| OQ-17 | MP4 mux の MPEG-2 で残る `CVFieldDetail` の読み了と、検出器への供給順位（PCE とどちらを優先するか） | PCE 優先。detail 値は読むだけで使わない | 同一素材の field 声明をコンテナ・bitstream・detail で突き合わせる（mp4-01 fixture） | G2 | Phase 1 残作業 |
| OQ-18 | 初回フレームの**再生線での初回复号スパイク**の warmup 設計（open 直後の使い捨てデコード、セッション预热、測定の除外方法） | **実装・実測済み（2026-11-16、#12）**: セッションの `prepare()` が load の .preparing 中に先頭 3 帧を復号して**保持する**（捨てない・`reset()` は呼ばない — reset は VT session を invalid 化してスパイクを再払する）。音声は prefill まで積んで start は play まで遅らせる。統計の除外規則: warmup 分は `warmupStageMS` に分離し常時統計（`decodeStageMS` / `decodePerFrameMS`）に混ぜない（テスト 2 本で両辺を固定） | 実測（04 §9）: 初回复号スパイク 50.5〜68.9 ms（合成 11 素材・再生線）。warmup で play→初帧提示は 59〜69 ms → 1.1〜3.6 ms（AC-3 で 16.5 ms）。**EXP-001 の 44〜70 ms は旧コードの decode-all に現れたもので、現在のコードの decode-all は max 1.45 ms（スパイク無し）— スパイクは再生線固有**。マルチストリーム切替時の再 warmup 要否は Phase 2（トラック切替の実装時に同じ prepare を使う） | G2 | 完了 |
| OQ-19 | 音声復号とクロックの実現（AC-3 を AVFoundation の PCM outputSettings で復号できるか。AudioClock の jitter） | **実装・実測済み（2026-11-16、#10）**: AVAssetReader の linear PCM 出力で AC-3 を復号する（依存ゼロ維持）。quantum 分割は AudioDecoder 実装側（A2、`AVFoundationAudioDecoder.quanta` で 480 帧へ。テスト固定）。クロックの原料は PCM 経路の valid PTS + 帧数（A3）。`AVFoundationAudioSink` + `AudioClock` を実装し、in-loop の drift を実測（04 §9: p50 +6.9 / p95 +10.6 ms、デッドバンド帯域内）。**DTS は AVFoundation がトラックを列挙しない（A6）ため Phase 4 の shim ゲートまで非対応**（`AudioPathTests` で回帰固定） | 5.1 配置・実素材の jitter 分布は実盤で再測（OQ-16）。実測（realtimeFactor ≈1100、合成素材での clock jitter は上にとどまる） | G1（clock 部分） | 完了（実盤計測は OQ-16 に引き継ぎ） |
| OQ-20 | SW 復号フォールバック（`SoftwareDecoder`）の実現方式（VideoToolbox が弾く pixfmt・codec — WMV1 等） | libavcodec shim。ただし**実際に対象素材が現れるまで作らない**（無依存方針を壊さない） | WMV1 fixture が AVFoundation で開けるかの測定（未実施） | Phase 4 | 対象が判明した時点 |
| OQ-21 | 合成 fixture の再生成一致性（ffmpeg の版で bit が変わりうる。sha を検証にするか記録にするか） | **決定済み（下記決定ログ）**: `status: generated` で Git 同梱。sha は記録（検査しない） | CI の ffmpeg バージョン漂移の実測 | — | 決定 |
| OQ-22 | 60i 素材のキャデンス（film-origin pull-down）対応の範囲と ground truth | 未対応（現セットに flag 付き pull-down 素材がない） | 市販 DVD 映画素材の flags と検出器の突合 | G2 | Phase 2 |
| OQ-23 | seek 再開直後にも zero-sample buffer（`hasSampleData == false`）が現れるか（F5 の再発条件） | **決定済み（下記決定ログ・#13）**: 出る。cold read でも seek 再開直後でも 0 長 sample が現れることを実測で確認（各 2 件）。demux 縁の間引きは両経路で必須。`gatedEmptySampleCount` で診断を残す | 実測（04 §6・§9）: cold 180 sample 中 2 件 / seek(3.0s) 後 96 sample 中 2 件。decode 段に届いた件数は 0（-12902 ゼロ） | G1 | 完了 |
| OQ-24 | ビルド成果物の署名方針（unsigned の SPM debug binary が一部環境で SIGKILL=exit 137。CI と配布の関係） | ビルド後 ad-hoc 署名（`codesign --force --sign -`）。Makefile/CI で実施 | 配布形態の要件（hardened runtime・entitlements） | G4 | Phase 4 |
| OQ-25 | H.264 interlaced 素材の field 順序の情報源（F11 で全て消える）— detector の検証素材をどう用意するか | H.264 は detector 経路で受け入れる。順序の ground truth は生成時情報で持つ | h264 fixture での検出精度比較（生成時に正解既知） | G2 | Phase 2 |
| OQ-26 | #5（Metal 提示）が載るまでの映像提示の形（#2 が先、#5 が後の順序に対する間つなぎ） | **暫定既定で実装済み（下記決定ログ #14）**: engine は present 済み帧を `VideoPresentSink` で UI に渡す（in-flight 3、超過は `displayMissed` に計上）。UI 側は AVSampleBufferDisplayLayer に enqueue のみ。比率は帧の format から AspectResolver で解決 | 実装・回帰固定（PresentHandoffTests の保存則 / SurfaceAspectTests の 4:3 / アプリ e2e）。#5 の Metal 提示で置換されるまで暫定 | G2 | 完了（#5 で置換前提） |

## 決定ログ

### 2026-11-16 — EXP-001 にもとづく決定（根拠: [docs/experiments/EXP-001](../experiments/EXP-001-dependency-and-videotoolbox.md)）

- **OQ-01（縮小）・OQ-02（延期）**: ファイル source の再生に FFmpeg は要らない。AVFoundation demux（`outputSettings = nil` の ES パススルー）+ `VTDecompressionSession` 直接で全 10 fixture が open→全サンプル復号に通過した。FFmpeg の導入判断は **DVD 制御（IFO/NAV）と Phase 4 の WMV1 ゲート**に分離した。
- **OQ-08（解消）**: 案 B 採用。実測スループット 176〜1555 fps（実時間要件 29.97 fps）、decode p50 0.4〜1.7 ms。案 A との G2 比較は実施しない。
- **OQ-06（完了）**: ES のコピーは発生しない参照設計（`CompressedSample` が `CMSampleBuffer` を復号直前まで運ぶ）。`Data` 所有への切替えは行わない。
- **フレームレート解決鎖**（01 §2 / 04 §2 に反映済み）: container hint（既知標準に一致する場合のみ使用）→ MPEG-2 bitstream → PTS span（ソート済みユニーク PTS ÷ 総フレーム数。demux 順＝decode 順の平均間隔は GOP 並替で約 4 倍ずれる）。解決しない場合は `.formatRejected`。**NTSC 既定に倒さない**。全 10 fixture で解決を確認（切り詰め素材は container hint で解決）。
- **field 順序の供給元**: MPEG-PS では順序は PCE の `top_field_first` のみに載る（container の `CVFieldCount` は本数だけ）。全 fixture で bottom-first を実測。H.264 interlaced では復号段階で field 信号が全て失われるため、**05 §5 の detector 経路は補助ではなく必須の経路**である（OQ-17/OQ-25 で継続）。
- **提示順序の責任**（04 §3 に反映済み）: 同期 `VTDecompressionSession` の出力は decode 順。decoder が 1 サンプル分保持して PTS 順に組み替え、提示可能分だけ返す。統合テストで固定。
- **色キャリア**: 復号 pix_fmt は `420v`（BT.601・映像 range）でメタデータと一致。ただし `Guesses` フラグが立つ component range があるため、声明値の優先読みは component range 側（01 §2 に反映済み）。

### 2026-11-16 — 再生線前半（#11）の実装決定（映像のみ。実測は 04 §9 の表に記録）

- **仮クロック（映像のみ）**: 提示時刻 = 初回提示の wall 基点 + メディア PTS 差分。音声 master clock（04 §5）確立までの暫定だが、Phase 2 の Metal 提示（#5）は**同じフックに PresentSchedule を差し込む**形へ進める。TimeSource 注入で決定的テスト（DeterministicTimeSource）を先に固定した。
- **遅延フレームはドロップせず提示し `late++`**（02 §1 の「連続性最優先」の徹底）。`presented` は増え、`realTimeFactor` は維持される。late は測定パラメータ（既定 2 ms 閾値）の産物である点を 04 §9 に明記。
- **待ちは締切合わせ**: `run()` のスリープは固定 1 ms ポーリングから「キュー先頭 PTS の締切から逆算」に変えた（MPEG-2 系の late 5→0 を実測）。固定ポーリングは late を量子の産物で膨らませるため測定として不適。
- **pause/resume はクロック基点の再アンカー**（停止区間が後方遅延に積算されない）。testPauseResumes で固定。
- **比率未声明素材（H.264 mp4 等）は load が `chooseAspect` を要求**——resolver が推測で 4:3 に倒さない設計（01 §2）どおりの動作と確認。headless 計測（probe-play）だけ「明示 4:3 を選んだユーザー」の代理を JSON に記録して通す。UI（#2）の実装まで既定値は作らない。
- **H.264 系の late（22/29）の帰属を確定**: 復号スループット不足ではない（realTimeFactor 0.9998・全帧提示）。同一呼吸内で同期復号（interlaced H.264 p50 5.7 ms）を済らせてから提示判定する構造の阻塞。**構造的修復は #5（復号と提示時刻の分離）**。当面は数値を残して受け取る。
- **実測された原価**: 復号 p50 — MPEG-2 2.6 ms、H.264 progressive 1.6〜1.9 ms、**H.264 interlaced 5.7 ms（progressive の約 3 倍）**。04 §1 の videoDecode 予算 3 ms は MPEG-2 では満たす interlaced H.264 では超過。Phase 2 の 05 §1 見直し資料。
- **素材の穴は素材のまま測る**: 切り詰め素材には提示順序上の PTS 穴（100 ms 級）が実在（ffprobe で確認）。テストは「提示間隔=pts 間隔 ±2 ms」で検査し、固定値（33.37 ms 期待）では検査しない。
- 新ツール: `make probe-play`（EngineCore 経由の実測。nightly CI が `probe-*.json` と `play-*.json` を収集）。

### 2026-11-16 — EXP-002 にもとづく決定（根拠: [docs/experiments/EXP-002](../experiments/EXP-002-audio-pcm-path.md)）

- **OQ-19（復号経路部分）**: **AC-3 → PCM は AVFoundation の linear PCM 出力で復号する**（A1。実時間率 ≈1100×、要求仕様どおりの 48 kHz/int16/packed 出力）。FFmpeg shim・AudioToolbox 自前管理は音声には使わない。依存ゼロ方針は音声にも及ぶ。
  - 副次的事実として設計へ反映: 変換出力は 8192 帧（≈171 ms）に結合されるため 10 ms quantum 分割は AudioDecoder 実装側の責任（A2）。passthrough 経路は ES が ~1.5 s 結合で末尾 PTS が invalid（A3）— クロック原料は PCM 経路の valid PTS + 帧数を使う。
  - 未決のまま残る: AudioSink/clock の jitter 実測（#10 の実装作業）、5.1ch 配置（実盤＝OQ-16）。
- **OQ-18（拡張）**: 音声側にも初期化コスト（passthrough 計 24 ms の初バッチ）がある（A5）。warmup は映像・音声で一括设计すること。
- **DTS（OQ-02 の測定された例）**: AVFoundation は MPEG-PS 内の DTS をトラックとして列挙しない（A6、警告も出ない = 黙って消える不是）。DVD-Video で音声必須は LPCM/AC-3。**当面の既定: Phase 4 の FFmpeg shim ゲートまで DTS 非対応**。shim 実装時の受け入れ素材として `ntsc480i-dts-01.mpg`（ffmpeg `-strict -2 -c:a dca` で生成、manifest 登録済み）を使う。

### 2026-11-16 — 音声線（#10）の実装決定（実測は 04 §4/§5/§9 に反映）

- **契約は実測で確定した形に同期した**（04 §4 のコードブロックを実装とおりへ更新）: 音声の入口は ES ではなく **PCM 変換済み chunk の供給**（`PCMSampleSource.pcmSamples(for:target:)`）。目標仕様は Sendable 値型 `PCMTargetSettings` — `[String: Any]` は actor 境界を跨げない（Swift 6 の検査で判明。dict は actor 内側で組む）。ES をさばく復号器（DTS 等＝OQ-02 ゲート）は同じ出力側（quantum 列 + outputFormat）で入口だけ差し替える。
- **AudioSink / AudioClock は class+NSLock**（契約が同期要件で clock が each tick から同期で読むため。DeterministicTimeSource と同じ前例）。
- **framePosition↔PTS 対応表は AudioSink の内側**（`scheduleBuffer(at: nil)` の順次連結で frame 位置は決定的に追える。decoder が帧数と PTS 進みの対応を保証 — `AudioPathTests` で「帧数と PTS 進みが一致」を固定。04 §5 の設計どおり）。
- **出力装置の遅延**: 本 SDK の AVAudioNode に `outputLatency` は無い。`outputPresentationLatency`（秒）を読み、rendered 位置から引いた地点を `renderedPTS()` とする。妥当性は drift 実測で担保（p95 +10.6 ms、帯域内）。
- **縮退は常に存在する**（INV-2 と同じ原則）: 出力装置の無い環境（CI の macOS ランナーがありうる）では `sink.start()` が throw → `audioStatus="failed:…"` で暫定 pacing（#11 の壁時計基点）に落ちる。e2e テストは running 経路と failed 経路の両方を検査する形にした（silent skip で環境差を隠さない）。映像の完走はどちらでも壊れない。
- **供給方針（初期値）**: prefill 120 ms → start → 稼働中は 150 ms を維持（04 §4 の 0.10〜0.12 s の範囲内）。映像終了後は音声 drain を最大 2 s 待ち、不発なら打ち切って errors に記録（停止しないセッションを作らない安全弁）。
- **drift は audio master clock の実測として帯域内**（p50 +6.9 / p95 +10.6 ms。04 §5 の 8 ms デッドバンド／40 ms 補正段階に対し、Phase 1 は補正行動を実装せず測って残すだけ）。**audio clock 下で `late`(2 ms 閾値) が 144 計上された**: drift が帯域内でも「同期復号が提示パスを阻塞する構造 + clock 锚の量子化 + 補正なし」で late に出る。**修復は Phase 2 の #5/#6（PresentSchedule で復号と提示時刻を分離。8 ms 超だけ補正）**。H.264 の 22/29 と同じ归属。数値は誤誘導なので 04 §9 に含义ごと記録した。
- **DTS の非列挙（A6）はテストで回帰固定**（`AudioPathTests`/`AudioPlaybackTests`: DTS 素材は音声なしで完走する。現れたら OQ-02 の判断を更新する）。
- 新規 API 面の気づき（CLAUDE.md 収集方針）: `CMBlockBufferCreateWithMemoryBlock` は 9 引数（旧 7 引数形は現 SDK に無い）で最終ラベルは `blockBufferOut:`。`CMBlockBufferCopyDataBytes` の destination は **raw memory**（block ではない）。`CMAudioFormatDescriptionCreate` のラベルは `magicCookieSize:/magicCookie:/formatDescriptionOut:`。`CMSampleBufferCreate` は counted-array 形（`sampleCount:/sampleTimingEntryCount:/…`）。PCM の CMSampleBuffer では **sample 数 = frame 数**（EXP-002 の GetNumSamples 実測と一致）。`AVAudioPCMBuffer.mutableAudioBufferList` は non-Optional で `mAudioBuffers` は direct access 不可 — 16bit interleaved なら `int16ChannelData?[0]` が正しい。内部割当の CMBlockBuffer は「empty」状態で `GetDataPointer` に到達できない（自有 memory を渡す）。
- **計測の環境区別（CI 実測で判明・04 §9 に記録）**: GitHub の macOS ランナーでは AVAudioEngine が start するが、音声装置が**実時間ペーシングを持たない仮想装置**で走ることがある（rendered frame 位置が実時間の約 1.09〜1.5 倍で無料実行し、同一コードで drift p95 が 40→92 ms と揺れた）。audio master clock の前提（音声軸≈実時間）は装置の実時間ペーシング依存なので、CI の drift/提示間隔は上限値ではなく**装置の産物**（実機の +10.6 ms とは別物）。**判定は環境の自己申告にしない**: e2e は独立エンジンで rendered の実時間比を測るゲートを持ち、**定常窓 0.98〜1.03 の装置だけ** drift p95 < 40 ms の数値検査を走る（実測: 実機は起動直後窓 0.252 → 定常窓 1.00〜1.013、CI 仮想装置 ≥1.09 で除外。ゲート通過の事実は print で残す）。数値の実盤分布測定は OQ-16 の計画作業に含める。

### 2026-11-16 — 起動 warmup（#12）の実装決定（実測は 04 §9 に記録）

- **OQ-18 決定**: warmup は「`PlaybackSession.prepare()` が load の .preparing 中に先頭 3 帧を復号して**保持**する」。使い捨て復号（案 A）は採らない — 復号済み帧を捨てると同じコストを再生でもう一度払うことになる。**`decoder.reset()` は warmup に使わない**（`VideoToolboxDecoder.reset` は VT session を invalidate するので、预热したのにスパイクを再払うになる）。セッション预热（空 session を作るだけ）も不十分 — スパイクは**最初のフレーム返す復号**に乗る（実測: 1 帧目は delay（F13）で nil を返し 0.5 ms、2 帧目（最初のフレーム）が 50〜69 ms）。
- **音声は prefill のみで start しない**: prefill（120 ms）を prepare で、`sink.start()` を play 初回 tick で行う（開始の瞬間にずらし、停止中の無音供給を作らない）。prepare 失敗（音声 prefill 失敗等）は open を失敗させない — 既存の縮退経路（映像のみ／暫定 pacing）で再生側に表面化する。
- **統計の除外規則（issue #12 の 3 項目目）**: warmup 段の復号は `PlaybackOutcome.warmupStageMS` に分離し、常時統計（`decodeStageMS`）に混ぜない。非再生 probe の decode-all でも**最初のフレーム返す復号**を `firstDecodeMS` に分離して `decodePerFrameMS` から除く（decoder の 1 帧遅延で 1 回目の decode は nil。その nil 応答を「初回复号」扱いしないこと。実装バグとして一度踏んだ）。比較可能性: どちらの値も JSON に載る。テスト `testWarmupPrepareKeepsFullPlaybackAndSeparatesStageStats` / `testWithoutWarmupAllDecodesStayInSteadyStats` の対で「除外」と「非 warmup 時は全 sample が常時統計」の両辺を固定。
- **供給の二重進行防止**: prepare と run は同一セッションを重ねて触る（actor の await で交互実行）。`producing` フラグの闸门で iterator の二重進行を防ぐ。warmup した帧はキューに残っているので、run 側の先読みはキュー上限（4）ぶんだけ進む。
- **数値の再解釈（重要）**: EXP-001 の「初帧 44〜70 ms」は**旧コードの decode-all 経路の max** だった。現在のコード（#4/#11 以降）の decode-all は max 1.45 ms でスパイクが無く、**スパイクは再生線（AVFoundationDemuxer の reader + 同一 session の継続）に現れる**（no-warmup 再生の実測 firstDecode 52〜65 ms、全 11 素材で再現）。G1 の「初回复号は別枠」の前提は生き但つが、内訳が変わった: demux+decode 常時コストは従来どおり軽く、起動コストは warmup で .ready 側に移った。
- **設計値（起動遅延）**: play→初帧提示 **≤ 50 ms**（実測 p95 17 ms に対し安全側の設計値。UI が open 完了を待って play する流れで成立）。load→初帧提示 **≤ 300 ms**（実測 max 188 ms。warmup は load 側に 57〜106 ms を移すだけで open→初帧の合計は変えない — 利得は「play を open から独立にできる」「初帧測定が clean」「stage 統計が常時値で安定」にある）。この 2 つを 04 §9・DEVELOPMENT_PLAN に設計値として記録。
- AC-3 の play→初帧 16.5 ms（映像のみ 1〜4 ms に対し）は sink start + clock 初回 anchor の経直。破綻ではないが startup UX の実装（#2）で詰める（04 §9 に注記）。

### 2026-11-16 — seek（#13・OQ-23）の実装決定（実測は 04 §6・§9 に記録）

- **OQ-23 決定**: seek 再開直後にも 0 長 sample buffer は**出る**（cold read で 180 sample 中 2 件、seek 再開で 96 sample 中 2 件を実測。F5 は seek 経路でも再現する）。demux 縁の間引き（`hasSampleData == false` を PTS 補完に使わず捨てる）は**両経路で必須**。件数は `gatedEmptySampleCount` として demuxer に診断を残す（テストが cold / post-seek の両方を検査）。
- **セッションは生きたまま組み替える**（seek で session・VT decoder を作り直さない）。#12 の warmup 資産を守るためで、実測どおり seek 後の復号は定常値（0.7〜2.6 ms）のまま。decoder の `flush()`（session 維持・`reset()` ではない）で F13 の遅延保持帧を流し切り、`DropReason.seekDiscarded`（新 case）に計上 — seek ごとに 1 帧以上の破棄が必ず出る構造をテストで固定。
- **reader 位置は 1 本という制約**（`AVFoundationDemuxer` は単一の `readingFrom`）: 音声 iterator は生成時に reader 位置を capture するため、**音声の seek（target−0.2 s）と prefill を映像 seek より先に作る**順序が契約になる。逆順にすると音が target から始まる（prefill の 0.2 s が消える）。将来 reader をトラック別に分離するならこの順序制約は外せるが、現状は順序で固定する。
- **供給の中断は正常系**: seek で generation を同期インクリメントし、供給ループは await ごとに照合して旧 reader は黙って終る（degrade・error 扱いしない）。seek 中の `step()` は `seeking` フラグで不許可。
- **sink の flush/restart セマンティクス**: flush は `player.stop()+reset()` で buffer と対応表だけ捨て、**engine は running のまま**（`start()` は `engine.isRunning` を見て player を再開、出力装置の再確保をしない）。#10 の device-missing 縮退とは独立。
- **AVFoundation の seek 着地は実 bitstream より 1 帧手前**（実測: target 3.0 s → 最初の sample PTS 2.502 s、keyframe は 2.535 s）。`SeekEffect.landedAt` は要求位置を返し、実際の着地は sample の PTS で確認する契約のまま（着地位置を設計値にしない）。加えて着地 GOP の 9 sample（I・P・B 混在、すべて target 前）を reader 自体が届けない。**契約は「target 以上の sample はすべて届く」側に置く**（テストで frame 90..179 の完全着達を固定。着地直後の欠番は破棄側の問題として 04 §6 に記録）。
- **実測**: 決定的回帰 = 提示 120 ちょうど（30 + target 以上 90）・seekDiscarded 7（reader が届けた target 前 6 + decoder 保持 1）・seek 後の提示間隔 pts ±2 ms。実時間回帰（AC-3）= seek wall time **91.8 ms**（`PlaybackOutcome.seekMS` に記録）・clock 再 anchor 確認（drift 采样継続）・underrun 0。設計の 0.2〜1.5 s は UI ガイド値のまま（合成 6 s 素材ではその 1/2 以下。実盤長い素材での再測は OQ-16 の実素材で）。

### 2026-11-15〜16 — 運用面の実施決定（実験ゲート外の自己決定）

- **OQ-21**: 合成 fixture は自己生成物（第三者の権利を含まない）として Git に同梱し、`fixtures/manifest.json` に `status: generated` / `kind: generatedFile` + 実測 sha256 + 生成パラメータで登録した。版差で bit 一致は保証しないため **sha は記録であって検査ではない**（`check-fixtures.py` は存在・フィールド構造を検査。再生成は `make gen-fixtures`、既存ファイルはスキップ）。実素材の `pending` 7 件は OQ-16 に紐づいて保留。
- **H.264 fixture の仕様**: yuv420p / High 4:2:0 に変更。High 4:2:2（yuv422p）ではこの機械の VideoToolbox が handler status -8969 で弾いた（開かない素材を待たせるより、通る仕様で固定）。
- **ライセンス棚卸は実測値へ**: libdvdnav 7.0.0・libdvdread 7.1.1・libdvdcss 1.6.0 はいずれも **GPL-2.0-or-later**（過去の MIT 記録は誤り）。Homebrew ffmpeg 9.0.2 は GPL-3.0-or-later。すべて `planned`（未リンク）のまま。CSS/AACS の照会（OQ-03）は未着手。

### 2026-11-16 — プレイヤーシェル（#2）の実装決定（UI 設計そのものは #17 に固定済み）

- **OQ-26 決定（暫定既定・#5 で置換前提）**: Metal 提示（#5）より先に UI シェルが動くため、提示は「engine が present 済み帧を `VideoPresentSink`（async receive）で渡す」契約の間つなぎ。UI 側は AVSampleBufferDisplayLayer に enqueue のみ（スケーリング・deint なし。`enqueue(_:)` は macOS 15 非推奨 — 置換までの許容）。in-flight 上限は 00 §5 と同じ 3。渡せなかった帧は `PlaybackOutcome.displayMissed` に数える（保存則 presented = delivered + displayMissed をテストで固定）。再生は止めない（INV-1）。`AVFoundationAudioSink` の前例どおり MainActor クラスの async メソッドで非 isolated async 要件を満たせる（SDK 実測）。
- **PlayerEngine に setVolume を追加**（#17 に音量スライダーがあるのに 02 §2 のプロトコルに音量が無かった取りこぼし）。値は線形 0.0〜1.0、engine は AudioSink 契約に追加した setVolume で player node のゲインだけ触る（対応表・クロック不変。音声線が無い素材では no-op で UI の状態だけ保つ）。セッション再生成でも値は引き継ぐ。
- **line generation ガード（実測した reentrancy 不具合の修正）**: EngineCore は actor なので seek の await 中に close が割り込める。実測順序: seeking → （close で）empty → seek 復帰で playing → ended と、phase が復活した（アプリ e2e の print デバッグで確定）。close/load で generation を進め、seek は復帰後に線が変わっていれば phase を触らず終る。旧 session の report クロージャも生成時 generation を持つ（#13 のガードの engine 側姉妹）。回帰: `testCloseDuringInFlightSeekLeavesPhaseEmpty`。
- **#17 の有効・無効表からの逸脱（preparing のみ）**: 実測で preparing は load の中に一瞬通り、UI が購読する前に .ready へ進みうる（#12 の warmup を load 内に収める設計のため）。「操作不可」にすると開いている間の transport が死に、着弾後に再度押すはめになる。表を緩め、preparing は play/pause だけ許し seek・step・トラック選択（構造確定が要る操作）は不許可にした。実装は `PlayerViewModel` の computed property で、全 phase の表は `PlayerViewModelTests` に固定。
- **境界検査**: アプリ source は RVMediaCore / RVMediaSources / RVPlaybackEngine のみを import する（INV-8）。`ImportBoundaryAppTests` が機械検査。アプリは単独 SPM パッケージ（App/RetroVisionApp）で、make と CI に build/test を追加（00 §2 の構造どおり。Xcode ワークスペース化と App Sandbox・署名は #16）。
- **比率の暫定実装**: 表示比率は最初の提示帧の `format`（codedSize + aspectSignals）から AspectResolver で解決し、枠の aspectRatio に反映。NTSC 720x480（PAR 10:11）が 4:3 になる回帰を 2 本（単位 + e2e）で固定。信号が無い素材は 1:1 画素比で仮表示し、メニューで明示選択を促す（推測で 4:3 に倒さない = 01 §2 の方針継続）。


## 意思決定の運用

1. 決めたら**この表に「決定」と「日付」「根拠（実験 ID / レポート ID）」を書く**。本文の既定値は同じ commit で更新する。
2. ゲートで決められなかった項目は、次のゲートに持ち越さず、**当面の既定値を製品方針として固定**する（例: OQ-14 は G3 で必ず決める）。
3. ライセンス関連（OQ-02、OQ-03、OQ-15）は実験では決められない。問い合わせて回答が来るまで**対応しないと表明する**側の決定を先に置く。

## 現在、設計を進めるうえで先に埋めるべきもの

- ~~OQ-01、OQ-02~~ → **縮小済み**（2026-11-16、決定ログ参照。残りは DVD 制御の block-reader 実験と Phase 4 の WMV1 ゲート）
- OQ-12（デプロイメントターゲット。API 選択に影響する）
- OQ-07 の前半（モデル変換環境。G3 の評価が始められない）
- OQ-16（実素材フィクスチャ。G2 の判定が実素材なしにはできない）
- OQ-19（音声経路。G1 の受入基準にクロックの実測が必要）
