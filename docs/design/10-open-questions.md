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
| OQ-17 | MP4 mux の MPEG-2 で残る `CVFieldDetail` の読み了と、検出器への供給順位（PCE とどちらを優先するか） | PCE 優先。detail 値は読むだけで使わない | 同一素材の field 声明をコンテナ・bitstream・detail で突き合わせる（`ntsc480i-22-01-in-mp4` fixture。issue #14 の旧名 mp4-01 は存在しない） | G2 | **2026-11-17 実測で解読済み**（container 値は `SpatialFirstLineLate`、PCE の bottom-first と整合。PCE 優先を維持。`DecodePathTests` で固定）。残: temporal 値を持つ素材での検証、ground truth（生成器の tff 意図と実測 bottom-first の食い違い）の確定 |
| OQ-18 | 初回フレームの**再生線での初回复号スパイク**の warmup 設計（open 直後の使い捨てデコード、セッション预热、測定の除外方法） | **実装・実測済み（2026-11-16、#12）**: セッションの `prepare()` が load の .preparing 中に先頭 3 帧を復号して**保持する**（捨てない・`reset()` は呼ばない — reset は VT session を invalid 化してスパイクを再払する）。音声は prefill まで積んで start は play まで遅らせる。統計の除外規則: warmup 分は `warmupStageMS` に分離し常時統計（`decodeStageMS` / `decodePerFrameMS`）に混ぜない（テスト 2 本で両辺を固定） | 実測（04 §9）: 初回复号スパイク 50.5〜68.9 ms（合成 11 素材・再生線）。warmup で play→初帧提示は 59〜69 ms → 1.1〜3.6 ms（AC-3 で 16.5 ms）。**EXP-001 の 44〜70 ms は旧コードの decode-all に現れたもので、現在のコードの decode-all は max 1.45 ms（スパイク無し）— スパイクは再生線固有**。マルチストリーム切替時の再 warmup 要否は Phase 2（トラック切替の実装時に同じ prepare を使う） | G2 | 完了 |
| OQ-19 | 音声復号とクロックの実現（AC-3 を AVFoundation の PCM outputSettings で復号できるか。AudioClock の jitter） | **実装・実測済み（2026-11-16、#10）**: AVAssetReader の linear PCM 出力で AC-3 を復号する（依存ゼロ維持）。quantum 分割は AudioDecoder 実装側（A2、`AVFoundationAudioDecoder.quanta` で 480 帧へ。テスト固定）。クロックの原料は PCM 経路の valid PTS + 帧数（A3）。`AVFoundationAudioSink` + `AudioClock` を実装し、in-loop の drift を実測（04 §9: p50 +6.9 / p95 +10.6 ms、デッドバンド帯域内）。**DTS は AVFoundation がトラックを列挙しない（A6）ため Phase 4 の shim ゲートまで非対応**（`AudioPathTests` で回帰固定） | 5.1 配置・実素材の jitter 分布は実盤で再測（OQ-16）。実測（realtimeFactor ≈1100、合成素材での clock jitter は上にとどまる） | G1（clock 部分） | 完了（実盤計測は OQ-16 に引き継ぎ） |
| OQ-20 | SW 復号フォールバック（`SoftwareDecoder`）の実現方式（VideoToolbox が弾く pixfmt・codec — WMV1 等） | libavcodec shim。ただし**実際に対象素材が現れるまで作らない**（無依存方針を壊さない） | WMV1 fixture が AVFoundation で開けるかの測定（未実施） | Phase 4 | 対象が判明した時点 |
| OQ-21 | 合成 fixture の再生成一致性（ffmpeg の版で bit が変わりうる。sha を検証にするか記録にするか） | **決定済み（下記決定ログ）**: `status: generated` で Git 同梱。sha は記録（検査しない） | CI の ffmpeg バージョン漂移の実測 | — | 決定 |
| OQ-22 | 60i 素材のキャデンス（film-origin pull-down）対応の範囲と ground truth | 未対応（現セットに flag 付き pull-down 素材がない） | 市販 DVD 映画素材の flags と検出器の突合 | G2 | Phase 2 |
| OQ-23 | seek 再開直後にも zero-sample buffer（`hasSampleData == false`）が現れるか（F5 の再発条件） | **決定済み（下記決定ログ・#13）**: 出る。cold read でも seek 再開直後でも 0 長 sample が現れることを実測で確認（各 2 件）。demux 縁の間引きは両経路で必須。`gatedEmptySampleCount` で診断を残す | 実測（04 §6・§9）: cold 180 sample 中 2 件 / seek(3.0s) 後 96 sample 中 2 件。decode 段に届いた件数は 0（-12902 ゼロ） | G1 | 完了 |
| OQ-24 | ビルド成果物の署名方針（unsigned の SPM debug binary が一部環境で SIGKILL=exit 137。CI と配布の関係） | ビルド後 ad-hoc 署名（`codesign --force --sign -`）。Makefile/CI で実施 | 配布形態の要件（hardened runtime・entitlements） | G4 | Phase 4 |
| OQ-25 | H.264 interlaced 素材の field 順序の情報源（F11 で全て消える）— detector の検証素材をどう用意するか | H.264 は detector 経路で受け入れる。順序の ground truth は生成時情報で持つ | h264 fixture での検出精度比較（生成時に正解既知） | G2 | Phase 2 |
| OQ-26 | #5（Metal 提示）が載るまでの映像提示の形（#2 が先、#5 が後の順序に対する間つなぎ） | **暫定既定で実装済み（下記決定ログ #14）**: engine は present 済み帧を `VideoPresentSink` で UI に渡す（in-flight 3、超過は `displayMissed` に計上）。UI 側は AVSampleBufferDisplayLayer に enqueue のみ。比率は帧の format から AspectResolver で解決 | 実装・回帰固定（PresentHandoffTests の保存則 / SurfaceAspectTests の 4:3 / アプリ e2e）。**2026-11-17: #5 A1a で Metal 提示（既定）に置換済み**。暫定経路は `RV_LEGACY_PRESENT=1` のフォールバックとして残す | G2 | 完了（Metal 既定。フォールバックは実画面での Metal 検証が済むまで残す） |

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
- **position イベントの非逆行契約（CI で実測した逆行の修正。02 §4 に契約を追記）**: `AudioPlaybackTests` の seek 位置単調増加検査が GitHub runner で落ちた（target 3.0 s の後に 1.6 s 台の位置が後出し: `position 7 が PTS 順でない`）。原因は actor の await で位置報告の Task が後回しになること（local では再現せず、CI の低速 runner で顕在化）。session の seek 世代を `Event.position` に載せ、engine の受け口で ①seeking 中は黙る ②旧世代を捨てる ③受理位置以下を捨てる の三重に濾過（既存の line/seek generation と同系譜）。テストの断言はそのまま契約の検査として CI で固定。教訓: **時刻・position の不変条件は出力点で決定的に守る**（timing で偶然通る状態を放置しない）。
- **#17 の有効・無効表からの逸脱（preparing のみ）**: 実測で preparing は load の中に一瞬通り、UI が購読する前に .ready へ進みうる（#12 の warmup を load 内に収める設計のため）。「操作不可」にすると開いている間の transport が死に、着弾後に再度押すはめになる。表を緩め、preparing は play/pause だけ許し seek・step・トラック選択（構造確定が要る操作）は不許可にした。実装は `PlayerViewModel` の computed property で、全 phase の表は `PlayerViewModelTests` に固定。
- **境界検査**: アプリ source は RVMediaCore / RVMediaSources / RVPlaybackEngine のみを import する（INV-8）。`ImportBoundaryAppTests` が機械検査。アプリは単独 SPM パッケージ（App/RetroVisionApp）で、make と CI に build/test を追加（00 §2 の構造どおり。Xcode ワークスペース化と App Sandbox・署名は #16）。
- **比率の暫定実装**: 表示比率は最初の提示帧の `format`（codedSize + aspectSignals）から AspectResolver で解決し、枠の aspectRatio に反映。NTSC 720x480（PAR 10:11）が 4:3 になる回帰を 2 本（単位 + e2e）で固定。信号が無い素材は 1:1 画素比で仮表示し、メニューで明示選択を促す（推測で 4:3 に倒さない = 01 §2 の方針継続）。

### 2026-11-16 — DVD/ISO source（#3 v1 増分）の実装決定（実測は 03 §9 に反映）

