#!/usr/bin/env python3
"""licenses/inventory.json の検査（09 §6）。

- status=integrated の項目はライセンス項目がすべて埋まっていることを要求する
- status=excluded の項目は distribution に理由があることを要求する
- models に載った項目は outputRightsConfirmed を明示していることを要求する
"""
import json
import sys
from pathlib import Path

REQUIRED_KEYS = {"name", "status", "spdx", "distribution", "sourceURL", "obligations", "blockingItems"}
VALID_STATUS = {"integrated", "planned", "excluded"}
INTEGRATED_REQUIRED = {"version", "spdx", "distribution", "sourceURL"}


def main() -> int:
    path = Path("licenses/inventory.json")
    if not path.exists():
        print("licenses/inventory.json が見つかりません", file=sys.stderr)
        return 1
    data = json.loads(path.read_text(encoding="utf-8"))
    errors: list[str] = []

    if data.get("schemaVersion") != 1:
        errors.append("schemaVersion が未対応です")

    integrated = 0
    for entry in data.get("thirdParty", []):
        name = entry.get("name", "?")
        missing = REQUIRED_KEYS - set(entry)
        if missing:
            errors.append(f"{name}: キーがありません {sorted(missing)}")
            continue
        if entry["status"] not in VALID_STATUS:
            errors.append(f"{name}: status が不明です")
        if entry["status"] == "integrated":
            integrated += 1
            for key in INTEGRATED_REQUIRED:
                value = entry.get(key)
                if not value or (isinstance(value, str) and "TBD" in value):
                    errors.append(f"{name}: integrated なのに {key} が未記入です")
            if not entry.get("obligations"):
                errors.append(f"{name}: integrated なのに obligations が空です")
        if entry["status"] == "excluded" and not entry.get("distribution"):
            errors.append(f"{name}: excluded なのに distribution（除外理由）がありません")

    for model in data.get("models", []):
        if "outputRightsConfirmed" not in model:
            errors.append(f"model {model.get('id', '?')}: outputRightsConfirmed がありません（06 §2）")
        if not model.get("license"):
            errors.append(f"model {model.get('id', '?')}: license がありません")

    print(f"third-party: 合計 {len(data.get('thirdParty', []))} / 組込み済み {integrated} / "
          f"models {len(data.get('models', []))}")
    if errors:
        for e in errors:
            print(f"NG: {e}", file=sys.stderr)
        return 1
    if integrated == 0:
        print("NOTE: 第三者ライブラリは一つもリンクしていません（実測: docs/experiments/EXP-001 — "
              "ファイル再生経路は AVFoundation + VideoToolbox で成立）。planned は DVD 制御（OQ-01）と "
              "フォールバックが必要になった場合の FFmpeg（OQ-02）の調査のみ。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
