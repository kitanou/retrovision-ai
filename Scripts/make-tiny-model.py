#!/usr/bin/env python3
"""契約検査用の tiny model を生成する（06 §8）。32x32 BGR 画像を受け、各画素を 255 - x に反転して返す。

CI の毎回の契約検査（load → predict → 出力 layout → unload）専用。画質評価の対象ではない。
生成物（model.mlpackage → コンパイル済み model.mlmodelc と model.json）は Git に載せる（数十 KB）。
再生成: .venv-tools/bin/python Scripts/make-tiny-model.py <出力ディレクトリ>
  （venv は `python3 -m venv .venv-tools && .venv-tools/bin/pip install coremltools numpy`）
"""
import json
import pathlib
import shutil
import subprocess
import sys

import coremltools as ct
from coremltools.converters.mil import Builder as mb
from coremltools.proto import FeatureTypes_pb2 as ft

out_dir = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "tiny-invert-v1")
out_dir.mkdir(parents=True, exist_ok=True)


@mb.program(input_specs=[mb.TensorSpec(shape=(1, 3, 32, 32))])
def invert(image):
    inverted = mb.sub(x=255.0, y=image)
    return mb.clip(x=inverted, alpha=0.0, beta=255.0, name="out_tensor")


model = ct.convert(
    invert,
    convert_to="mlprogram",
    minimum_deployment_target=ct.target.macOS15,
    inputs=[ct.ImageType(name="image", shape=(1, 3, 32, 32), color_layout=ct.colorlayout.BGR)],
)
# MIL program 直書きでは出力の ImageType 指定が反映されず multiArray になる（coremltools 9.0 で確認）。
# spec を編集して出力を BGR の画像にする（pixel buffer で受け取れる — 06 §4 方針 A）。
spec = model.get_spec()
output = spec.description.output[0]
output.type.imageType.width = 32
output.type.imageType.height = 32
output.type.imageType.colorSpace = ft.ImageFeatureType.BGR
model = ct.models.MLModel(spec, weights_dir=model.weights_dir, compute_units=ct.ComputeUnit.CPU_ONLY)
package = out_dir / "model.mlpackage"
if package.exists():
    shutil.rmtree(package)
model.save(str(package))

compiled = out_dir / "model.mlmodelc"
if compiled.exists():
    shutil.rmtree(compiled)
subprocess.run(["xcrun", "coremlcompiler", "compile", str(package), str(out_dir)], check=True)
shutil.rmtree(package)   # コンパイル済みだけを残す

manifest = {
    "schemaVersion": 1,
    "id": "test.tiny.invert",
    "revision": "1",
    "displayName": "Tiny invert (contract test)",
    "task": "unknown",
    "scaleFactor": 1,
    "license": {"spdx": "CC0-1.0", "weightsLicense": "none (no weights)", "outputRightsConfirmed": True},
    "compiledModel": "model.mlmodelc",
    "checksum": "sha256:unset",
    "input": {"name": "image", "kind": "image", "width": 32, "height": 32,
              "pixelFormat": "BGRA8", "dataType": "float16"},
    "output": {"name": "out_tensor", "kind": "image", "width": 32, "height": 32,
               "pixelFormat": "BGRA8", "dataType": "float16"},
    "constraints": {"multipleOf": 16, "maxPixels": 4194304, "allowsDynamicShape": False},
    "computeUnitsPreference": "cpuOnly",
    "memoryEstimateMB": 1,
    "expectedLatencyMS": {"p50": 1.0, "p95": 2.0},
}
(out_dir / "model.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
print("generated", out_dir)
