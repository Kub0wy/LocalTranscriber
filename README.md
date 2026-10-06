<p align="center">
  <img src="LocalTranscriber/Assets.xcassets/AppIcon.appiconset/icon_128@2x.png" width="112" alt="LocalTranscriber icon">
</p>

<h1 align="center">LocalTranscriber</h1>

<p align="center">
  Fast, private, on-device transcription for Apple Silicon.
</p>

<p align="center">
  <strong>MLX Whisper · macOS · TXT · SRT · PDF · No cloud upload</strong>
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-required-black?logo=apple">
  <img alt="SwiftUI" src="https://img.shields.io/badge/SwiftUI-native-F05138?logo=swift&logoColor=white">
  <img alt="MLX Whisper" src="https://img.shields.io/badge/MLX-Whisper-blue">
</p>

---

## Overview

**LocalTranscriber** is a native macOS app for local speech transcription using **MLX Whisper** on Apple Silicon.

Your media stays on your Mac. LocalTranscriber does not upload source audio, transcripts, filenames, or model information to a cloud transcription service. It also does not maintain an application-level transcription history.

The workflow is intentionally simple:

**Choose source → choose destination → configure transcription → transcribe → export**

---

## Features

### Native macOS workflow

- Native SwiftUI interface
- Apple Silicon focused
- StudioFlow visual language
- English interface by default
- Polish interface available in Settings
- Fixed control areas with a flexible live Details workspace
- Persistent progress, status, and footer areas
- Minimum main-window size of **900 × 650 pt**

### Local transcription

- Local **MLX Whisper** backend
- Whisper Large v3 Turbo compatible
- Automatic language detection
- Manual source-language selection
- Speech-to-English translation
- Live backend/process output
- Progress percentage
- Elapsed time
- Estimated remaining time
- Safe cancellation of an active transcription
- Noise/empty-result filtering
- No persistent transcription-history database

### Export formats

| Format | Description |
| --- | --- |
| **TXT** | Plain-text transcript with optional timestamps |
| **SRT** | Subtitle file generated from Whisper segment timing |
| **PDF** | Paginated transcript document with configurable text size |

LocalTranscriber stages output before publication, so a cancelled task does not expose a partially written final transcript.

### Timestamp options

TXT and PDF can use:

- timestamps on/off
- **Start only**
- **Start + end**
- spacing:
  - Automatic
  - about every 15 seconds
  - about every 30 seconds
  - about every 60 seconds

For PDF output, body text size can be adjusted from **8 pt to 14 pt**.

SRT always uses timed Whisper segments.

### Supported source languages

- Auto Detect
- Polish
- English
- German
- Spanish
- French
- Italian
- Portuguese
- Ukrainian
- Russian
- Czech
- Slovak
- Dutch
- Swedish
- Norwegian
- Danish
- Finnish
- Turkish
- Greek
- Hungarian
- Romanian
- Bulgarian
- Croatian
- Serbian
- Slovenian
- Lithuanian
- Latvian
- Estonian
- Arabic
- Hebrew
- Hindi
- Chinese
- Japanese
- Korean

Whisper translation currently targets **English**.

---

## Privacy

LocalTranscriber is designed as a local-first tool.

- no cloud transcription API
- no analytics SDK
- no advertising SDK
- no embedded web view
- no application-level transcript history
- no transcript upload to StudioFlow
- no filename upload to StudioFlow
- no model-path upload to StudioFlow

The **StudioFlow** and **Buy Me a Coffee** buttons simply open their URLs in your default browser.

---

## Requirements

Current source builds require:

- **macOS 14 or later**
- **Apple Silicon**
- Python with `mlx-whisper`
- FFmpeg
- a local MLX-compatible Whisper model

### Managed CLI installation

Clone the repository and run the transparent CLI installer:

```bash
git clone https://github.com/Kub0wy/LocalTranscriber.git
cd LocalTranscriber
./installer/install.sh
```

The installer shows the complete plan before downloading anything. It installs
Runtime 1.0.0 from the dedicated GitHub Release and, after separate consent,
downloads Whisper Large v3 Turbo directly from its upstream Hugging Face
repository. No Homebrew or system Python installation is modified.

For runtime-only, model-only, validation, repair, non-interactive, and custom
location commands, see [installer/README.md](installer/README.md).

The SwiftUI first-run installer is not implemented yet.

---

## Runtime configuration