- **AVFoundation の MPEG-PS タイムラインは「ファイル単位 0 起点正規化」だと確定**（実測: 生素材の先頭 PTS 2.535 s → track timeRange.start = 0、先頭 sample PTS = 0.0）。多重 VOB の連結は「素の PTS の縫合」では成立しない（part2 が 0 台から始まり衝突する）。
- **AVMutableComposition による連結は不採用**（設計候補を実測で否定）: composition はタイムライン構造（track timeRange）だけ合成し、**PS 由来の圧縮 sample の時刻を書き換えない**（part2 の sample がファイル単位の素の時戳のまま届く。track 終端 3.04 s の直後に 0.47〜0.53 s 台の sample が並ぶ実測で確定。`datacount` probe: 174 buffer / 有効 166、tail は素の 2.90 のまま）。`CMSampleBufferCreateCopyWithNewTiming` の自前 surgery を避けるため、**バイト連結 + 実証済み単一ファイル経路**へ切り替えた。DVD 仕様は「タイトル VOB の連結は 1 本の連続 MPEG-PS」を保証するため正当（VOB は容器のスライス）。fixture の `cat` が母素材とバイト一致であることも実測で確認（検査の根拠に使う）。
- **連結後の契約は「単一ファイルとして読んだ列と一致」**（`ConcatPSDemuxerTests` が逐語一致で固定。engine e2e でも母素材と同じ demux 180 / 提示 180・境界跨ぎの位置連続を実測）。sample 列は MPEG の復号順（IPPP/IBBP の 3 周期 PTS 列）で presentation 順ではない — 単調化は engine の位置契約（02 §4 床ガード）の仕事、と demux 段の境界を明確化（#13 の seek 着地実測の続測）。
- **title 列挙は VIDEO_TS ファイル名走査（v1）**。IFO 実パースは増分として保留（OQ-01 の libdvdread 設計はそのまま）。IFO 欠落・0 バイト IFO は `unreadableIFO`、part 飛び・先頭 part 欠落は `missingVOB` を structure.warnings に列挙（#3 受入基準の第一条項をテストで固定）。`VTS_nn_0.VOB`（menu）は列から除く（実 DVD 配置対策）。
- **ISO はマウント経路に決めた**（実測で三つの事実）: (1) AVFoundation は ISO を直接 demux できない（-11828。#3 事前ゲートの続測）、(2) ブロック供給の無名経路は `loadTracks` が解決せず 30 s 超ハング（無名供給 → AVFoundation の道は separate gate の実験として OQ-01 の証拠に記録）、(3) `diskutil image --plist attach` の plist（`system-entities[].mount-point` / `dev-entry`）は決定的に読める。解除は `diskutil eject`（`diskutil image` に eject/detach は無い）+ AVFoundation の開いた取扱いが残っていると素の eject は失敗（"at least one volume could not be unmounted"）→ **demuxer を降ろしてから eject、失敗時 force** の順で固定（テスト後の /Volumes 残留 0 を検査）。CLI 選択: hdiutil は deprecated 警告のため diskutil（Makefile・コードとも）。
- **Engine 配線口の一般化**: `FileMediaSource` 特例だった wirePipeline を `DemuxerProviding`（`makeDemuxer(itemId:)`）へ一般化（03 §9.5）。item 単位 demuxer（VTS ごと）+ 単一实例の約束（track id 対応）は継続。selected item が structure に無ければ先頭（title 切り替え UI は未実装のまま）。
- **一つの入口**: `MediaSourceRouting`（directory→VideoTs / disk-image UTI→DiscImage / その他→File）。App の NSOpenPanel は canChooseDirectories=true（ボリュームルート/VIDEO_TS 直下の両対応で開く）。FileMediaSource の disk-image 事前ゲートは安全網として維持。
- **fixture**: `Scripts/gen-dvd-fixture.sh`（母素材 ntsc480i-ac3-01.mpg を pack 境界・セクタ境界で 2 分割 → VTS_01_1/2.VOB + 単一 VTS_02 + 0 バイト IFO/BUP + `hdiutil makehybrid` ISO）。`make gen-fixtures` の末尾に接続。マニフェストには derived fixture として**母素材の sha256 を記録**（ISO/VOB の再生成は非決定的。内容の integrity は母素材側で担保 — OQ-21 の約束の延伸）。`hdiutil makehybrid -quiet` は失敗理由を隠して exit 1（実測。付けない）。
- 新規 API 面の気づき（CLAUDE.md 収集方針）: `diskutil image attach` の stdout はタブ区切り（テキスト解析はもたない。`--plist` は `diskutil image --plist <subcommand>` の位置で効く）。`FileHandle` の Swift イニシャライザは現 SDK で `init(forReadingFrom:)/init(forWritingTo:)`（`forReadingAt:` は無い）。AVAssetReader の `timeRange` は sample pts の逐語比較で選ぶ（seek 着地に境界 marker が 1 本混ざる意味論は #13 と同一）。AVMutableComposition の track `timeRange.duration` は符号順末尾の無データ marker を含む（挿入範囲を実測終端で切る設計は不採用＝連結方式の変更で消滅）。

### 2026-11-17 — タイトル切り替え（#3 追加分）の実装決定（実測は 03 §9.6 に反映）

- **実運用で境界が顕在化した**: ユーザーの実 DVD ISO がアプリで開けて再生できたが「おそらく最初のチャプターのみ」と報告された。v1 の設計境界（全タイトルを列挙するが engine は ItemID(1) を選ぶだけ・切り替え UI 未実装）そのもの。優先度を上げる実測として受け、同日増分化した。
- **切り替えの意味論は「同じ source の再 load」**: `EngineCore.select(item:)` は lineGeneration を進め、旧 session を stop し、新しい item へ配線し直して warmup → `.preparing → .ready`。position は 0（`positionUpdated(.zero)` が単一の初期化経路）。再生の自動継続はせず停止で止まる（v1。autoplay 継続は増分として保留）。
- **items.first 固定を selectedItem() に置換**（実測された不具合の修正）: snapshot の duration / available、seek と position の duration イベント、rebuildPlan、tracksChanged が選択 item に従うようになった。「2 本目に切り替えても UI の duration が 1 本目のまま」という実測が根拠。
- **source の open は冪等**: VideoTsMediaSource は構造/demuxer、DiscImageMediaSource はマウントを cache。理由の実測: 再 open での再 probe は多重 VOB の再連結コピー（GB 級）をやり直す。attached の ISO を再度 `diskutil image attach` すると「〜 1」付きの別マウントが増える。demuxer の同一实例契約（track id 対応）は open をまたいても保つことを検査で固定。
- **load が旧 session を止める**（潜在バグの修正）: 以前は 2 回目の load で旧 session が止められていなかった（ファイルを連続で開いても同じ）。
- **選択も events 由来**: load で `selectionChanged` を送る（タイトルメニューの現在選択が単一経路で更新される）。FakePlayerEngine は実 engine と同じ順序（structureChanged → tracksChanged → selectionChanged → positionUpdated(.zero) → ready）で流す。
- **fixture を判别可能にした**: VTS_02_1.VOB を別素材（truncated-01.mpg 複製・4.04 s）に変更。単一 MPEG の機械スライスだと 2 タイトルの sample 数が近く、e2e が切り替えを数値で区別できなかった（設計上の落ち度。実測で発覚）。実測値: VTS_02 raw total=122 / valid=120 / lastPTS 3.971 s、engine 経由 demux 120 / 提示 120（0 長 marker 2 件は demux 縁の間引き = OQ-23 と同一の意味論）。タイトル 1 の 180 と明確に区別でき、`testTitleSwitchPlaysSecondTitle` が 120/120 で兼実測固定。
- **UI**: transport バーに「映像タイトル」メニュー（multi-item 構造のときだけ表示）。選択は engine に `select(item:)` を投げるだけで、表示は events からのみ更新される（#17 の単一経路原則）。単一項目 source ではメニューが出ないことを fake 検査で固定。

### 2026-11-17 — transport バー再表示の入力源（#22）の実装決定

- **実測**: ユーザー実機で ISO 再生中、バーは自動非表示で消えた後、**マウスを動かしても一切戻らない**。ウィンドウ検査（CGWindowList で `RetroVision AI` 1541×847 の再生ウィンドウを特定）とスクリーンショットで「映像は表示、bar は無し」を裏取りした。
- **原因**: #17 方針1 の再表示入力が `.onContinuousHover`（ZStack 側）だけだった。映像面 `VideoLayerView`（layer-backed NSView の `NSViewRepresentable`）が再生中は画面を覆い、AppKit は `mouseMoved` を deepest hit-test 側へ送るため SwiftUI の hover tracking に届かない。一度 auto-hide したら戻る経路が無い。
- **決定（意味論は変えない）**: 入力源に AppKit の `NSEvent` **local monitor** を追加（`ControlsActivityMonitor`）。sendEvent の分发前に割込むため view 階層に依存しない。拾う範囲は mouse-moved / click / scroll（キーは含めない — shortcut は bar の可視に依存しない）。`onContinuousHover` は併存（bar 自身の上では SwiftUI 側も効く。二重発火は `showControls()` の冪等性で無害）。イベントは return して吞まない（timeline ドラッグ等のバー操作を壊さない）。再生画面の onAppear で start / onDisappear で stop。
- **検査で固定した回路**: local monitor は `NSApp.sendEvent` で発火する（headless で検証可能）、目撃 monitor を先に登録して「吞まない」を検証、start 冪等・stop で解除、keyDown は活動に含めない。
- API 面の気づき（CLAUDE.md 収集方針）: `NSEvent.addLocalMonitorForEvents` の handler は **新しい登録順に呼ばれ**、nil を返すと event を吞む。`NSEvent.otherEvent(with:)` は mouseMoved を作れない（例外 `WeirdMask`）。合成 mouseMoved は `CGEvent(mouseEventSource:mouseType:mouseCursorPosition:mouseButton:)` → `NSEvent(cgEvent:)` で作れる（type は保持され sendEvent に通る）。`NSApp.sendEvent` を通す局所検証には `NSApplication.shared` の生成だけで足り、run loop は不要（handler は同期呼出しだが検査は RunLoop drain で待って確定させる）。`onContinuousHover` は `NSViewRepresentable` の layer-backed view 上で発火しない（実運用実測。pure SwiftUI 領域では効く）。

