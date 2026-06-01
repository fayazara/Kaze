# Kaze

Hold a global hotkey, speak, and the transcribed text is automatically pasted into whatever app you're using. Transcription runs locally on your Mac, with optional Smart Formatting through your own AI provider API key.

https://github.com/user-attachments/assets/8fde004a-e07a-45fc-ae3c-8f8a216873d3

## Download

Grab the latest `.dmg` from [GitHub Releases](https://github.com/fayazara/Kaze/releases/latest).

## How it works

1. **Press your global hotkey** (default: `Option + Command`) to start recording.
2. **Speak** while Kaze captures audio and shows a floating waveform overlay.
3. **Stop recording** (release in Hold mode, or press again in Toggle mode).
4. **Kaze pastes the transcription** into the focused app while preserving your clipboard.

The app lives entirely in the menu bar with no Dock icon. On first launch, a guided onboarding wizard walks you through hotkey setup and engine selection.

## Features

### Transcription engines

> **Personal recommendation** -- use **Parakeet v3 (NVIDIA)** for the best overall results.

Kaze ships with **3 transcription engines**:

| Engine | Framework | Notes |
|---|---|---|
| **Direct Dictation** | Apple `SFSpeechRecognizer` | Zero setup, real-time streaming, uses device locale |
| **Whisper (OpenAI)** | [WhisperKit](https://github.com/argmaxinc/WhisperKit) | Local model variants: Tiny, Base, Small, Large v3 Turbo |
| **Parakeet v3 (NVIDIA)** | [FluidAudio](https://github.com/FluidInference/FluidAudio) | Fast, high-accuracy English ASR (~600 MB CoreML model) |

### Model management

- **One-click download/remove** in Settings -- view readiness status and model size on disk
- **Cancel in-progress downloads** at any time
- **Idle model unloading** -- models automatically free memory after 90 seconds of inactivity
- **Graceful fallback** -- if a selected model is unavailable, Kaze falls back to Direct Dictation

### Recording overlay

- **Dynamic Island / notch mode** -- a recording indicator that extends from the MacBook notch at the top of the screen, with animated expand/collapse transitions
- **Pill mode** -- traditional floating pill at the bottom-center of the screen
- **Real-time waveform bars** driven by audio level
- **Live scrolling transcription** text with leading fade mask
- **Processing state** -- shimmer animation + spinner while model inference or smart formatting runs

### Smart Formatting

- Post-process transcriptions with direct provider Cloud AI requests to add paragraphs, lists, punctuation, and spoken formatting cues
- Supports OpenAI, Gemini, and Anthropic API keys stored in Keychain
- Custom vocabulary words are injected into the formatting prompt for better accuracy

### Global hotkey

- **Configurable shortcut** with support for key + modifier and modifier-only combos
- **Two modes**: Hold to Talk and Press to Toggle
- Default: `Option + Command`
- Visual shortcut recorder in both Settings and Onboarding

### Microphone selection

- Pick a specific audio input device or use the system default
- Real-time device list updates when hardware is connected/disconnected
- Selection persists across sessions and is validated on launch

### Onboarding

- **4-step guided setup** on first launch: Welcome, Hotkey configuration, Engine selection, and Completion summary
- Preferences are saved automatically as you complete each step

### Other features

- **Custom vocabulary/keywords** -- add names, abbreviations, and domain terms to improve recognition across all engines
- **Transcription history** -- persistent local history (latest 50 entries) with engine labels, "Formatted" badge, relative timestamps, and one-click copy
- **Clipboard-safe auto-paste** -- saves and restores your clipboard contents around each paste
- **Trailing space option** -- optionally append a space after each transcription
- **Launch at login** -- start Kaze automatically when you log in
- **About dialog** -- version info, links to GitHub and Releases
- **Menu bar status indicator** -- icon dims when no model is loaded, animates during model loading

## Tech stack

| Layer | Technology |
|---|---|
| UI | **SwiftUI** + **AppKit** -- SwiftUI for Settings/Onboarding/Overlay views; AppKit for menu bar, floating panel, clipboard, and simulated key events |
| Speech | **Apple Speech framework** (`SFSpeechRecognizer`) for real-time streaming dictation |
| Whisper | [**WhisperKit**](https://github.com/argmaxinc/WhisperKit) for local OpenAI Whisper transcription |
| Parakeet | [**FluidAudio**](https://github.com/FluidInference/FluidAudio) for Parakeet v3 CoreML runtime |
| Smart Formatting | Direct HTTP requests to OpenAI, Gemini, or Anthropic |
| Hotkey | **CGEvent** tap for low-level global hotkey detection |
| Audio | **AVCaptureSession** + **Accelerate/vDSP** for microphone capture, format conversion, and resampling |
| State | **Combine** for reactive state bridging between transcription engines and the UI |
| Login item | **SMAppService** for launch-at-login registration |

## Requirements

- macOS 26.0+
- Xcode 26+ (for building from source)
- Accessibility permission (for global hotkey)
- Microphone permission
- Speech Recognition permission (used by Direct Dictation)

## Building from source

```bash
git clone https://github.com/fayazara/Kaze.git
cd Kaze
open Kaze.xcodeproj
```

Build and run in Xcode. Dependencies ([WhisperKit](https://github.com/argmaxinc/WhisperKit) + [FluidAudio](https://github.com/FluidInference/FluidAudio)) are resolved automatically via Swift Package Manager.

## License

MIT
