# LocalTranscriber 1.0.6

- Improved Custom Runtime validation: LocalTranscriber now checks that the selected Python environment can import `mlx_whisper` before transcription starts.
- Clearer errors distinguish an unavailable Python executable from a missing `mlx-whisper` package.
- Added **Validate / Sprawdź** in Custom Runtime settings to check Python, `mlx-whisper`, FFmpeg, and the Whisper model.
- Improved Custom Runtime setup guidance and documentation.
- Added regression tests for runtime validation and transcription preflight.

Runtime 1.0.0 and managed runtime behavior remain unchanged. No migration is required.

## Requirements

- macOS 14 or later
- Apple Silicon (arm64)

This build is ad-hoc signed and is not notarized.
