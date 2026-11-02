# LocalTranscriber 1.0.5

## Fixes

- Fixed PDF exports appearing blank when LocalTranscriber was running in dark appearance.
- PDF text and page numbers now use fixed print-safe colors independent of macOS appearance.
- Added regression coverage that renders exported PDF content and verifies that visible dark pixels are present.

No Runtime changes, model changes, or migration are required. LocalTranscriber 1.0.5 continues to use Runtime 1.0.0 and the existing Whisper model.

## Requirements

- macOS 14 or later
- Apple Silicon

This build remains ad-hoc signed and non-notarized.