### 2026-11-17 — #22 二次原因（mouse-moved の生成自体）と .ended 運送の実装決定

- #23 の local monitor 後もユーザー実測で「マウスを動かしてもバーは出ない」が続いた。**一段深い原因**: `NSWindow.acceptsMouseMovedEvents` の既定は false で、既定のままでは mouseMoved NSEvent が**生成されない**。local monitor は sendEvent の分发前に割込むだけなので、そもそも列に来ないイベントを観測できない。前増分の unit test は `NSApp.sendEvent` 直接投递で生成段を通過していた（test の穴として実測に負けた）。
- 決定（入力鎖の完成）: ① 映像面 `VideoLayerView` が載る window で `acceptsMouseMovedEvents = true`（viewDidMoveToWindow + layout で再宣言 — fullscreen 経路の保险）。② 生成された mouse-moved の owner 配送受け口として `VideoLayerView.mouseMoved(with:)` → `onControlsActivity`（representable 経由で PlayerScreenView の `showControls()` に接続）。local monitor とは独立の配送で、二重に届いても showControls は冪等。③ `onContinuousHover` と monitor は維持（ SwiftUI 側領域と click/scroll を拾う）。
- **.ended からの運送（同実測で判明した操作不能バグ）**: PICHI 実 ISO でタイトル終了後、`play` も `seek` も guard に弾かれて何も押せない状態になっていた（UI の position だけ scrub で 0 に動き engine と乖離）。決定: `ended` からの `play` = 古い線を stop → `seek(.zero)` で線を作り直し最初から再生。`ended` からの `seek` = 指定位置で `paused` に落ち着く（自動再生しない）。境界として、seek した 0 と PTS=0 初帧の**二重 0** が position の strictly increasing contract（02 §4・#14）と衝突するため、engine の position 配送は「published 済みと同じ值是黙る」に厳格化（0 地点の初期化イベントは seek/load 側の単一経路が既に送っている）。
- 検査: window フラグの生成（既定 false → 映像面載せで true、layout 再宣言）、owner 配送 callback、実線 fixture で「終了→再生し直し→全帧提示・position は 0 再出発から strict 増・2 度目の .ended」の e2e。
- API 気づき: `NSResponder` の Swift 名は `mouseMoved(with:)`。NSWindow の `acceptsMouseMovedEvents` は既定 false（tracking area の無い plain NSView 上のホバーで mouse-moved が生成されない理由）。`NSWindow(contentRect:styleMask:backing:defer:)` は test で使え、`contentView=` 代入で viewDidMoveToWindow が走る（headless で生成契約を検証できた）。
- 実機 e2e 検証（統合前・分支ビルドを実行し CGEvent/HID 合成入力で測定済み）: 再生→活動→2.5 s でバー自動非表示→pure mouseMoved sweep で再表示（画面検査 + monitor 発火の実測 count）。切り分けのために `RV_DEBUG_ACTIVITY=1` のオプトイン stderr 診断を残す（既定は沈黙。「アプリはログを書かない」方針は不変。binary を直接起動して stderr を取れる形でのみ観測可能）。


### 2026-11-17 — 多重 VOB: バイト連結から無連結 segment demux + PTS 再開始修復へ差し替え（#3）

- **実測（PICHI 実 ISO、issue #3）**: 4 連結の duration 76.064 s 崩壊 / part 4 単体 92,865 s 誤読・reader 92 sample 停止。VTS_01 parts 1〜4 の PES PTS は raw 連続（0.189→2935.455 s）なのに part 4 のバイト 338,876,430 で 0.189→75.965 s（≈ −2,935 s）へ戻る。**pack SCR はこの点を跨いでも連続**（338.6〜339.0 MB 窓に負のジャンプ無し実測）= part 内部のプログラム再開始が根本原因で、連結の器は壊れていない。
- **決定（設計差し替え）**: ConcatPSDemuxer 退場。`SegmentPSDemuxer`（part 単位の `AVFoundationDemuxer` + duration 累積オフセット + `CMSampleBufferCreateCopyWithNewTiming` の時刻 surgery を demux 内侧に閉じ込める）へ全チェーン（単一 part 含む）を流す。sample 時戳 surgery を「避ける」とした旧方針は「連結が壊れる以上 surgery を避けられる経路が無い」で転換。engine・session の契約（04 §2 の単一 sample 列）は不変。
- **決定（修復の形）**: `ProgramStreamRepair` が PS を start code で歩き、PES PTS の逆行 ≥ 2.0 s（`programBreakSeconds`）だけを検出して以降を 5-byte タイムスタンプフィールド単位で `lastSeen` 直後へ平行移動する写しを tempfile に作る（発火はスキャン検出のみ、heuristics 無し。clean part は写しを作らない — PICHI parts 1〜3 で plan ゼロ実測）。SCR は読まない（FFmpeg の PS demuxer も pack header を読む設計ではない — libavformat/mpeg.c 確認）。警告 code `.ptsRestartRepaired` を structure に載せる。
- **実測（修復妥当性の実証）**: canonical layout（`lead P[32:30] '1' P[29:15] '1' P[14:0] '1'`、P[29:15] は bit31..17）の PES のみ修復で part 4 相当を全文字読み: duration 357.184 s / reader 完走 10,699 sample（未修復 92）。実 PICHI フィールド 0x31000184eb = 0.18903 s の delta 0 round-trip 恒等で符号化を確定。PES ヘッダは PES-2（'10xx' marker）と PES-1 旧形（'001x' 直後形。ffmpeg fixture。ffprobe pts/dts とバイト一致）の 2 形両対応（FFmpeg と同じ判別 `(c & 0xE0) == 0x20`）。*初期 2 実装（Python 実証・Swift 初版）は marker bit を 1 本誤読し、当時の実測数値（319.266 s 等）は取り消し。round-trip 検査に差し替え。
- **既知のトレードオフ（受容して進む。cell 時刻縫合は別増分）**: 累積 duration オフセットは母素材タイムラインより fixture +0.123 s 大きい（境界 interleave 二重計上。実写の 0.5 s 級 gap で有界）。合成 mpeg2 fixture は open GOP で境界 4 帧喪失（176/180 実測。fixture は ffprobe keyframe 位置へ切るのは 15 帧喪失を避けるため。実 DVD closed-GOP cell では喪失 0 = PICHI で part 全文字通し実測）。
- **検査**: `SegmentPSDemuxerTests`（9 検査。構造一致・frame 集合契約（喪失 ≤ 4・幽霊 0・drift < 0.25）・修復算術の厳密値・実バイト canonical round-trip・PICHI part 1 clean・2 連結形の限界記録）。engine e2e 更新: VTS_01 の demux/提示 180 → 176（実測追記）。`make check` 緑（2026-11-17）。

### 2026-11-17 — menu（VMGM）列挙と first-play 政策（ユーザー実測要望「メニュー画面も出るように」）

- **決定（列の約束）**: `VideoTsChain.isMenu` を追加。`VIDEO_TS.VOB` を `vtsNumber 0`・`isMenu true` のチェーンとして chains 先頭に置く。`VideoTsMediaSource` は `MediaItem(id: ItemID(0), titleNumber: 0)` を同じ経路で作り、UI は titleNumber 0 を「メニュー」と表示（model 変更なし。0 は menu 予約値）。VTS_nn_0.VOB（VTS メニュー）は対象外継続。多重 part VMGM 未対応（観測例なし。OQ 扱いで形式外 name warning に残す）。
- **決定（選択の構造駆動化）**: `PlayerEngine.load(_:selection:)` の selection を `PlaybackSelection?` に（nil = open 後 structure 先頭 item で engine が解決し selectionChanged を単一経路で流す。tracksChanged より先）。menu の有无に関わらず「Disc を開くと盤が選ぶ順序で始まる」を engine 側ではなく**構造の順序**で表現する。明示指定の既存呼び出しは不変。
- **決定（first-play 政策は PlayerViewModel。engine に意味を渡さない）**: 構造に titleNumber 0 が在るときだけ自动再生（実機の盤挿入=再生開始）。無い素材は #17 user gate 不変。menu `.ended` → ~~最初の本体タイトルへ自動進行~~ **2026-11-17 改訂: menu を `play()` で再生し直して繰り返す**（本体へはタイトル一覧から。尺不明・1 秒未満の menu は終端で停止。phaseChanged(.ended) からのみ発火、`menuLoopPending` ガード、`.playing` で解除）。
- **検査**: navigator（menu 先頭/無し/nn_0 除外）、engine e2e（items [0,1,2]・menu 完走 120/ended）、PlayerViewModelTests（auto-select+auto-play、自動進行 1 回だけ、menu 無しで自动再生しない）。Interactive menu（VMGM PGCI の PU 命令）は未実装 — メニューは video として线性再生するだけ（IFO パース増分とセットの次項。03 §9.7 限界メモ）。