Open:

**Settings → Runtime / Advanced**

LocalTranscriber supports two runtime modes.

### Automatic / Managed

The CLI installer uses the app's managed runtime path-resolution architecture.

Default managed location:

```text
~/Library/Application Support/LocalTranscriber/
├── Runtime/
│   ├── FFmpeg/
│   └── Environment/
│       └── bin/
│           └── python3
├── Models/
├── Cache/
└── Config/
```

The current installer is command-line based. A SwiftUI first-run installer is
planned for a future release.

### Custom

You can independently provide:

- **Python executable**
- **FFmpeg executable**
- **Whisper model directory**

Each empty custom field falls back to the managed default for that component.

The model directory may point either to:

- a Whisper/Hugging Face cache directory, or
- a model snapshot directly

LocalTranscriber resolves the usable model snapshot automatically.

---

## Advanced Transcription Config — JSON

LocalTranscriber includes an **Advanced Transcription Config (JSON)** editor in Settings.

The JSON object is saved in app preferences and passed directly as keyword arguments to:

```python
mlx_whisper.transcribe(...)
```

The app validates that the field contains a JSON object before starting transcription.

### Default LocalTranscriber configuration

```json
{
  "condition_on_previous_text": false,
  "temperature": 0.0
}
```

### App-controlled values

These values are controlled by LocalTranscriber itself and should not be configured manually:

```text
path_or_hf_repo
language
task
verbose
```

`path_or_hf_repo`, `language`, and `task` are explicitly protected by the worker before the backend call. `verbose` is controlled by LocalTranscriber so the live Details panel can receive backend output.

---

## JSON parameter reference

The exact accepted parameter set depends on the installed version of `mlx-whisper`.

### Transcription-level options

| Key | Type / example | Description |
| --- | --- | --- |
| `temperature` | `0.0` or `[0.0, 0.2, 0.4]` | Sampling temperature, or a fallback temperature sequence |
| `compression_ratio_threshold` | `2.4` | Retry output when text appears excessively repetitive |
| `logprob_threshold` | `-1.0` | Retry output when average log probability is too low |
| `no_speech_threshold` | `0.6` | Silence-detection threshold |
| `condition_on_previous_text` | `false` | Feed previous-window output into the next decoding window |
| `initial_prompt` | `"Names: ..."` | Initial context / vocabulary hint |
| `word_timestamps` | `true` | Request word-level timing |
| `prepend_punctuations` | string | Punctuation to merge with the following word |
| `append_punctuations` | string | Punctuation to merge with the previous word |
| `clip_timestamps` | `"0,60,120,180"` | Restrict processing to selected time ranges |
| `hallucination_silence_threshold` | `1.0` | Skip long silence around possible hallucinations when word timestamps are enabled |

### Decode options

`mlx-whisper` also accepts decode options passed through to its decoder.

| Key | Type / example | Description |
| --- | --- | --- |
| `sample_len` | integer | Maximum number of tokens to sample |
| `best_of` | integer | Number of candidate samples when temperature is above 0 |
| `beam_size` | integer | Beam-search width when supported by the installed backend |
| `patience` | number | Beam-search patience |
| `length_penalty` | `0.0 ... 1.0` | Sequence-length ranking penalty |
| `prefix` | string / token list | Prefix for the current decoding context |
| `suppress_tokens` | `"-1"` / token list | Tokens to suppress |
| `suppress_blank` | `true` | Suppress blank output at the beginning |
| `without_timestamps` | `true` / `false` | Decode without timestamp tokens |
| `max_initial_timestamp` | number | Maximum initial timestamp |
| `fp16` | `true` / `false` | Select half/full precision path where supported |

> `prompt` is internally managed by the transcription loop for previous-window context. Prefer `initial_prompt` for user-supplied initial context.

> Some decode combinations may be incompatible. For example, backend constraints can differ between greedy/sampling/beam modes. Use only options supported by the installed `mlx-whisper` version.

### Example — deterministic transcription

```json
{
  "condition_on_previous_text": false,
  "temperature": 0.0,
  "no_speech_threshold": 0.6,
  "compression_ratio_threshold": 2.4,
  "logprob_threshold": -1.0
}
```

### Example — vocabulary hint

```json
{
  "condition_on_previous_text": false,
  "temperature": 0.0,
  "initial_prompt": "StudioFlow, LocalTranscriber, AutoSync, FrameGap"
}
```

