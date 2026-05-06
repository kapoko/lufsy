# Lufsy

Lufsy: Loudness Broadcast Norm Analyser.

Lufsy is a native macOS loudness checking app that analyzes audio/video files with bundled FFmpeg and validates them against multiple delivery norms.

## Supported norms

- `EBU R128`
- `ATSC A/85`
- `ARIB TR-B32`
- `Streaming (YouTube/Spotify)` (`-14`)
- `Podcasts` (`-16`)

Each profile checks integrated loudness plus true peak, with profile-specific targets/tolerances. Some profiles also enforce a loudness range (LRA) limit.

## How it works

- Add files by drag-and-drop or with the `+` toolbar button.
- Analyses run concurrently with a bounded worker limit.
- Switching the norm dropdown re-evaluates existing measured files instantly (no re-scan needed).

## UI notes

- Toolbar includes:
  - info button (`i`) that opens a norms/details sheet,
  - norm dropdown,
  - add-files (`+`) button.

## Build and run

```bash
swift run
```