### 2026-11-17 — 起動時 QA 入口: RV_AUTO_OPEN / RV_DEBUG_POSITION（opt-in env）

- **動機（実測環境の制約）**: 実盤 live 検証をしようとした夜、Mac はロック画面（要パスワード）で GUI 自動化が不能。RV_DEBUG_PSREPAIR / RV_DEBUG_ACTIVITY と同じ opt-in env 约定で、画面を出せない環境からも運送の数値を確認できる入口を作る。
- **RV_AUTO_OPEN=<path>**: `RetroVisionAppBody.init` で `PlayerViewModel.autoOpenFromLaunchEnvironment()` を呼ぶ。設定時だけ起動時にその URL を open する（未設定では何もしない = 既定起動の不変。first-play 政策などの意味は通常の open と共有 — 政策の重複実装を作らない）。**実測で配線を差し替え**: 当初 RootView.onAppear に置いたが、画面ロック中の起動では onAppear 自体が発火しない（RV_DEBUG_ACTIVITY の monitor 登録ログが一行も出ず、窓だけ存在した実測）。init は画面状態に依存しない。
- **RV_DEBUG_POSITION=<any>**: PlayerViewModel の events 経路にだけ乗る stderr 診断（`rvtransport:` 行）。phase / selection は毎回、position は 1 s 粒度（フレーム毎で埋めない）。UI 側ミラーの単一更新経路（#17）の観測を写すだけで、engine の契約は変えない。
- **検査**: auto-open の発火・未設定 noop（既定起動の意味不変）、QA 入口が first-play 政策（menu 既定選択）を通ること。実盤 live 計測はこの夜は画面ロックのため GUI 側は未実施（朝の解錠待ち）。エンジン側の実盤計測は device-gated 検査と RV_AUTO_OPEN 実行の组合せで実施。

### 2026-11-17 — MediaSource.close（明示的资源解除）とアプリ終了後始末（#3、live 実測起因）

- **実測（live 検証の終了後）**: 実 PICHI ISO を再生したアプリを SIGTERM で終らせたとき、(a) ISO マウント（diskimagesiod が残り /Volumes に居続けた）と (b) 修復写し temp `retrovision-psfix-*.mpg` 430,792,704 B が temporaryDirectory に残った。engine.close は openedSource を nil にするだけで、source 側の後始末（unmount・temp 掃除）は process 終末の deinit / Task.detached 任せになっていた — 終末では間に合わない。
- **決定（契約）**: `MediaSource` に `close() async` を追加（資源を持たない source は protocol extension の no-op 既定）。`EngineCore.close()` は session を止めた**後**に currentSource.close() を await して手放す（reader が動いたままの eject は壊れる — 順を厳守）。DiscImageMediaSource.close（既存）= internal source の demuxer 解放 + eject。VideoTsMediaSource.close を追加 = opened cache 破棄 + releaseDemuxers（SegmentPSDemuxer の temp は deinit で掃除される — 参照をここでまとめて手放す）。タイトル切り替えの再 load は close を通らない（冪等 cache は不変。03 §9.6）。
- **決定（アプリ側の終了経路）**: `applicationShouldTerminate` → `closeEngineForQuit()`（async）を走らせてから `reply(toApplicationShouldTerminate:)`。保留中の待ち時間は watchdog（3 s、超過時 rvquit 一行で進行）。**nested run loop で待たせる案は実測で退場**: 素の CFRunLoop を回しても main actor のジョブは流れず（XCTest で 3 s 待っても engine.close が完了しなかった）、同期待ちのつもりが事実上 complete しない。terminateLater で AppKit の通常ループに戻すのが正しい。
- **検査**: EngineCoreTests（engine.close → source.close が 1 回だけ伝播、2 回目の engine.close は no-op）、PlayerViewModelTests（closeEngineForQuit が engine.close 完了 + events 経由の空状態）。live（実 PICHI ISO）: 再生中のアプリを TERM で終了 → マウント解除と temp 削除を確認（この項の実測は PR 記載）。docs 03 §1 に契約、§9.6 に close と冪等 cache の関係を追記。

### 2026-11-17 — Demuxer.close（続報）: temp 掃除は deinit の時点に任せられない（#3、live 実測）

- **実測**: PR #28 の terminateLater 経路でアプリを終了すると unmount は走ったが、修復写し temp は残った。close→reply→process exit の順では actor（SegmentPSDemuxer）の非同期 deinit / process 終末の deinit が走る前に終る — deinit は「open 経路中断の保険」であって契約にできない。
- **決定（契約の対）**: `Demuxer.close() async` を追加（資源を持たない demux は no-op 既定）。SegmentPSDemuxer.close は修復写しを**同期的**に削除 + parts/mergedInfo の cache を落とす（close 後の再 probe は ensureParts で作り直し — 検査で成立固定）。VideoTsMediaSource.close と DiscImageMediaSource.close は demuxer の close を await してから手放す。
- **検査**: SegmentPSDemuxerTests §8（close で temp が消える・close 後の再 probe が壊れない・2 回目の close で残らない）。

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

### 2026-11-17 — #5 A1a: Metal 提示を実再生経路へ接続（OQ-26 の置換）

- **決定（契約）**: engine の出口を `VideoFramePresenter.present(_:plan:) -> FrameDeliveryOutcome`（`.delivered` / `.dropped`）にした。提示時刻の権威は engine（音声 clock）のまま。`PlaybackSession.deliverToSurface` は detached Task で presenter を呼び（再生・音声を止めない — INV-1）、in-flight 上限 3 と lease は従来どおり。presenter が `.dropped` を返したら `displayMissed` に数える（保存則 presented = delivered + displayMissed を維持。`PresentHandoffTests` に presenter drop の検査を追加）。
- **決定（互換）**: 既存の `VideoPresentSink` は `LegacySinkPresenter`（常に delivered）で包み、`setVideoSink` は無変更。UI は `RV_LEGACY_PRESENT=1`（または Metal デバイス無し）で暫定経路を使える。
- **決定（時間軸）**: `MetalPresenter.timing = .immediate`（呼ばれた時点の次の vsync）。presenter 自前の anchor（`.anchoredGrid`）は audio clock と別の時間軸になり、seek で PTS が飛ぶと予約が未来へずれるため engine 経路では使わない。`.anchoredGrid` は残す（`PresentScheduleTests` は不変）。復号 buffer は presented handler まで保持（GPU が読み終えるまで生かす）。
- **決定（plan）**: EngineCore が昇格済み plan（`activePlan`）を session へ渡す（`play()` の昇格時と session 生成時）。presenter は plan を読むだけ。
- **決定（UI 境界）**: App は `CAMetalLayer` を `DefaultPlayerEngine.attachMetalSurface(layer:onAspectResolved:)` へ渡すだけで、RVVideoPipeline を import しない（INV-8。`ImportBoundaryAppTests` 不変）。drawableSize は view が実ピクセル寸法に保ち、変更時に `redrawMetalSurface()` で最後の frame を描き直す。表示比率は plan の `aspect.targetDAR` から通知する（view の枠が DAR、graph の letterbox は同じ DAR なので二重補正にならない）。
- **実測（2026-11-17、`dvd-video-ts-01` の menu を実アプリ窓で撮影し暫定経路と比較）**: 向き・色の並び・4:3 枠は暫定経路と一致。Metal 側は cleanAperture（704/720）を反映してカラーバーが約 2% 横に広がる（05 §6 の設計どおり。暫定経路は無視）。
- **既知の差（次の増分）**: インターレース素材の静止した細部（焼き込み timecode）が、`.auto` → edgeDirected の縮退で崩れて見える（暫定経路は weave のままで鮮明）。detector と motionAdaptive（A1b）で解消する。present 間隔・GPU 時間の実測（G2）は未実施で、実素材（#15）も要る。

### 2026-11-17 — #5 A1b: motion-adaptive デインターレース（前 frame 入力）

- **決定**: `DeinterlaceMode.auto` / `.motionAdaptive` は、前 frame があれば `rv_deint_motionAdaptive_v1`、無ければ（先頭 frame・寸法変更直後）従来の edge-directed に倒す。`RenderFrameInput.previousPixelBuffer` を追加（同寸法・NV12 のときだけ取り込む）。`MetalFramePresenter` が直前に渡した frame の pixel buffer を保持して渡す。seek 直後は前 frame が無関係でも、その 1 frame は動き側（空間内挿）に倒れるだけで破綻しない。
- **アルゴリズム**: 偶数行は保持。奇数行は「前 frame との同位置差」（補間行と上下の保持行の 3 点の最大。同 parity 同士）から `smoothstep(0.03, 0.10, motion)` で weave と空間内挿を混ぜる。静止部は垂直解像度を保ち、動き部は comb を出さない。chroma は源のまま（従来どおり）。
- **実測（実アプリ窓、`dvd-video-ts-01` の menu）**: edge-directed 固定では焼き込み timecode の静止桁が崩れていたが、motion-adaptive では静止桁が鮮明になり、毎 frame 変わる桁だけが空間内挿になる（想定どおり）。
- **未実装（A1b の残り）**: detector（FieldMatch / CadenceAnalyzer と判定根拠の記録）、inverseTelecine（24p 化）、`ScaleFilter.highQuality` の kernel、OQ-10（表示同期方式）。G2 判定（combing の客観検査・GPU 時間）は実素材（#15）が要るため未実施。

