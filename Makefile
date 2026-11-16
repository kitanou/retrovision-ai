# 開発の入口（09 §7 の CI と同じ手順をローカルで実行できるようにする）
PKG := Packages/RetroVisionKit

.PHONY: all build release app run-app test check licenses fixtures gen-fixtures probe probe-play clean

all: check

build:
	 swift -version
	 cd $(PKG) && swift build --build-tests
	 cd App/RetroVisionApp && swift build --build-tests

release:
	 cd $(PKG) && swift build -c release

# 起動できる .app を組み立てる（build/RetroVision AI.app）。
app:
	 sh Scripts/make-app.sh release

run-app: app
	 open "build/RetroVision AI.app"

test:
	 cd $(PKG) && swift test
	 cd App/RetroVisionApp && swift test

licenses:
	 python3 Scripts/check-licenses.py

fixtures:
	 python3 Scripts/check-fixtures.py

# 合成 fixture の再生成（ffmpeg が必要: brew install ffmpeg）。
# 既存ファイルは skip される（Scripts/gen-fixtures.sh が冪等）。生成物は Git に載るため通常は不要。
gen-fixtures:
	 sh Scripts/gen-fixtures.sh

# 実測プローブ（EXP-001 の再現入口）。結果 JSON は bench/captures/（Git に載せない）。
# 新規ビルドの unsigned binary は SIGKILL されることがあるため ad-hoc 署名する（OQ-24）。
# 各行は別 shell で走るため、パスは Makefile の cwd（repo root）基準で書く。
probe:
	 cd $(PKG) && swift build -c debug --product rvprobe
	 @codesign --force --sign - $(PKG)/.build/debug/rvprobe
	 @mkdir -p bench/captures && for f in fixtures/generated/*; do \
	   b=$$(basename "$$f"); \
	   ./"$(PKG)/.build/debug/rvprobe" --json "$$f" 2>"bench/captures/probe-$$b.json" >/dev/null || echo "probe failed: $$b"; \
	 done
	 @echo "probe: bench/captures/probe-*.json（見る: python3 Scripts/show-probe.py bench/captures/probe-*.json）"

# 再生線の実時間計測（#11・G1 前半資料）。EngineCore を通した最初→最後の提示を測る。
# 素材長ぶん実時間で走る（11 素材で約 1.5 分）。結果は bench/captures/play-*.json。
probe-play:
	 cd $(PKG) && swift build -c debug --product rvprobe
	 @codesign --force --sign - $(PKG)/.build/debug/rvprobe
	 @mkdir -p bench/captures && for f in fixtures/generated/*; do \
	   b=$$(basename "$$f"); \
	   ./"$(PKG)/.build/debug/rvprobe" --json --play "$$f" 2>"bench/captures/play-$$b.json" >/dev/null || echo "play failed: $$b"; \
	 done
	 @echo "probe-play: bench/captures/play-*.json（見る: python3 Scripts/show-probe.py bench/captures/play-*.json）"

check: build test licenses fixtures
	 @echo "OK"

clean:
	 cd $(PKG) && rm -rf .build
