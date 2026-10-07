# Kaze

Hold a key, speak, and Kaze types what you said into whatever app you're using. Speech recognition always runs on your Mac and your voice never leaves it. The optional Clean Up runs on your Mac too, unless you choose to connect your ChatGPT plan.

https://github.com/user-attachments/assets/8fde004a-e07a-45fc-ae3c-8f8a216873d3

## Download

Grab the latest `.dmg` from [GitHub Releases](https://github.com/fayazara/Kaze/releases/latest). Requires macOS 26 on Apple silicon.

## How it works

1. **Hold your shortcut** (default: `fn`) and talk. A small island grows out of the notch with a live waveform.
2. **Let go.** Kaze transcribes, optionally cleans the text up, and pastes it where your cursor is. Your clipboard is restored afterwards.

Prefer hands-free? **Tap** the shortcut once instead of holding it; Kaze keeps listening until you tap again. Press `esc` to cancel at any point.

```
shortcut ─▶ microphone (16 kHz) ─▶ speech model ─▶ Clean Up (optional) ─▶ replacements ─▶ paste
```

## Speech models

| Model | By | Runs on | Best for |
|---|---|---|---|
| **Apple Speech** | Apple | SpeechAnalyzer, built into macOS | Zero setup; shows words live as you speak |
| **Parakeet v2** | NVIDIA | Core ML on the Neural Engine ([FluidAudio](https://github.com/FluidInference/FluidAudio)) | Fastest and most accurate for English |
| **Parakeet v3** | NVIDIA | Core ML on the Neural Engine | 25 European languages |
| **Whisper** (Base, Small English, Large v3 Turbo) | OpenAI | Core ML ([WhisperKit](https://github.com/argmaxinc/WhisperKit)) | 99 languages |

## Clean Up

Optional post-processing that turns raw speech into written text: it removes fillers and false starts, keeps the correction when you change your mind ("Friday, no wait, Thursday" → "Thursday"), and writes numbers, dates, times, currency and email addresses properly. Choose a style (Casual → Formal), allow bulleted lists, and get proper email layout in mail apps. Two engines:

- **S1-mini by Superwhisper** (default): a 0.6B-parameter model fine-tuned for exactly this, run locally with [MLX](https://github.com/ml-explore/mlx-swift). Nothing leaves your Mac; the only network access is the one-time 1.5 GB download from Hugging Face. It loads while you speak and is freed right after, using up to 1.5 GB of memory only while cleaning. English only.
- **ChatGPT** (opt-in): Sign in with ChatGPT and Clean Up uses a model from your own ChatGPT plan (GPT-5.6-Luna by default, lowest thinking level). Your transcript is sent to OpenAI for that request with `store: false`, so it isn't saved to your ChatGPT history. No API key needed.

## Why Core ML for speech and MLX for Clean Up?

Speech models are encoder-heavy and run continuously, so Kaze runs them through **Core ML on the Neural Engine**: it's very fast (Parakeet transcribes a minute of audio in about half a second), sips power, and leaves the GPU free. S1-mini is a small language model generating text token by token, which is what **MLX** is built for, and it loads the published weights directly.

## Also

- **Vocabulary**: custom words that bias Apple Speech and Whisper, plus find-and-replace rules applied to every dictation
- **History**: recent dictations with search and one-click copy, plus words-per-minute and time-saved stats
- **Microphone picker**, sounds, launch at login, Sparkle auto-updates

## Building from source

```bash
git clone https://github.com/fayazara/Kaze.git
cd Kaze
open Kaze.xcodeproj
```

Build the `Kaze Dev` scheme (Debug, separate bundle ID) or `Kaze` (Release). Dependencies resolve through Swift Package Manager. The first build compiles MLX and takes a few minutes.

Debug builds include a headless self-test:

```bash
"Kaze Dev.app/Contents/MacOS/Kaze Dev" --selftest --model parakeetV2 --say "send the report by friday"
"Kaze Dev.app/Contents/MacOS/Kaze Dev" --selftest --format "so um send it friday no wait thursday"
```

Releases are cut with `go run ./cmd/kaze-release` (see `.agents/skills/release-kaze`).

## License

MIT. S1-mini is Apache 2.0 with a naming clause; see its [model card](https://huggingface.co/superwhisper/s1-mini).
