#!/usr/bin/env python3
"""fixtures/manifest.json の検査（09 §2）。

- schemaVersion と必須キーの有無
- 各 fixture に id / kind / properties / expectations があるか
- status=pending の本数を報告（storage と sha256 が決まるまでは許容し、schema 違反のみ失敗にする）
"""
import json
import sys
from pathlib import Path

REQUIRED_FIXTURE_KEYS = {"id", "status", "kind", "sha256", "seconds", "properties", "license", "expectations"}
VALID_KINDS = {"videoTsFolder", "discImage", "plainFile", "opticalDisc", "generatedFile", "localExtract"}
VALID_STATUS = {"pending", "available", "generated", "local"}


def main() -> int:
    path = Path("fixtures/manifest.json")
    if not path.exists():
        print("fixtures/manifest.json が見つかりません", file=sys.stderr)
        return 1
    data = json.loads(path.read_text(encoding="utf-8"))
    errors: list[str] = []

    if data.get("schemaVersion") != 1:
        errors.append("schemaVersion が未対応です")
    if not data.get("root"):
        errors.append("root（素材の取得元）が必要です")

    pending = 0
    for fixture in data.get("fixtures", []):
        missing = REQUIRED_FIXTURE_KEYS - set(fixture)
        if missing:
            errors.append(f"{fixture.get('id', '?')}: キーがありません {sorted(missing)}")
            continue
        if fixture["kind"] not in VALID_KINDS:
            errors.append(f"{fixture['id']}: kind が不明です")
        if fixture["status"] not in VALID_STATUS:
            errors.append(f"{fixture['id']}: status が不明です")
        if not isinstance(fixture["properties"], list) or not fixture["properties"]:
            errors.append(f"{fixture['id']}: properties が空です")
        if not isinstance(fixture["expectations"], dict) or not fixture["expectations"]:
            errors.append(f"{fixture['id']}: expectations が空です（期待値のない素材は検査に使えない）")
        if fixture["status"] == "pending":
            pending += 1
            if fixture["sha256"] is not None:
                errors.append(f"{fixture['id']}: pending なのに sha256 が入っています")
        else:
            sha = fixture["sha256"] or ""
            if len(sha) != 64:
                errors.append(f"{fixture['id']}: available なのに sha256 が 64 文字ではありません")

    print(f"fixtures: 合計 {len(data.get('fixtures', []))} / 未取得 {pending}")
    if errors:
        for e in errors:
            print(f"NG: {e}", file=sys.stderr)
        return 1
    if pending:
        print("NOTE: 実在素材（pending）の取得元（storage）が未決です（09 §2）。"
              "合成素材（generated）に対する統合テスト（RVDecodeTests）は実行されます。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
