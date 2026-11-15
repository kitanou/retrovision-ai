# 開発の入口（09 §7 の CI と同じ手順をローカルで実行できるようにする）
PKG := Packages/RetroVisionKit

.PHONY: all build release test check licenses fixtures clean

all: check

build:
	 swift -version
	 cd $(PKG) && swift build --build-tests

release:
	 cd $(PKG) && swift build -c release

test:
	 cd $(PKG) && swift test

licenses:
	 python3 Scripts/check-licenses.py

fixtures:
	 python3 Scripts/check-fixtures.py

check: build test licenses fixtures
	 @echo "OK"

clean:
	 cd $(PKG) && rm -rf .build
