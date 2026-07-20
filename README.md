# LazyStudio 🎥✨

**Record lazily. Ship polished videos.**

An open-source, native macOS menu bar recorder for people who hate editing. Record your screen, camera, and mic in one click — then let AI cut the silences, add zooms, generate chapters, and write your YouTube title.

> Free forever. No accounts required to record. MIT licensed.

## Why

Screen Studio is beautiful but paid. OBS is powerful but complicated. Loom wants a subscription. Nothing open-source does **AI auto-editing** — that's the gap LazyStudio fills.

## Features

- 🖥️ **Native & lightweight** — Swift + SwiftUI + ScreenCaptureKit, lives in your menu bar
- 🎙️ Screen + system audio + microphone in one recording (macOS 15 `SCRecordingOutput`, no virtual drivers)
- 📷 Floating circular **camera bubble** (drag it anywhere, baked into the recording)
- 🪄 **AI Polish** *(in progress)* — transcribe, cut silences & retakes, auto-zoom, chapters, YouTube title/description. Bring your own Claude/OpenAI key, or run fully local with whisper.cpp
- 📂 Recordings saved to `~/Movies/LazyStudio`

## Install / Build

Requires macOS 15+ and Swift 6 (Xcode Command Line Tools are enough):

```bash
git clone https://github.com/everyai-com/lazystudio
cd lazystudio
./scripts/bundle.sh
open build/LazyStudio.app
```

Grant Screen Recording, Camera, and Microphone permissions when prompted.

## Architecture

```
Sources/LazyStudio/
├── LazyStudioApp.swift   # MenuBarExtra app shell
├── RecorderEngine.swift  # ScreenCaptureKit capture → .mp4
├── CameraOverlay.swift   # Floating AVFoundation camera bubble
├── MenuView.swift        # Menu bar UI
├── SettingsView.swift    # Recording + AI provider settings
└── AIEditor.swift        # AI post-processing pipeline (WIP)
```

The plan (inspired by Cap's Studio mode and the Screen.studio clones): record **raw video + event metadata** (cursor positions, clicks, transcript), then apply all polish non-destructively in post via an AI-generated edit decision list.

## Roadmap

- [ ] Whisper transcription (local via whisper.cpp)
- [ ] AI edit decision list → AVFoundation composition export
- [ ] Auto-zoom from cursor/click events, smoothed cursor
- [ ] Area/window selection, background & padding styling
- [ ] OAuth login for Claude/ChatGPT subscriptions (instead of API keys)
- [ ] Direct YouTube upload

## Inspiration & prior art

[Cap](https://github.com/CapSoftware/cap) · [QuickRecorder](https://github.com/lihaoyun6/QuickRecorder) · [Azayaka](https://github.com/Mnpn/Azayaka) · [Kap](https://github.com/wulkano/kap) · [OpenScreen](https://github.com/getopenscreen/openscreen)

## License

MIT