### Example — fallback temperatures

```json
{
  "condition_on_previous_text": false,
  "temperature": [0.0, 0.2, 0.4, 0.6],
  "compression_ratio_threshold": 2.4,
  "logprob_threshold": -1.0
}
```

### Example — word timestamps

```json
{
  "condition_on_previous_text": false,
  "temperature": 0.0,
  "word_timestamps": true,
  "hallucination_silence_threshold": 1.0
}
```

For the authoritative parameter set for your installed backend, consult the upstream MLX Whisper implementation.

---

## Output naming

For:

```text
interview.wav
```

LocalTranscriber writes one selected output format:

```text
interview_transcript.txt
interview_transcript.srt
interview_transcript.pdf
```

If no destination folder is selected, the transcript is written beside the source file.

After a successful export, LocalTranscriber reveals the generated file in Finder.

---

## Live Details

The main window contains a permanent **Details** workspace.

It displays live backend/process information during transcription, automatically follows new output, and remains selectable and scrollable.

The Details panel is the only vertically flexible region of the main window. The product header, source/destination controls, transcription options, language controls, progress area, action bar, and footer remain structurally fixed.

---

## Progress and cancellation

The progress area is always present.

### Idle
- 0%
- elapsed `--:--`
- remaining `--:--`

### Active
- live progress percentage
- elapsed time
- estimated remaining time

### Completed
- 100%
- final elapsed time
- remaining `00:00`

The completed state remains visible until the next transcription begins.

Cancellation also terminates the external Python worker. If the worker does not exit after termination, LocalTranscriber force-stops it to avoid orphan background processes.

---

## Output safety

LocalTranscriber writes output to a temporary staged file first.

The final file is exposed only after:

1. transcription completes,
2. cancellation checks pass,
3. the selected exporter finishes successfully.

This avoids publishing incomplete final output after cancellation or failure.

---

## Interface

LocalTranscriber uses the same visual language as the StudioFlow AutoSync macOS app:

- compact dark workspace
- recessed surfaces
- system-blue accent
- StudioFlow typography and spacing
- fixed top controls
- flexible Details panel
- fixed bottom progress/action area
- persistent StudioFlow / support footer

---

## Development

Clone the repository:

```sh
git clone https://github.com/Kub0wy/LocalTranscriber.git
cd LocalTranscriber
```

Open:

```text
LocalTranscriber.xcodeproj
```

or build/test from Terminal:

```sh
xcodebuild -project LocalTranscriber.xcodeproj -scheme LocalTranscriber build
xcodebuild -project LocalTranscriber.xcodeproj -scheme LocalTranscriber test
```

Runtime binaries, Python environments, model files, generated transcripts, local media, build products, logs, secrets, and user-specific Xcode state are intentionally excluded from version control.

---

## Project structure

```text
LocalTranscriber/
├── LocalTranscriber/
│   ├── AppSupport.swift
│   ├── AppTheme.swift
│   ├── ContentView.swift
│   ├── Exporters.swift
│   ├── LocalTranscriberApp.swift
│   ├── RuntimeConfiguration.swift
│   ├── RuntimeValidator.swift
│   ├── SettingsStore.swift
│   ├── SettingsView.swift
│   ├── TranscriptionEngine.swift
│   └── transcribe_worker.py
├── LocalTranscriberTests/
├── LocalTranscriber.xcodeproj/
└── README.md
```

---

## Roadmap

The application itself is functional. Distribution work still planned:

- managed Python runtime
- managed FFmpeg
- managed `mlx-whisper` dependencies
- automatic Whisper model download
- runtime manifest and checksums
- GitHub Releases runtime package
- first-run GUI setup
- CLI installer
- code signing
- notarization
- DMG distribution

The final installer goal is simple:

**download LocalTranscriber → approve required components → everything else happens automatically**

Advanced users will still be able to keep using custom Python, FFmpeg, and model locations.

---

## StudioFlow

LocalTranscriber is part of the **StudioFlow** family of tools for media workflows.

**Explore more StudioFlow products:**  
https://studioflow.media/

---

## Support LocalTranscriber

LocalTranscriber is free to use.

If it saves you time and you would like to support continued development:

**[Buy Me a Coffee](https://buymeacoffee.com/jakubrolkab)**

---

## Version

Current marketing version: **1.0.4**  
Build: **1**
