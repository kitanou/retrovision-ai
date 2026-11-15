# RetroVision AI

A native macOS player for DVD-era and other video content, with optional real-time AI restoration.

## Vision

Make SD video look its best on modern displays while preserving stable playback, correct cadence and audio/video synchronization.

## Initial scope

- DVD optical drives, VIDEO_TS folders and DVD ISO images
- Ordinary video files
- Metal-based deinterlacing, scaling and color processing
- Optional Core ML super-resolution and denoising
- Adaptive quality control with a reliable non-AI fallback

Commercial CSS/AACS-protected media support is subject to separate licensing and compliance work. Blu-ray is a separately gated milestone. The project will not implement copy-protection circumvention or key extraction.

## Planned technology

| Layer | Technology |
|---|---|
| App/UI | Swift, SwiftUI |
| DVD navigation | libdvdnav / libdvdread (evaluation) |
| Demux/decode | FFmpeg, VideoToolbox |
| Frame transport | CoreVideo |
| GPU processing | Metal |
| AI inference | Core ML |
| Audio / sync | AVFoundation, CoreAudio |

MLX may be used for model research; the shipping playback path will prioritize Core ML and Metal unless benchmarking indicates otherwise.

## Performance target

Initial target is 29.97 fps playback with an approximately 33.4 ms end-to-end frame budget on the development target (Apple M5 Max, 64GB). This is a goal to validate, not a guaranteed performance claim. Playback continuity and A/V sync take priority over enhancement quality.

## Development plan

See [Epic #1](https://github.com/kitanou/retrovision-ai/issues/1) and its implementation issues:

- #2 Native SwiftUI player shell
- #3 DVD sources: optical drive, VIDEO_TS and ISO
- #4 FFmpeg / VideoToolbox decode
- #5 Metal video pipeline
- #6 Core ML inference runtime
- #7 Real-time 2x AI super-resolution
- #8 AI denoising and restoration
- #9 Adaptive quality control and benchmarks

## Licensing

Review the licenses and distribution obligations of all third-party libraries and model weights before shipping. Protected-disc playback must use a compliant, properly licensed implementation. A playback license must not be assumed to permit arbitrary frame processing or output paths; confirm those rights with the relevant licensors or SDK vendor.

## Status

Early design and implementation planning.