### 2026-11-17 — #9 A4: 適応制御ループの配線（監査で未接続を確認 → 接続）

- **監査（実コード確認）**: `AdaptivePolicyEngine.evaluate` はテストからしか呼ばれず、`EngineCore.applyControlActions` の呼び出し元も無く、`AdaptiveController`（actor）は生成されていなかった。実再生では信号が作られず、制御は一度も動いていなかった。
- **決定**: `EngineCore` が位置イベント（提示のたび）を契機に、窓（`controller.config.windowMS` = 2 s）が満ちたときだけ評価する。専用タイマーは持たない。窓の `FrameStats` は session の累積 stats の差分（`windowedStats`。session 再生成で累積が戻っても負にせず 0 に丸め、新 session では窓を取り直す）。thermal は `ProcessInfo.thermalState` を写像。窓が満ちるまで session に触れない（提示のたびの呼び出しを安く保つ）。evaluate の action は `applyControlActions` へ。
- **未接続の信号（既定値のまま）**: memory pressure（normal）、modelBreakerOpen（false。A2 の runtime と `ModelHealthTracker` が載るまで）、presentJitterMS（0。`MetalPresenter.onPresented` の集計が載るまで）、endToEnd の p95（0）。このため現状 AI 段が無い構成では tier は metalOnly のままで、action は実質発火しない。ベンチマークレポート・品質インジケータ UI・負荷注入テストも未実装。

### 2026-11-17 — #5 A1c: highQuality スケール（bicubic。拡大時のみ）

- **決定**: `ScaleFilter.highQuality`（plan の既定）は、**拡大時**（出力側の画素数 > 取り込み域 × 1.01）だけ `rv_colorConvert_bicubic_v1`（輝度 4x4 tap の Catmull-Rom、overshoot は clamp(0,1)）を使い、縮小・等倍は従来の linear。chroma は 4:2:0 で元々低解像なので linear のまま。bicubic は縮小時に折り返しを強めるため使わない。
- **検査**: 16→64 の階段エッジで遷移幅が bilinear より狭いこと、16→8 の縮小では filter に関わらず同一出力、平坦部が保たれること（`MetalPipelineTests`）。
- **未実施**: 実素材での画質評価（リンギングの主観評価・Lanczos 等との比較は 07 の評価に置く）、GPU 時間の実測（G2）。

### 2026-11-17 — #8 A3: 非 AI（metalGuided）ノイズ除去を graph に実装

- **決定**: `MetalRenderGraph` が plan の `.denoise` 段を実行する（deinterlace の後・colorConvert の前）。強さは `LumaChromaDenoiseRequest.metalDenoiseStrength`（RVVideoPipeline 側の最小契約。`DenoiseParameters` が metalGuided のときだけ適合値を返す — RVVideoPipeline は RVEnhancement に依存できないため）。learned 実装（ML 段）は nil で、この段は実行しない。強さ 0 は段を実行せず恒等。
- **アルゴリズム**: 輝度は 5x5 の bilateral（空間重み × 値差重み。値差の sigma は `mix(0.01, 0.12, strength)`、輝度 [0,1] 正規化）、色は 3x3 の bilateral。強い edge（字幕・線画・顔の輪郭）は値差が sigma の数倍で平均に入らず保たれ、小振幅の揺らぎ（ブロック・粒子・色ノイズ）だけが均される。temporal blend は前 *出力* が要るため v1 に入れない（ghost 回避）。
- **検査**: ±8 の市松ノイズ領域の振れ幅が半分未満に均され、強い edge の暗側・明側が保たれること、strength 0 は恒等であること（`MetalPipelineTests`）。
- **未実施**: 実素材での評価（顔・アニメ線画・粒子を塗り潰さないかの主観評価、before/after キャプチャ — 07 §7）、protect / targets の実際の反映（現状は strength のみ）、GPU 時間の実測、UI からの強度操作の配線。

### 2026-11-17 — #5 A1d: CadenceAnalyzer（05 §5.1 の判定ロジック。GPU 非依存）

- **決定**: frame ごとの comb スコア（1 frame 内の 2 field の不一致量。`rv_fieldMatch_sad_v1` の block SAD から host 側が作る）を `CadenceAnalyzer.ingest(combScore:)` に流すと `CadenceDecision { cadence, confidence, telecinePhase, evidence }` が返る。3:2 telecine の周期 `[clean, clean, combed, combed, clean]` に直近 10 frame が完全一致したら `.telecine32`（位相付き、confidence 1.0）。ロック中は予測と 2 frame 連続で食い違ったら抜ける（hysteresis 2 frame。1 frame の食い違いは静止場面の取りこぼしとして許容）。窓が満ちる前（9 frame まで）は telecine を宣言しない（誤検出による 24p 化の回避）。telecine でない場合は縞なし → `.progressive`、8 割以上 → `.interlaced22`、その他 → `.mixed`。根拠は窓のビット列の FNV-1a 64 を `evidence` に残す（09 §5）。
- **検査**: 5 つの位相すべてで 10 frame 目にロックし位相が合う、全縞あり / 全縞なしの分類、9 frame ではロックしない、1 回の食い違いでは抜けず 2 連続で抜ける、telecine → 全縞ありで interlaced22 に落ち着く、根拠の再現性（`CadenceAnalyzerTests`）。
- **未実装（A1 の残り）**: comb スコアを GPU の SAD kernel から取り出して analyzer へ流す配線、`.auto` の mode 選択（telecine → inverseTelecine）、inverseTelecine の復元と 2:3 提示、`CadenceDecision` の plan / 診断への記録。OQ-22（60i の film-origin pull-down）の実素材検証（#15）も要る。

### 2026-11-17 — #6 A2: Core ML 実行層（load / predict / tiny model ハーネス）

- **許可**: `coremltools` の取得はユーザーの許可を得て、プロジェクトの `.venv-tools`（`.gitignore` 済み）の仮想環境にだけ入れた（coremltools 9.0 + numpy）。重み・外部モデルは取得していない。
- **決定（実装）**: `CoreMLModelRuntime`（actor）が `ModelRuntimeProtocol` を実装する。`<modelsDirectory>/<name>/model.json`（`ModelManifest`）+ コンパイル済み `.mlmodelc` を discover / load し、方針 A（06 §4）で `CVPixelBuffer` を image 特徴として渡して出力も pixel buffer で受ける。`predict` は `InferenceFrame`（Sendable の箱）で入出力する。失敗はすべて `PlaybackError.model(...)` の値で返す: 未 load → `notCompiled`、寸法違い → `shapeMismatch`（モデルの不調ではないので breaker に数えない）、期限超過 → `deadlineExceeded`（結果を捨てる。breaker に数えない）、推論例外 → `runtimeFailure`（breaker に加算）、breaker open → `disabledByBreaker`。`measuredOn` / `expectedLatencyMS` の無いモデルは既定で load を拒否する（G3 の運用ルール。契約検査用の tiny model だけ `requireMeasurement: false`）。`ModelHealthTracker`（前の増分）が p50/p95・失敗率・breaker を保持する。
- **tiny model**: `Scripts/make-tiny-model.py` が 32x32 BGR を 255-x に反転するモデルを生成する（約 20 KB の `.mlmodelc` と `model.json` を `Tests/RVMLRuntimeTests/Models/tiny-invert-v1` に置く）。coremltools 9.0 では MIL program 直書きの出力 `ImageType` 指定が反映されず multiArray になるため、spec を編集して出力を BGR の画像にしている。
- **検査（実際の Core ML 推論）**: discover、load → predict（画素値 245/155/55 を確認）→ unload、未計測モデルの拒否、shape 不一致が breaker に数えられない、期限超過が breaker に数えられない、連続失敗で breaker が open して以降は投入されない（`CoreMLModelRuntimeTests`）。
- **未実装（A2 の残り）**: Metal ↔ テンソルの橋渡し（`tensor_to_texture` kernel・方針 B）と変換コストの分離計測、tile 分割 + overlap blend、memory pressure 連動の unload、`EngineCore` への接続（breaker の open を `ControlSignals.modelBreakerOpen` へ）、実モデルでの compute units 実測（G3）。実モデル（Real-ESRGAN 等）の変換・同梱は OQ-07 / OQ-11 とライセンス確認が済むまで行わない。

### 2026-11-17 — #6 A2: タイル分割推論（06 §5。16 px オーバーラップ + feather 合成）

