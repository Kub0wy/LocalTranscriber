# LocalTranscriber

LocalTranscriber is a native macOS app for private, on-device transcription with MLX Whisper on Apple Silicon. It exports TXT, SRT, and PDF files and does not keep an application-level transcription history.

## Requirements

- macOS 14 or later on Apple Silicon
- Python with `mlx-whisper`
- FFmpeg
- A local Whisper model, including Whisper Large v3 Turbo

The upcoming managed installer is not included yet. Until it is available, open **Settings → Runtime / Advanced**, select **Custom**, and choose existing Python, FFmpeg, and model locations. Each empty custom field falls back to the future managed-runtime location under:

```text
~/Library/Application Support/LocalTranscriber/
├── Runtime/
│   ├── Python/
│   ├── FFmpeg/
│   └── Environment/
├── Models/
├── Cache/
└── Config/
```

## Development

Open `LocalTranscriber.xcodeproj` in Xcode, or build and test from the command line:

```sh
xcodebuild -project LocalTranscriber.xcodeproj -scheme LocalTranscriber build
xcodebuild -project LocalTranscriber.xcodeproj -scheme LocalTranscriber test
```

Runtime binaries, Python environments, model files, generated transcripts, local media, build products, and user-specific Xcode state are intentionally excluded from version control.

## Localization

English is the default for new installations. Polish remains available in Settings, and an existing saved language choice is preserved during upgrades.

## Support LocalTranscriber

LocalTranscriber is free to use.

If you find it useful and would like to support its development:

[Buy Me a Coffee](https://buymeacoffee.com/jakubrolkab)

## Version

Current marketing version: **1.0.4** (build **1**).
