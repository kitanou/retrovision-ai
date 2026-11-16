#!/usr/bin/env python3
"""rvprobe の --json 出力を選択的に表示する（実験記録の切り貼りに使う）。"""
import json
import sys

KEYS = (
    "file", "openStatus", "openMS", "error", "errorKind", "recovery", "warnings",
    "demuxedSampleCount", "samplesCarryFormatDescription",
    "containerFormatDescription", "sampleFormatDescription", "frameRateByPTSInference",
    "bitstreamFromSampleData", "pictureCodingExtensionFromSampleData",
    "decodeStatus", "decodeError", "decodePath", "decodedFrameCount",
    "decodeTotalMS", "decodePerFrameMS", "decodeThroughputFPS",
    "decodedPixelFormat", "decodedDimensions", "decodedAttachments", "decodedFormat",
    "mode", "playStatus", "loadError", "targetFrameRate", "targetFrameIntervalMS",
    "presented", "late", "firstPresentDelayMS", "totalWallMS", "mediaDurationMS",
    "realTimeFactor", "presentIntervalMS", "decodeStageMS", "errors",
    "audioStatus", "audioOutputFormat", "clockDriftMS",
    "audioUnderrunEpisodes", "audioUnderrunTotalMS",
)

def main() -> None:
    for path in sys.argv[1:]:
        print(f"##### {path}")
        try:
            entries = json.load(open(path))["entries"]
        except Exception as exc:  # noqa: BLE001
            print(f"  (read failed: {exc})")
            continue
        for e in entries:
            for k in KEYS:
                if k not in e:
                    continue
                v = e[k]
                if isinstance(v, (dict, list)):
                    print(f"{k}: {json.dumps(v, ensure_ascii=False, sort_keys=True)[:1200]}")
                else:
                    print(f"{k}: {v}")
            if "decodedFieldRetention" in e:
                fr = e["decodedFieldRetention"] or []
                print(f"fieldRetention: n={len(fr)} first={json.dumps(fr[0], sort_keys=True) if fr else None}")
                if len(fr) > 1:
                    print(f"                last={json.dumps(fr[-1], sort_keys=True)}")
            for audio in e.get("audioExperiment") or []:
                if "error" in audio:
                    print(f"audioExperiment: {json.dumps(audio, ensure_ascii=False)}")
                    continue
                print(f"audio: source={audio.get('sourceSubtypes')} dataRate={audio.get('estimatedDataRate')}")
                for mode in ("passthrough", "linearPCM"):
                    step = audio.get(mode) or {}
                    brief = {k: step.get(k) for k in (
                        "status", "sampleBufferCount", "totalBytes", "wallMS", "realtimeFactor",
                        "spanSeconds", "firstPTSValid", "lastPTSValid", "firstBufferFrames", "maxBufferFrames")}
                    print(f"  {mode}: {json.dumps(brief, sort_keys=True)}")
                    fmt = step.get("firstOutputFormat")
                    if fmt:
                        print(f"    format: {json.dumps(fmt, sort_keys=True)}")
            print()

if __name__ == "__main__":
    main()