- **決定**: `TilePlan`（純粋な計画）が、モデルの入力寸法のタイルで frame を覆う。軸ごとに stride = tile − overlap（既定 overlap 16 px）で並べ、最後のタイルは frame の端に揃える。frame がタイルより小さい・重なりがタイル以上・倍率が不正なら nil（呼び出し側はより小さいモデル variant を選ぶか推論しない — 08 §5）。合成は重なりを線形に混ぜる feather で、**重みは出力画素ごとに正規化**するので合計は常に 1（恒等モデルなら入力が厳密に復元される）。超解像の倍率（scale）は出力タイルの配置と重みの幅に反映する。
- **`TiledInference.run`**: BGRA の `CVPixelBuffer` を CPU でタイルに切り出し、`ModelRuntimeProtocol.predict` を**直列に**投入し（in-flight ≤ 2 の枠内 — 06 §7）、出力を合成して 1 枚の pixel buffer にする。どのタイルが失敗しても全体を失敗として返す（部分的に強調された frame は出さない。呼び出し側はその frame を非強調のまま提示 — INV-1）。入力寸法が計画と違えば、どのタイルも走らせずに `shapeMismatch`。
- **検査**: 計画の被覆・端揃え・重なり、無効な計画の拒否、**正規化による恒等復元**（scale 1 と 2）、継ぎ目が階段にならない（単調・最大の段差が小）。**実際の Core ML 推論**（tiny model、80x64 を 32x32 のタイル・overlap 8 で）で、継ぎ目を含む全画素が全体の反転（255−x）と一致（±3）。タイルの失敗が全体の失敗になること。
- **未実装（A2 の残り）**: Metal の texture ↔ Core ML の入出力（`tensor_to_texture`・方針 B。いまは CPU の BGRA 経由の参照実装）、タイル合成の Metal kernel 化（`blend`）、描画手順に RGB の中間 texture を挟む graph の作り替え、`EngineCore` への接続（breaker の open を `ControlSignals.modelBreakerOpen` へ）、メモリ逼迫での unload、実モデルでの計算ユニットの実測（G3）。実モデルの変換・同梱は OQ-07 / OQ-11 とライセンス確認が済むまで行わない。

### 2026-11-17 — #9 A4: 適応制御の信号接続（breaker / memory pressure / thermal / 降格理由）

- **決定（接続）**: `EngineCore.setModelRuntime(_:models:)` でモデル実行層（`ModelRuntimeProtocol`）と追跡するモデルを接続する。窓（2 s）ごとの評価（`evaluateWindow`。session に依存せず単体で検査できる）が、次の信号を `ControlSignals` に載せる: ① **breaker**: 追跡中のモデルのどれかの `health.breakerState == .open`（half-open は試行中なので open 扱いにしない）→ `modelBreakerOpen`（controller が tier の上限を metalOnly にする）。② **memory pressure**: `DispatchSourceMemoryPressure`（warning / critical / normal。実行層を接続している間だけ監視）→ `memoryPressureLevel`。③ **thermal**: `ProcessInfo`（前の増分）。④ 窓の `FrameStats` の差分（前の増分）。
- **決定（action の適用）**: `applyControlActions` は async になり、`.unloadModel`（memory pressure）で追跡中のモデルを実際に `unload` する。降格の理由を UI へ流す（`enhancementDegraded`: breaker → `modelFailure`、memory pressure → `memory`、thermal → `thermal`、それ以外 → `loadHigh`）。**降格のときだけ**通知し、昇格（`.setTier` が上がる方向）は通知しない。
- **検査**: 信号の写像、breaker の open で tier が metalOnly に下がる（half-open では下がらない）、memory pressure で unload と tier 降下、実行層が無ければ breaker は常に closed で unload もしない、thermal serious の上限と理由の通知、昇格を降格として通知しない。**本物の Core ML 実行層**（tiny model を NV12 の入力で 3 回失敗させて実際に breaker を open）で、エンジンの tier が下がるところまでの通し検査。
- **未接続（意図的）**: ① present jitter: `.immediate` の提示では「予約時刻との差」が提示までの待ち時間になり、基準値（8 ms）を超えて誤作動するため接続しない（指標の再定義が先）。② endToEnd の p95: PTS から実提示までの対応付けは `MetalPresenter.onPresented` の集計が要る。③ 実際の AI 段（超解像・学習ベースのノイズ除去）が plan に入る構成での挙動（現状は AI 段が無いので tier が上がっても段は増えない）。④ 品質インジケータ UI、負荷注入テスト、ベンチマークレポート。

### 2026-11-17 — #6 A2: Metal ↔ Core ML の橋渡しと AI 段（方針 A）

- **決定（橋渡し、方針 A — 06 §4）**: BGRA8 の IOSurface 付き・Metal 互換の `CVPixelBuffer` と、その同じ領域を指す `MTLTexture`（`RGBFrameBuffer`。`CVMetalTextureCache` から renderTarget + shaderRead + shaderWrite で取り込む）を橋にする。Metal が描画先として書いた buffer を、そのまま Core ML に image 入力として渡し（コピー無しで GPU と Core ML が同じ領域を見る）、Core ML の出力 buffer を texture として取り込み直す。`MetalRenderGraph` に `makeRGBBuffer` / `importRGB` / `renderToRGB`（deinterlace + 色変換を取り込み域の寸法いっぱいに描く。拡縮・letterbox 無し）/ `presentRGB`（目標比率で letterbox して target へ。`rv_rgbPresent_v1`）を追加した。
- **決定（AI 段）**: `MLEnhancementStage`（RVEnhancement。RVVideoPipeline と RVMLRuntime の両方に依存できる層）が、① 入力を RGB buffer へ描く（GPU の完了を待つ）→ ② `TiledInference` でタイル分割推論 → ③ 出力を texture として返す。失敗（未 load・breaker open・shape 不一致・期限超過・描画失敗）はすべて型付きの `PlaybackError`。呼び出し側はその frame を非強調のまま提示する（INV-1）。この段は再生時刻を持たない。
- **検査（実際の Metal + Core ML）**: 反転モデル（tiny）で、Metal の描画 → Core ML（32x32 のタイル・overlap 8 で 64x64 を分割）→ Metal の提示を通した出力が、通常の描画の 255 − x に全画素で一致（継ぎ目を含む。±4）。未 load のモデルは `notCompiled`、タイルより小さい frame は `shapeMismatch`。
- **未実装（A2 / A3 の残り）**: ① `MetalFramePresenter` / `PlaybackSession` への AI 段の組み込み（tier が lightML 以上のとき enhance → presentRGB に切り替える。いまは plan に AI 段が入っても描画に使われない）。② タイル切り出し・合成の GPU 化（いまは CPU の参照実装。実時間の予算は未計測）。③ 実モデル（Real-ESRGAN 等）の変換・同梱・compute units の実測（OQ-07 / OQ-11 とライセンス確認が先）。④ 超解像の倍率（scale 2）で出力寸法が変わるときの presentRGB の検査（コードは対応、検査は scale 1 のみ）。

### 2026-11-17 — #6 / #7: AI 段の再生経路への組み込み

- **決定（有効化）**: `DefaultPlayerEngine.attachEnhancement(runtime:model:)` がモデルを load し（失敗なら false で AI 段は有効にならない）、presenter に AI 段を設定し、エンジンにモデル実行層を接続する（plan が manifest を参照でき、breaker / memory pressure が適応制御の信号になる）。`detachEnhancement()` で unload して切り離す。タイルはモデルの入力寸法、overlap は 16 px（入力寸法の半分未満に収める）、倍率は manifest の `scaleFactor`。plan に `superResolution` 段が入るのは、実行層が接続され、`measuredOn` のあるモデルが `selectModel` に選ばれ、tier が lightML 以上のとき（INV-2）。
- **決定（提示）**: `MetalFramePresenter` は、tier が lightML 以上で plan の `superResolution` 段が設定済みのモデルを指すときだけ AI 段を通す。再生を止めない（INV-1）ための方針: ① **推論は同時に 1 つだけ**。実行中は待たず、その frame を非強調のまま提示する（`skippedBusy`）。② **失敗**（breaker open・未 load・shape 不一致・描画失敗）も、frame を**落とさず非強調で提示**する（`fellBack`）。③ **期限**は frame の表示長（`enhancementBudgetMS` で変更可）。超えた結果は捨てて非強調で提示する。④ 強調して提示できた数は `enhanced`。`MetalPresenter` に `presentEnhanced`（AI 段の RGB buffer を letterbox して drawable へ）を追加し、drawable の確保・presented 記録・再描画（窓リサイズ時）は通常経路と共通。
- **決定（frame 境界での plan 切り替え — INV-3）**: これまで pending plan は `play()` でしか昇格しなかったため、再生中の設定変更・適応制御による tier の上げ下げが描画に反映されなかった（A4 で接続した信号の結果も効かなかった）。**次に提示された frame の位置イベントで pending plan を昇格する**ようにした（その場では差し替えない。既存の「設定変更で active plan が即座に変わらない」検査は維持）。
- **検査（実際の Metal + Core ML、headless の `CAMetalLayer`）**: AI 段を通して提示される（`enhanced == 1`）、tier が足りない / SR 段が無いと強調しない、モデル未 load は frame を落とさず非強調で提示（`delivered`、`fellBack == 1`、エラーが残る）、期限切れの結果は捨てて非強調で提示、推論が 250 ms かかる間に来た 2 枚目は待たずに提示（`skippedBusy == 1`）、plan は実行層の接続中だけ SR 段を持つ、load できないモデルでは `attachEnhancement` が false。
- **未実装 / 未検証**: ① 実時間での実測: タイルの切り出し・合成が CPU の参照実装で、29.97 fps の予算に入るかは未計測（遅ければ「同時に 1 つ」により強調される frame が間引かれ、強調と非強調が交互になって見える。滑らかさの評価と、遅いモデルは tier を下げる判断は G3）。② **実画面での確認はしていない**（headless の layer で提示まで通ることのみ）。③ アプリ（App）からの有効化の入口（`attachEnhancement` を呼ぶ UI / 設定）は未配線。④ 実モデル（Real-ESRGAN 等）の変換・同梱は OQ-07 / OQ-11 とライセンス確認が済むまで行わない。⑤ 学習ベースのノイズ除去（`denoise` の learned 実装）は同じ枠組みで追加できるが未実装。

