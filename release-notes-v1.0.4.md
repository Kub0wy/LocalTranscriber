# LocalTranscriber 1.0.4

LocalTranscriber is a native macOS transcription application built for private,
on-device speech recognition on Apple Silicon.

## Highlights

- native macOS SwiftUI application
- local MLX Whisper transcription
- Whisper Large v3 Turbo support
- Managed Runtime installer and automatic Runtime/model setup
- Custom Runtime support
- TXT, SRT, and PDF export
- optional timestamps
- automatic or manual source-language selection
- speech-to-English translation
- live progress and Details output
- English and Polish interface
- local-first privacy with no analytics or tracking

## Requirements

- macOS 14 or later
- Apple Silicon / arm64

## Important: unsigned and non-notarized

This release is not signed with an Apple Developer ID and has not been
notarized by Apple. macOS may block it on first launch.

Install the application by opening the DMG and dragging LocalTranscriber to
Applications. Try to open it normally. If macOS blocks it:

1. Open **System Settings → Privacy & Security**.
2. Find the message about LocalTranscriber.
3. Choose **Open Anyway** and confirm **Open**.

Depending on the macOS version, you may instead Control-click or right-click
LocalTranscriber in Finder, choose **Open**, and confirm the prompt. This
approves only this application; do not disable Gatekeeper globally.

## Managed setup and privacy

LocalTranscriber downloads Runtime 1.0.0 from the versioned LocalTranscriber
GitHub Release. The Whisper Large v3 Turbo model is downloaded separately from
its pinned upstream Hugging Face revision after explicit consent.

Audio and video selected for transcription remain on your Mac and are not
uploaded for transcription. LocalTranscriber includes no analytics or tracking.
