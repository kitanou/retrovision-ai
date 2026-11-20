#!/usr/bin/env python3
"""SR の 16 bit テンソル契約（設計 11 §5.4・P2）を検査する tiny model を生成する。

入力 "image": float16 の NCHW [1, 3, 16, 24]（0..1 の RGB）。出力 "out": float16 [1, 3, 32, 48] =
「1 - x」を最近傍で 2 倍（値と位置の取り違えが出力に現れるようにする）。重みなし。数 KB。
`--enumerated` を付けると、入力に 16x24 と 24x32 の 2 寸法を受ける版（EnumeratedShapes。設計 11 D4）を作る。
再生成: .venv-tools/bin/python Scripts/make-tiny-sr-model.py <出力ディレクトリ> [--enumerated]
"""
import json
import pathlib
import shutil
import subprocess
import sys

import coremltools as ct
import numpy as np
from coremltools.converters.mil import Builder as mb

H, W = 16, 24
ENUMERATED = "--enumerated" in sys.argv
SIZES = [(16, 24), (24, 32)]   # (H, W)
args = [a for a in sys.argv[1:] if not a.startswith("--")]
out_dir = pathlib.Path(args[0] if args else "tiny-sr2x-f16-v1")
out_dir.mkdir(parents=True, exist_ok=True)


from coremltools.converters.mil.mil import get_new_symbol

shape_spec = (1, 3, get_new_symbol(), get_new_symbol()) if ENUMERATED else (1, 3, H, W)


@mb.program(input_specs=[mb.TensorSpec(shape=shape_spec, dtype=ct.converters.mil.mil.types.fp16)],
            opset_version=ct.target.macOS15)
def sr(image):
    inverted = mb.sub(x=np.float16(1.0), y=image)
    return mb.upsample_nearest_neighbor(x=inverted, scale_factor_height=2, scale_factor_width=2, name="out")


model = ct.convert(
    sr,
    convert_to="mlprogram",
    minimum_deployment_target=ct.target.macOS15,
    compute_precision=ct.precision.FLOAT16,
    inputs=[ct.TensorType(name="image",
                          shape=ct.EnumeratedShapes(shapes=[(1, 3, h, w) for h, w in SIZES], default=(1, 3, H, W))
                          if ENUMERATED else (1, 3, H, W),
                          dtype=np.float16)],
    outputs=[ct.TensorType(name="out", dtype=np.float16)],
    compute_units=ct.ComputeUnit.CPU_ONLY,
)
package = out_dir / "model.mlpackage"
if package.exists():
    shutil.rmtree(package)
model.save(str(package))
compiled = out_dir / "model.mlmodelc"
if compiled.exists():
    shutil.rmtree(compiled)
subprocess.run(["xcrun", "coremlcompiler", "compile", str(package), str(out_dir)], check=True)
shutil.rmtree(package)

manifest = {
    "schemaVersion": 1,
    "id": "test.tiny.sr2x.f16.enum" if ENUMERATED else "test.tiny.sr2x.f16",
    "revision": "1",
    "displayName": "Tiny SR x2 fp16 tensor (contract test)",
    "task": "superResolution",
    "scaleFactor": 2,
    "license": {"spdx": "CC0-1.0", "weightsLicense": "none (no weights)", "outputRightsConfirmed": True},
    "compiledModel": "model.mlmodelc",
    "checksum": "sha256:unset",
    "input": {"name": "image", "kind": "tensor", "width": W, "height": H, "pixelFormat": "RGB_NCHW", "dataType": "float16"},
    "output": {"name": "out", "kind": "tensor", "width": W * 2, "height": H * 2, "pixelFormat": "RGB_NCHW", "dataType": "float16"},
    "constraints": {"multipleOf": 8, "maxPixels": 4194304, "allowsDynamicShape": False,
                    **({"enumeratedSizes": [{"width": w, "height": h} for h, w in SIZES]} if ENUMERATED else {})},
    "computeUnitsPreference": "cpuOnly",
    "memoryEstimateMB": 1,
    "expectedLatencyMS": {"p50": 1.0, "p95": 2.0},
}
(out_dir / "model.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
print("generated", out_dir)