### 2026-11-17 — #5 A1b 修正: 実盤 ISO での点線状アーティファクト（動き検出の拡張と chroma の動き適応）

- **発見（実盤 `PICHI_PICHI_PITCH1.ISO`、menu 11 秒）**: ユーザー提供の実 DVD の ISO を実アプリ窓（Metal 既定）で再生すると、動きの速い金属リングの輪郭に点線状の縞が出た（合成素材では出ていなかった）。
- **原因と対処**: ① 動き指標が 1 画素ごとに weave / 空間内挿を切り替えていた → 左右 1 画素と上下の保持行まで広げた 3x3 の最大にして判定を空間的に連続させ、しきい値を `smoothstep(0.02, 0.07)` に下げた。② 4:2:0 の chroma はインターレースでは行が field 交互なのに、weave のまま素通しにしていたため、動く輪郭で色が交互にずれた（chroma upsampling error）→ 動く画素の chroma は、輝度で保持した field（偶数行）の chroma から補間する（静止画素は従来どおり weave）。
- **確認**: 修正前後の実アプリ窓で同じ区間の輪郭を比較し、点線が消えたことを目視確認。`MetalPipelineTests` に chroma が動く画素でのみ補間されること（静止は weave のまま）を追加。
- **G2 判定ではない**: 実素材 1 本・菜単 menu の 11 秒での目視確認で、combing の客観検査・present 間隔・GPU 時間は未実施。#15 の 7 本は未充足。

### 2026-11-17 — QA 入口 RV_AUTO_TITLE（起動時に本体タイトルを選んで再生）と実盤 ISO の本体確認

- **決定**: `RV_AUTO_OPEN` と同じ opt-in env 約定で、`RV_AUTO_TITLE=<n>` があれば open 後にその `titleNumber` の本体タイトルへ `select` + `play` する（menu の first-play 政策とは独立。画面を操作せずに実盤の本体を検証するため）。
- **実測（`PICHI_PICHI_PITCH1.ISO`）**: VIDEO_TS は VMGM menu（約 13 MB、11 s）+ VTS_01（menu 235 KB + 本体 VOB 4 本 ≈ 3.6 GB、約 50 分 11 秒）。`RV_AUTO_TITLE=1` で本体が Metal 既定で再生され、実時間比 ≈ 1.0（位置が 1 s ごとに進む）。複数 VOB は連結して 1 タイトルとして扱われた（#25 の修復写しが働いた）。
- **未決（静止ロゴの輪郭の点々）**: 本体冒頭（PONY CANYON のロゴ）の文字輪郭に細かい点々が見える。静止に近い場面なので motion-adaptive の weave 側で、動き由来ではない。MPEG-2 の mosquito noise（輪郭周りの圧縮ノイズ）の可能性が高いが、**同じ瞬間を暫定経路と比較できていない**（再生位置と実時間が実行ごとにずれて同じ場面を撮れない）。確定には、seek 位置を指定できる QA 入口（例: `RV_AUTO_SEEK`）で同じ位置を撮る、または Metal の最終出力を CPU に読み戻して差分を取る必要がある。A3 の非 AI ノイズ除去（metalGuided）は mosquito noise を狙う処理だが、UI から強度を操作する配線がまだ無く、実盤での効果は未確認。

### 2026-11-17 — #5 A1e: 縞（comb）指標の実測と、field matching に進まない判断

- **測定道具**: `CombMeasurementTests`（`RVDecodeTests`）。環境変数 `RV_MEASURE_PATH`（任意で `RV_MEASURE_SKIP` / `RV_MEASURE_FRAMES`）を指定したときだけ、復号した frame ごとに「歯」指標（`(y−上)` と `(y−下)` が同符号で輝度 12 階調超となる画素の割合）、隣接行 SAD、PCE のフラグ（`progressive_frame` / `repeat_first_field` / `top_field_first`）を表示する。未設定なら何もしない（CI では走らない）。
- **指標の妥当性**: 歯指標は合成の縞あり frame（≈0.045）と縞なし（≈0.008）を 5 倍以上に分ける。既存の `rv_fieldMatch_sad_v1`（隣接行 SAD）は縦方向の細部でも反応するため、実素材では縞の指標として弱い見込み（歯指標の方が頑健）。
- **`telecine-32-01.mpg`（生成素材）は標準の 3:2 ではない**: 縞ありは 5 frame に 2 回だが**隣り合わず**（周期 [縞,無,無,縞,無]、冒頭は 3 frame 周期）。生成コマンドの `telecine=pattern=3` を 30000/1001 へ落とした結果とみられる。標準の 3:2（A A / B B B / C C / D D D）は縞ありが連続 2 frame（周期 [無,無,縞,縞,無]）になるはずで、`CadenceAnalyzer` の想定と合わない。この素材では analyzer はロックしない（安全側）。標準 3:2 の素材は `telecine=pattern=23` で作り直す必要がある（未実施）。
- **実盤（`PICHI_PICHI_PITCH1.ISO` 本編 VTS_01_1.VOB、約 50 s と 166 s の各 25 frame）に 3:2 は無い**: 歯指標は一定（≈0.0065 / ≈0.0155）で 5 frame 周期の山が無く、PCE は全 frame `prog=0 rff=0 tff=1`（**top field 先**。生成素材の bottom-first とは逆）。この素材では telecine 検出経路は一度も働かず、field matching は実盤で検証できない。
- **決定**: 周期が明確に見える実素材が無い間は、field matching（weave 復元）・inverseTelecine・presenter 配線に**進まない**。誤った weave は現状（motion-adaptive）より悪く見えるため。`CadenceAnalyzer` は純粋ロジックのまま残し、画面には接続しない。
- **次に必要になる設計（未実施）**: ① comb スコアの絶対しきい値は使えない（縞なしの基準が内容で 0.0065〜0.0155 と動く）→ 近傍窓の中央値に対する相対しきい値にする。② GPU の歯指標 kernel（simd 縮約）。③ field 順序は top-first / bottom-first の両方で検査する（実盤は top-first、生成素材は bottom-first）。④ 24p 化（重複 frame を捨て 2:3 で再タイミング）は session の時刻と OQ-10 に触れるため別 PR。field matching だけでは「24p 化」とは言わない。⑤ 標準 3:2 の実素材（#15 の `telecine-32-01`）。

### 2026-11-17 — #5 A1f: 標準 3:2 素材の作り直しと、telecine の検出・weave 復元の実接続

- **素材の作り直し**: `telecine-32-01.mpg` を `telecine=first_field=top:pattern=23`（入力 24000/1001 → 30000/1001、`-r` の再サンプル無し）で生成し直した（`Scripts/gen-fixtures.sh`。この 1 本だけ。manifest の sha を更新）。測定で縞ありが周期内位置 2・3（隣り合う 2 frame）の標準の 3:2 になったことを確認（直前の記録の `pattern=3` 素材は非標準だった）。
- **`CadenceAnalyzer` の相対しきい値**: `relativeFactor`（既定は絶対値のみ）を追加。縞ありの判定を「直近窓の**下側中央値**の 2.5 倍超（下限は絶対値）」にして、縞なしの基準が内容で動く実素材（0.0065〜0.0155）でも使えるようにした。実素材 PICHI 相当の周期なし入力では telecine を宣言せず、非標準の周期（[縞,無,無,縞,無]）でもロックしない。
- **weave 復元（`rv_ivtc_weave_v1`）**: 縞あり frame（位置 2・3）は、現 frame の先行 field と前 frame の後続 field を行ごとに織る（top-first: 偶数行=現・奇数行=前、bottom-first: 逆。chroma も同じ規則）。**画素単位の検査**: 4 つの映画コマ A〜D から 5 つの video frame を top-first / bottom-first 両方で作り、全 5 位置で復元結果が元のコマとビット一致（既定の deinterlace では一致しない = 検査が縞を区別できる）。前 frame が無いときは weave せず従来の空間内挿に倒す。
- **`TelecineMatcher`（判断。画面・GPU 非依存）と presenter 配線**: 縞スコア（CPU の歯指標 `CombMetric`、輝度面の列を間引いて計算）と PTS から、**確信してロックしている間だけ**指示を出す（縞あり位置 → weaveWithPrevious、それ以外 → keepWoven＝weave のまま。ロック前・非 telecine は従来どおり）。PTS が連続でない（seek・落とし frame・menu のループ）と判定と前 frame を捨てる（従来は seek をまたいで前 frame が残っていた点も直る）。`MetalFramePresenter` が interlaced frame ごとに呼ぶ。
- **実素材での検査（標準 3:2 素材を復号）**: ① 10〜12 frame 目までにロックし、ロック後に外れず、周期内位置が測定と全 frame で一致。② weave の指示は測定で縞ありだった位置にだけ出て、取りこぼしが無い。③ **レンダラーを通した出力の縞を実測**: 復元後は縞なしの基準の 1.5 倍以内（入力の縞ありは基準の 3 倍以上）。
- **範囲外（明記）**: これは**縞の除去**であって「24p 化」ではない。出力は元の 29.97 のままで、重複 frame（B）は捨てず、2:3 の再タイミングもしていない（session の時刻と OQ-10 に触れるため別 PR）。実盤 PICHI は 3:2 ではないので、**実盤では検証できていない**（#15 の実素材 `telecine-32-01` が必要）。`inverseTelecineTarget: 24p` の期待値は満たしていない。縞スコアは CPU 計算で、release ビルドでの実時間への影響は未計測。

### 2026-11-17 — #3: タイトルメニュー（VTS_nn_0.VOB）の静止画表示（実盤 ISO で確認）

- **発見（実盤 `PICHI_PICHI_PITCH1.ISO`）**: 再生すると first-play の VMGM（VIDEO_TS.VOB。約 11 s のロゴ映像）を繰り返すだけで、DVD メニューが出なかった。実盤の「本当のメニュー」は `VTS_01_0.VOB`（235 KB。映像は I picture 1 枚 + ボタンの字幕 `dvd_subtitle` + NAV pack）で、これまで列挙の対象外だった。さらに「menu 終端で本体へ進まず繰り返す」（B0）が、ロゴ → メニューという実盤の流れを塞いでいた。
- **決定（列挙と並び）**: `VideoTsNavigator` が `VTS_nn_0.VOB`（0 バイトでないもの）を menu チェーン（`isMenu`、`vtsNumber` = nn、`isTitleMenu`）として列挙する。並びは VMGM → タイトルメニュー（vts 昇順）→ 本体（昇順）。`VideoTsMediaSource` は ItemID を 1000 + vts（本体と衝突しない）、`titleNumber` 0、`stillImage` true とし、UI は「タイトルメニュー」と表示する。
- **決定（再生の流れ — `PlayerViewModel`）**: VMGM（映像 menu）が終わったら、タイトルメニュー（静止画）があればそこへ `select` + `play` して進む。静止画は 1 frame で終わり、極短の menu は繰り返さない規則（尺 1 s 未満）により最後の画面で止まる。タイトルメニューが無い盤では従来どおり VMGM を繰り返す。本体はタイトル一覧から選ぶ（ボタンの操作は未実装）。
- **発見（AVFoundation の限界）と決定（`StillPSDemuxer`）**: **AVFoundation は、ピクチャ 1 枚だけの program stream から sample を 1 枚も渡さず、長さも不定（NaN）になる**（同じファイルを 2〜3 回つないでも変わらず、生成素材では映像 track さえ見つからない）。ffmpeg は問題なく読める。そこで AVFoundation を通さず、`StillPSDemuxer`（RVDecode）が program stream から映像の PES（0xE0〜0xEF）の payload を自前で連結して ES を取り出し、1 枚の access unit（MPEG-2 の形式記述 + sequence header 付き）として VideoToolbox へ渡す。静止画は progressive frame として扱い（実測 `interlaced_frame=0`）、deinterlace で解像度を落とさない。字幕（ボタンの絵・ハイライト）・音声・NAV pack は読まない。
- **検査**: 生成した 1 枚だけの VOB（`menu-still-01.vob`、`Scripts/gen-fixtures.sh`）で、AVFoundation が読めないこと（前提の固定）、`StillPSDemuxer` が sequence header の信号（720x480・4:3・NTSC・progressive）と長さ（1 frame）を返し、VideoToolbox で**ちょうど 1 frame を復号**して中身があること、PES 解析（映像だけ・header data の読み飛ばし・途中で切れた packet）、構造で VMGM → タイトルメニュー（`stillImage`）→ 本体と並ぶこと、VMGM 終了でタイトルメニューへ進み、静止画の終了では繰り返さず本体へも自動で進まないこと、タイトルメニューの無い盤では VMGM を繰り返すこと。**実アプリで実盤 ISO を再生し、ロゴ → タイトルメニュー（「つづけてみる」「第 1 話」「第 2 話」「TVCM 集」の画面）が表示されることを確認した。**
- **未実装（B2。操作できるメニュー）**: ボタンのハイライトと操作（矢印・決定・クリック）、字幕（SPU）の復号と重ね合わせ、NAV pack（PCI）のボタン位置、IFO の PGC とメニューの飛び先（VM 命令）。いまは静止画の背景（ボタンの絵が焼き込まれた部分を含む）が見えるだけで、ボタンは押せない。`libdvdnav` の採否（OQ-01 / OQ-03）が前提。

### 2026-11-20 — #3 B2 第 1 段: NAV pack（PCI）と字幕（SPU）の読み取り（操作できるメニューへの土台）

- **方針**: 操作できる DVD メニューは `libdvdnav` を使わず、**自前で段階的に**作る（OQ-01 の「二段構え」の自前側。03 §4）。GPL の `libdvdnav` を組み込まずに済み、PICHI 級の単純なメニュー（ボタン + ハート形カーソル + 「タイトル / チャプターへ飛ぶ」）は読み取り・描画・簡易の VM 命令で足りる見込み。複雑な VM（条件分岐・レジスタ演算を多用する盤）は未対応で、その場合は静止画の表示（前の増分）にとどまる。段階: ① データを読む（今回）→ ② IFO（パレット CLUT・タイトル / チャプター → セル → 時間）→ ③ 字幕とボタンのハイライトを Metal で重ねる → ④ 選択と決定の操作（矢印・クリック・Enter）と、ボタンの VM コマンドの実行（JumpTT / JumpVTS_PTT / JumpSS 等の最小集合）。
- **決定（PCI — `DVDNavigation`、RVMediaSources）**: NAV pack（2048 byte。pack header → system header 0xBB → private_stream_2 0xBF の substream 0x00 = PCI 979 byte）から、VOBU の表示開始・終了（90 kHz）、UOP 制御、hli（ハイライト情報）を読む。hli は hli_gi（22 byte）+ btn_colit（3 色グループ × 選択 / 実行、各 32 bit = 上位 16 bit が 4 色のパレット添字、下位 16 bit が 4 色のコントラスト）+ btnit（18 byte × 最大 36）。ボタンは 24 bit × 2 に 10 bit の座標（btn_coln 2 + x_start 10 + zero 2 + x_end 10 / auto_action 2 + y_start 10 + zero 2 + y_end 10）、上下左右の隣（各 6 bit）、8 byte の VM コマンド。`scanNavPacks` が VOB 全体の NAV pack を sector 番号つきで返す（VOBU ごとの開始時刻 = セル ↔ 時間の対応の原料）。矩形が壊れたボタン（終端が始端より小さい）は捨てる。
- **決定（SPU — `SubpictureDecoder`、RVDecode）**: private_stream_1（0xBD）の substream 0x20〜0x3F の payload をつないだ 1 個分を復号する。先頭 4 byte = 全体サイズ + 制御列のオフセット、制御列のコマンド（FSTA / STA / STP、SET_COLOR、SET_CONTR、SET_DAREA、SET_DSPXA、CHG_COLCON、CMD_END）、画素は 2 bit の RLE（1〜4 nibble の符号。長さ 0 = 行末まで。行末で byte 境界へ。top field = 偶数行、bottom field = 奇数行を交互に符号化）。未知のコマンドは長さが分からないので推測せず nil。壊れた SPU も落ちずに nil / 読めた分だけ。
- **実盤での確認（手元のみ。盤のデータはコミットしない）**: `PICHI_PICHI_PITCH1.ISO` の `VTS_01_0.VOB`（115 sector）= NAV pack 1 + 映像 110 + SPU 3 sector。PCI は **12 ボタン**（位置は画面の「つづけてみる」「TVCM集」と一致。上下左右の隣も整合）で、コマンドは `30 05 00 pp 00 tt 00 00` の形（JumpVTS_PTT とみられる: チャプター pp = 1〜5、タイトル tt = 2 または 3 ← 未検証。仕様の調査結果と IFO で確認する）。SPU は宣言サイズ 4322 byte どおりに復号でき、表示領域 720x478、**12 個のハート形カーソル**（選択中のボタンの横に出る印）の絵になった。SPU 自身のコントラストは全部 0（透明）で、ボタンを選んだときの色・濃さは PCI の btn_colit（選択: 画素値 1 と 2 をコントラスト 11 で不透明にする）が上書きする。
- **検査（合成データ。試験側で仕様どおりに組み立てる）**: PCI は座標・隣・色・コマンド・色グループ・ボタン番号のオフセット・hli なし・壊れた矩形・NAV でない sector・走査。SPU は RLE の符号長別（1〜4 nibble）・行末まで・field 交互・色とコントラストと領域・壊れた入力と未知コマンド。RLE の符号化器は試験側で復号器とは独立に書いた。
- **未実装（次の段階）**: IFO の読み取り（メニューのパレット CLUT = PGC の 16 色の YCbCr、VTS_PTT_SRPT のタイトル / チャプター、PGC のセル再生情報 → セルの先頭 sector → 時間）、字幕の Metal での重ね合わせとハイライトの色の適用、操作と VM コマンドの実行、本編へのシーク。

